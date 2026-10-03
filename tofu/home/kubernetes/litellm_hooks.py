"""LiteLLM deployment hooks for Aether.

Mounted beside config.yaml and registered in litellm_settings.callbacks.
"""

import logging
import os
from typing import Any

import httpx
from fastapi import HTTPException
from litellm.integrations.custom_logger import CustomLogger

logger = logging.getLogger("litellm.hooks.aether")

# One client reused for every decide call; Moira must answer in <50 ms, so a
# 300 ms cap bounds the hook's added latency tightly.
_moira_client = httpx.AsyncClient(timeout=0.3)


class ChatReasoningEffort(CustomLogger):
    """Send Chat Completions backends a string reasoning_effort.

    LiteLLM 1.99.1 bridges /v1/responses onto Chat Completions by copying the
    whole Responses `reasoning` object into `reasoning_effort` whenever it has
    a `summary` (litellm/responses/litellm_completion_transformation). Clients
    such as OMP always send {"effort": ..., "summary": ...}, and Chat
    Completions backends (Meta, xAI and Antigravity bridges, OpenCode Go,
    CodeBuddy, Ollama) reject the object. Keep its effort string.

    Responses-API deployments (`responses/` models, chatgpt/) take the object
    as `reasoning`, so they are left alone; the family pool's configured
    {summary: concise} relies on that.
    """

    async def async_pre_call_deployment_hook(self, kwargs: dict[str, Any], call_type: Any) -> dict | None:
        effort = kwargs.get("reasoning_effort")
        if not isinstance(effort, dict):
            return None
        model = str(kwargs.get("model") or "")
        provider = str(kwargs.get("custom_llm_provider") or "")
        if "responses/" in model or provider == "chatgpt" or model.startswith("chatgpt/"):
            return None
        level = effort.get("effort")
        if isinstance(level, str) and level:
            kwargs["reasoning_effort"] = level
        else:
            kwargs.pop("reasoning_effort", None)
        return kwargs


chat_reasoning_effort = ChatReasoningEffort()


def _nonempty_str(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def _header_value(headers: Any, name: str) -> str | None:
    """First non-empty value for a case-insensitive header name."""
    if not isinstance(headers, dict):
        return None
    for key, value in headers.items():
        if isinstance(key, str) and key.lower() == name:
            found = _nonempty_str(value)
            if found is not None:
                return found
    return None


def extract_session_id(data: dict[str, Any]) -> str | None:
    """Session key for Moira's sticky pin, first non-empty string wins.

    Precedence mirrors pi-ai's auth-gateway `resolvePromptCacheKey`, with
    Moira's existing `user` last resort: body `prompt_cache_key`; body
    `metadata.{prompt_cache_key,session_id,conversation_id}`; header
    `x-prompt-cache-key`; header `session_id` / `conversation_id`; header
    `x-session-id` / `x-conversation-id` (case-insensitive, from
    `proxy_server_request.headers`); body `user`. Empty strings and
    non-strings never count.
    """
    found = _nonempty_str(data.get("prompt_cache_key"))
    if found is not None:
        return found
    metadata = data.get("metadata")
    if isinstance(metadata, dict):
        for key in ("prompt_cache_key", "session_id", "conversation_id"):
            found = _nonempty_str(metadata.get(key))
            if found is not None:
                return found
    proxy_server_request = data.get("proxy_server_request")
    headers = (
        proxy_server_request.get("headers")
        if isinstance(proxy_server_request, dict)
        else None
    )
    for name in (
        "x-prompt-cache-key",
        "session_id",
        "conversation_id",
        "x-session-id",
        "x-conversation-id",
    ):
        found = _header_value(headers, name)
        if found is not None:
            return found
    return _nonempty_str(data.get("user"))


class MoiraRouter(CustomLogger):
    """Ask Moira which concrete model a quota-tier request should use.

    Moira is a decision service, not a proxy: clients call LiteLLM as always
    and this pre-call hook POSTs the request envelope to Moira's /decide,
    which answers from its in-memory quota cache. `route` rewrites
    data["model"] (plus effort and up to two same-effort fallbacks), `refuse`
    raises the tier's 429/400 back to the caller, and passthrough, timeout or
    any Moira error leaves the request unchanged (fail-open) so the
    moira/<tier> alias deployments serve their static default model.

    Env: MOIRA_DECIDE_URL (POST target), MOIRA_DECIDE_TOKEN (bearer),
    MOIRA_GROUPS (comma list of tiers.yaml `groups` names to route).
    """

    _CALL_TYPES = {"completion", "acompletion", "responses", "aresponses"}

    async def async_pre_call_hook(
        self, user_api_key_dict: Any, cache: Any, data: dict[str, Any], call_type: Any
    ) -> dict[str, Any] | None:
        call = str(call_type)
        if call not in self._CALL_TYPES and "anthropic" not in call:
            return None
        model = str(data.get("model") or "")
        groups = {g.strip() for g in os.environ.get("MOIRA_GROUPS", "").split(",") if g.strip()}
        if not (model.startswith("moira/") or model in groups):
            return None

        if "input" in data and "messages" not in data:
            api = "responses"
        elif "anthropic" in call:
            api = "messages"
        else:
            api = "chat"

        effort = data.get("reasoning_effort")
        if isinstance(effort, dict):
            effort = effort.get("effort")
        if not isinstance(effort, str):
            reasoning = data.get("reasoning")
            effort = reasoning.get("effort") if isinstance(reasoning, dict) else None
        if not isinstance(effort, str) or not effort:
            effort = None

        session_id = extract_session_id(data)

        payload = {
            "model": model,
            "effort": effort,
            "api": api,
            "stream": bool(data.get("stream")),
            "session_id": session_id,
            "allowed_models": list(getattr(user_api_key_dict, "models", None) or []),
        }

        try:
            token = os.environ.get("MOIRA_DECIDE_TOKEN")
            response = await _moira_client.post(
                os.environ.get("MOIRA_DECIDE_URL") or "",
                json=payload,
                headers={"Authorization": f"Bearer {token}"} if token else {},
            )
            if response.status_code != 200:
                raise RuntimeError(f"decide answered HTTP {response.status_code}")
            decision = response.json()
            if not isinstance(decision, dict):
                raise RuntimeError("decide answered a non-object")
        except Exception as exc:  # fail open on any Moira error or timeout
            logger.warning(
                "Moira decide unavailable (%s: %s); failing open", type(exc).__name__, exc
            )
            return None

        action = decision.get("action")
        if action == "passthrough":
            return None
        if action == "refuse":
            body = decision.get("body")
            error = body.get("error") if isinstance(body, dict) else body
            retry_after = decision.get("retry_after_s")
            raise HTTPException(
                status_code=int(decision.get("status") or 429),
                detail=error,
                headers={"Retry-After": str(int(retry_after))} if retry_after is not None else None,
            )

        chosen = decision.get("model")
        if action != "route" or not isinstance(chosen, str) or not chosen:
            logger.warning("Moira decide returned an unusable %r answer; failing open", action)
            return None

        data["model"] = chosen
        route_effort = decision.get("effort")
        if isinstance(route_effort, str) and route_effort:
            if api == "responses":
                reasoning = data.get("reasoning")
                if not isinstance(reasoning, dict):
                    reasoning = {}
                reasoning["effort"] = route_effort
                data["reasoning"] = reasoning
            elif api == "chat":
                data["reasoning_effort"] = route_effort
        fallbacks = decision.get("fallbacks")
        if isinstance(fallbacks, list) and fallbacks:
            data["fallbacks"] = fallbacks
        return None


moira_router = MoiraRouter()
