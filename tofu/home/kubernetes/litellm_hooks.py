"""LiteLLM deployment hooks for Aether.

Mounted beside config.yaml and registered in litellm_settings.callbacks.
"""

from typing import Any

from litellm.integrations.custom_logger import CustomLogger


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
