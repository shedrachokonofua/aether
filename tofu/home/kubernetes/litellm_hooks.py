"""LiteLLM deployment hooks for Aether.

Mounted beside config.yaml and registered in litellm_settings.callbacks.
"""

import json
import logging
import os
from collections import OrderedDict
from typing import Any

import httpx
from fastapi import HTTPException
from litellm.integrations.custom_logger import CustomLogger

logger = logging.getLogger("litellm.hooks.aether")
# LiteLLM's JSON logging attaches its handler to the root logger, whose level
# stays at the WARNING default, which gates INFO records before handlers see
# them. Pin ours: the deployment adaptations must be visible at INFO.
logger.setLevel(logging.INFO)

# One client reused for every decide call. 1.5 s cap: /decide answers in ~12 ms, but under heavy streaming load
# LiteLLM's own event loop delayed the hook's call past the old 300 ms cap and
# requests fell back to the static alias (17 timeouts, 2026-10-08 01:03-03:47).
_moira_client = httpx.AsyncClient(timeout=1.5)

# Last request size (chars) per session, for input estimates when a provider
# reports none: an agent resends its whole history each turn and providers bill
# the cached repeat at a fraction (Muse: ~4.2B raw input tokens on 2026-10-09
# moved its weekly meter ~30%, ~0.45B), so only the growth is new input.
_SESSION_CHARS: "OrderedDict[str, int]" = OrderedDict()
_SESSION_CHARS_MAX = 5000


def _new_input_chars(session_key: str | None, chars: int) -> int:
    if session_key is None:
        return chars
    prev = _SESSION_CHARS.pop(session_key, None)
    _SESSION_CHARS[session_key] = chars
    if len(_SESSION_CHARS) > _SESSION_CHARS_MAX:
        _SESSION_CHARS.popitem(last=False)
    # A shrink (compaction, new conversation under the same key) is all new.
    return chars - prev if prev is not None and chars >= prev else chars


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


def _effective_allowed_models(user_api_key_dict: Any) -> list[str] | None:
    """Concrete models the caller may use, as LiteLLM's key auth resolves them.

    None means unrestricted (Moira applies no filter). A key's model list can
    hold LiteLLM placeholders instead of names: an empty list or
    `all-proxy-models` allows every model, and `all-team-models` (team keys,
    e.g. seven30-foundry) defers to the team's own list, which may itself be
    empty or `all-proxy-models`. Sending the placeholders verbatim made Moira
    refuse every candidate as "not allowed for this key" (2026-10-06).
    """
    key_models = [str(m) for m in (getattr(user_api_key_dict, "models", None) or [])]
    if "all-proxy-models" in key_models:
        return None
    team_scoped = "all-team-models" in key_models or (
        not key_models and getattr(user_api_key_dict, "team_id", None)
    )
    if team_scoped:
        team_models = [str(m) for m in (getattr(user_api_key_dict, "team_models", None) or [])]
        if not team_models or "all-proxy-models" in team_models:
            return None
        explicit = [m for m in key_models if m != "all-team-models"]
        return explicit + [m for m in team_models if m not in explicit]
    return key_models or None


class MoiraRouter(CustomLogger):
    """Ask Moira which concrete model a quota-tier request should use.

    Moira is a decision service, not a proxy: clients call LiteLLM as always
    and this pre-call hook POSTs the request envelope to Moira's /decide,
    which answers from its in-memory quota cache. `route` rewrites
    data["model"] (plus effort, up to two fallbacks and each one's own effort
    in metadata.moira_efforts, applied per attempt by deployment_adapter), `refuse`
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
            # Moira skips models whose output cap is below this (they would be
            # clamped and truncate), unless nothing larger is left.
            "max_output_tokens": next(
                (v for k in ("max_completion_tokens", "max_tokens", "max_output_tokens")
                 if isinstance(v := data.get(k), int) and not isinstance(v, bool) and v > 0),
                None,
            ),
            "allowed_models": _effective_allowed_models(user_api_key_dict),
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
        # Fallbacks may need another effort than the primary (e.g. Muse at max,
        # Opus at medium); deployment_adapter applies each attempt's own value.
        efforts = decision.get("efforts")
        if isinstance(efforts, dict) and efforts:
            # /v1/responses and /v1/messages keep LiteLLM's metadata in
            # `litellm_metadata`; their `metadata` is the provider-facing field.
            # Writing there hid moira_efforts from the failure reporter, so 429s
            # on those routes never cooled the provider (2026-10-09).
            bucket = "litellm_metadata" if isinstance(data.get("litellm_metadata"), dict) else "metadata"
            metadata = data.get(bucket)
            data[bucket] = {**(metadata if isinstance(metadata, dict) else {}), "moira_efforts": efforts}
        return None

    async def async_log_failure_event(self, kwargs: dict[str, Any], response_obj: Any, start_time: Any, end_time: Any) -> None:
        """Report a 402/403/429 from a Moira-routed attempt to Moira's /report.

        LiteLLM calls this once per failed attempt (primary and fallbacks), so
        Moira cools the refusing provider right away instead of routing into
        it until the next quota poll. Only attempts Moira routed (their
        metadata carries moira_efforts) are reported; any error is swallowed.
        """
        status = getattr(kwargs.get("exception"), "status_code", None)
        if status not in (402, 403, 429):
            return
        # /v1/responses calls carry request metadata under litellm_metadata.
        params = kwargs.get("litellm_params")
        efforts = model = None
        for bucket_name in ("metadata", "litellm_metadata"):
            bucket = params.get(bucket_name) if isinstance(params, dict) else None
            if isinstance(bucket, dict):
                efforts = efforts or (bucket.get("moira_efforts") if isinstance(bucket.get("moira_efforts"), dict) else None)
                model = model or bucket.get("model_group")
        if efforts is None or not isinstance(model, str) or model not in efforts:
            return
        url = (os.environ.get("MOIRA_DECIDE_URL") or "").removesuffix("/decide") + "/report"
        token = os.environ.get("MOIRA_DECIDE_TOKEN")
        try:
            await _moira_client.post(
                url,
                json={"model": model, "status": status},
                headers={"Authorization": f"Bearer {token}"} if token else {},
            )
        except Exception as exc:  # reporting is best effort
            logger.warning("Moira report failed (%s: %s)", type(exc).__name__, exc)

    async def async_log_success_event(self, kwargs: dict[str, Any], response_obj: Any, start_time: Any, end_time: Any) -> None:
        """Report each successful call's tokens to Moira's /usage.

        Moira learns how many tokens one percent of each quota window holds
        from these (moira capacity.ts), so it ranks providers by absolute
        capacity left. Provider usage reports are unreliable: Meta's stream
        omits usage on large prompts (logged as 0 input) and LiteLLM's
        Responses bridge drops reasoning from completion_tokens. So input
        falls back to request size (~4 chars/token) and output is
        completion + reasoning when reasoning exceeds completion. Best effort.
        """
        slo = kwargs.get("standard_logging_object")
        if not isinstance(slo, dict):
            return
        model = slo.get("model_group")
        if not isinstance(model, str) or not model:
            return
        prompt = slo.get("prompt_tokens") if isinstance(slo.get("prompt_tokens"), int) else 0
        completion = slo.get("completion_tokens") if isinstance(slo.get("completion_tokens"), int) else 0
        usage = (slo.get("metadata") or {}).get("usage_object") if isinstance(slo.get("metadata"), dict) else None
        details = usage.get("completion_tokens_details") if isinstance(usage, dict) else None
        reasoning = details.get("reasoning_tokens") if isinstance(details, dict) else None
        reasoning = reasoning if isinstance(reasoning, int) else 0
        if prompt <= 0:
            body = kwargs.get("messages") or kwargs.get("input")
            if body:
                try:
                    chars = len(json.dumps(body, default=str))
                except (TypeError, ValueError):
                    chars = 0
                params = kwargs.get("litellm_params")
                psr = params.get("proxy_server_request") if isinstance(params, dict) else None
                request = psr.get("body") if isinstance(psr, dict) and isinstance(psr.get("body"), dict) else {}
                session = extract_session_id({**request, "proxy_server_request": psr})
                prompt = _new_input_chars(f"{model}|{session}" if session else None, chars) // 4
        output = completion + reasoning if reasoning > completion else completion
        tokens = prompt + output
        if tokens <= 0:
            return
        url = (os.environ.get("MOIRA_DECIDE_URL") or "").removesuffix("/decide") + "/usage"
        token = os.environ.get("MOIRA_DECIDE_TOKEN")
        try:
            await _moira_client.post(
                url,
                json={"model": model, "tokens": tokens},
                headers={"Authorization": f"Bearer {token}"} if token else {},
            )
        except Exception as exc:  # reporting is best effort
            logger.warning("Moira usage report failed (%s: %s)", type(exc).__name__, exc)


moira_router = MoiraRouter()


class DeploymentAdapter(CustomLogger):
    """Per-deployment request adaptation after LiteLLM picks a deployment.

    Runs once per attempt (primary, same-group retry, fallback), after the
    router has selected a deployment, so each attempt sees its own
    `model_info` and adapts independently. Five adaptations:

    - `supports_forced_tool_choice: false` softens a forced tool_choice
      (a dict, or the string "required") to "auto". Evidence: MiMo V2.6 Pro
      returns a different tool call than the forced one (2026-09-25 probe),
      and Step 5 Preview honoured a named forced tool_choice 1/3.
    - `max_output_tokens` clamps max_tokens / max_completion_tokens /
      max_output_tokens to the deployment's output cap.
    - `requires_leading_system_message: true` prepends an empty system
      message when the first message is not system/developer. CodeBuddy's
      Hy4 returns 400 (11128 "first message is not system prompt") without
      one and accepts an empty one (2026-10-08).
    - `system_as_string: true` joins an Anthropic `system` given as text
      blocks (and system messages with list content) into one string. The
      ChatGPT backend rejects the block form on /v1/messages ("System
      messages are not allowed", 400) and accepts the string (2026-10-09).
    - `metadata.moira_efforts` (set by moira_router) sets the reasoning effort
      Moira chose for this attempt's model group, so a fallback runs at its
      own in-band effort rather than the primary's.
    Nothing else: unsupported parameters stay with LiteLLM's native
    drop_params. Unknown or missing model_info is a no-op. The router reuses
    the request kwargs across attempts, so every change is written into a NEW
    dict over shallow-copied containers; nested objects are never mutated.
    """

    async def async_pre_call_deployment_hook(self, kwargs: dict[str, Any], call_type: Any) -> dict | None:
        info = None
        deployment = None
        for key in ("metadata", "litellm_metadata"):
            bucket = kwargs.get(key)
            if isinstance(bucket, dict) and isinstance(bucket.get("model_info"), dict):
                info = bucket["model_info"]
                deployment = bucket.get("deployment_model_name")
                break
        if info is None:
            return None
        deployment = (
            deployment
            or info.get("litellm_model_name")
            or info.get("model_name")
            or "?"
        )

        out = dict(kwargs)
        changed = False

        tool_choice = out.get("tool_choice")
        forced = tool_choice == "required" or isinstance(tool_choice, dict)
        if forced and info.get("supports_forced_tool_choice") is False:
            out["tool_choice"] = "auto"
            changed = True
            logger.info(
                "deployment_adapter: %s softened forced tool_choice to 'auto' "
                "(supports_forced_tool_choice: false)",
                deployment,
            )

        messages = out.get("messages")
        if info.get("requires_leading_system_message") is True and isinstance(messages, list):
            first = messages[0] if messages else None
            if not (isinstance(first, dict) and first.get("role") in ("system", "developer")):
                out["messages"] = [{"role": "system", "content": ""}, *messages]
                changed = True
                logger.info("deployment_adapter: %s prepended empty system message", deployment)

        if info.get("system_as_string") is True:
            system = out.get("system")
            joined = _join_text_blocks(system)
            if joined is not None:
                out["system"] = joined
                changed = True
                logger.info("deployment_adapter: %s joined system blocks into a string", deployment)
            messages = out.get("messages")
            if isinstance(messages, list):
                fixed = []
                for m in messages:
                    text = _join_text_blocks(m.get("content")) if isinstance(m, dict) and m.get("role") == "system" else None
                    fixed.append({**m, "content": text} if text is not None else m)
                    changed = changed or text is not None
                out["messages"] = fixed

        efforts = None
        model_group = None
        for key in ("metadata", "litellm_metadata"):
            bucket = kwargs.get(key)
            if isinstance(bucket, dict):
                efforts = efforts or bucket.get("moira_efforts")
                model_group = model_group or bucket.get("model_group")
        if isinstance(efforts, dict) and isinstance(model_group, str) and model_group in efforts:
            wanted = efforts[model_group]
            if isinstance(wanted, str) and wanted:
                # chat_reasoning_effort may have produced reasoning_effort from a
                # `reasoning` object, so both forms can be present: set each.
                effort_changed = False
                reasoning = out.get("reasoning")
                if isinstance(reasoning, dict) and reasoning.get("effort") != wanted:
                    out["reasoning"] = {**reasoning, "effort": wanted}
                    effort_changed = True
                if (not isinstance(reasoning, dict) or "reasoning_effort" in out) and out.get("reasoning_effort") != wanted:
                    out["reasoning_effort"] = wanted
                    effort_changed = True
                if effort_changed:
                    changed = True
                    logger.info("deployment_adapter: %s reasoning effort -> %s (moira)", model_group, wanted)

        cap = info.get("max_output_tokens")
        if isinstance(cap, int) and cap > 0:
            for key in ("max_tokens", "max_completion_tokens", "max_output_tokens"):
                value = out.get(key)
                if isinstance(value, int) and not isinstance(value, bool) and value > cap:
                    out[key] = cap
                    changed = True
                    logger.info(
                        "deployment_adapter: %s clamped %s %d -> %d (max_output_tokens)",
                        deployment, key, value, cap,
                    )

        return out if changed else None


deployment_adapter = DeploymentAdapter()


def _join_text_blocks(value: Any) -> str | None:
    """A list of only text blocks as one string ("\\n\\n"-joined); else None."""
    if not isinstance(value, list) or not value:
        return None
    texts = []
    for block in value:
        if not (isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str)):
            return None
        texts.append(block["text"])
    return "\n\n".join(texts)


class ToolDescriptionSanitizer(CustomLogger):
    """Drop `"description": null` from function tools.

    LiteLLM's MCP-to-OpenAI tool conversion emits `description: null` for MCP
    tools that omit a description (MCP allows that; siren's 74 generated tools
    do). llama.cpp b11223+ rejects the null in its tool parser ("type must be
    string, but is null"), failing every local-model request that carries
    such a tool. Omitting the key is valid OpenAI tool schema.

    The router reuses request kwargs across attempts, so the tools list and
    the touched tool/function dicts are copied, never mutated.
    """

    async def async_pre_call_deployment_hook(self, kwargs: dict[str, Any], call_type: Any) -> dict | None:
        tools = kwargs.get("tools")
        if not isinstance(tools, list):
            return None
        cleaned: list[Any] = []
        changed = False
        for tool in tools:
            function = tool.get("function") if isinstance(tool, dict) else None
            if isinstance(function, dict) and "description" in function and function["description"] is None:
                function = {k: v for k, v in function.items() if k != "description"}
                tool = {**tool, "function": function}
                changed = True
            cleaned.append(tool)
        if not changed:
            return None
        return {**kwargs, "tools": cleaned}


tool_description_sanitizer = ToolDescriptionSanitizer()


class ToolCallContentNormalizer(CustomLogger):
    """Send `content: null` for assistant turns that only carry tool calls.

    Clients (omp) replay tool-call turns with `content: ""`. On Anthropic
    routes LiteLLM rewrites every empty text to the literal block "[System:
    Empty message content sanitised to satisfy protocol]" (factory.py
    `_sanitize_empty_text_content`, not gated by modify_params), so the model
    sees that line before each of its own tool calls and starts writing it.
    `null` beside `tool_calls` is the OpenAI-specified form; LiteLLM then emits
    only the tool_use blocks. Turns without tool calls are left alone: there
    the placeholder is what keeps Anthropic from rejecting an empty turn.

    Copies the touched messages; the router reuses kwargs across attempts.
    """

    async def async_pre_call_deployment_hook(self, kwargs: dict[str, Any], call_type: Any) -> dict | None:
        messages = kwargs.get("messages")
        if not isinstance(messages, list):
            return None
        cleaned: list[Any] = []
        changed = False
        for message in messages:
            if (
                isinstance(message, dict)
                and message.get("role") == "assistant"
                and message.get("tool_calls")
                and _blank_content(message.get("content"))
                and message.get("content") is not None
            ):
                message = {**message, "content": None}
                changed = True
            cleaned.append(message)
        if not changed:
            return None
        return {**kwargs, "messages": cleaned}


def _blank_content(content: Any) -> bool:
    """True for "", whitespace, [] or a list of only blank text blocks."""
    if isinstance(content, str):
        return not content.strip()
    if isinstance(content, list):
        return all(
            isinstance(block, dict) and block.get("type") == "text"
            and not (isinstance(block.get("text"), str) and block["text"].strip())
            for block in content
        )
    return content is None


tool_call_content_normalizer = ToolCallContentNormalizer()


class SpendLogResponseId(CustomLogger):
    """Unique spend-log ids for deployments whose response ids repeat.

    LiteLLM keys LiteLLM_SpendLogs.request_id on the provider's response id
    and inserts with skip_duplicates. Ollama Cloud's /v1 returns ids like
    `chatcmpl-167` (three digits), so after the first ~1000 calls almost every
    Ollama row collided with an older one and was silently dropped (2026-10-09:
    ~200 Ollama calls in 10 minutes, 8 rows). Deployments flagged
    `unique_response_ids: false` in model_info get `<provider id>-<litellm_call_id>`
    in the logged result; the response the client received is unchanged.
    async_logging_hook runs on every CustomLogger before any success logger.
    """

    async def async_logging_hook(self, kwargs: dict, result: Any, call_type: str) -> tuple[dict, Any]:
        params = kwargs.get("litellm_params")
        info = None
        for bucket_name in ("metadata", "litellm_metadata"):
            bucket = params.get(bucket_name) if isinstance(params, dict) else None
            if isinstance(bucket, dict) and isinstance(bucket.get("model_info"), dict):
                info = bucket["model_info"]
                break
        if info is None or info.get("unique_response_ids") is not False:
            return kwargs, result
        call_id = kwargs.get("litellm_call_id")
        if not isinstance(call_id, str) or not call_id:
            return kwargs, result

        def unique(obj: Any) -> None:
            current = obj.get("id") if isinstance(obj, dict) else getattr(obj, "id", None)
            if not isinstance(current, str) or not current or current.endswith(call_id):
                return
            new = f"{current}-{call_id}"
            if isinstance(obj, dict):
                obj["id"] = new
            else:
                try:
                    obj.id = new
                except (AttributeError, TypeError, ValueError):
                    pass

        unique(result)
        unique(kwargs.get("async_complete_streaming_response"))
        unique(kwargs.get("complete_streaming_response"))
        unique(kwargs.get("standard_logging_object"))
        return kwargs, result


spend_log_response_id = SpendLogResponseId()
