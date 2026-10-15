"""LiteLLM proxy hooks for the GLM hybrid proxies (scripts/glm-hybrid-proxy.zsh).

Both apply to GLM (rits/...) requests only; other models (the gpt-6-luna
reviewer) pass through untouched.

1. Responses custom tools (codex flavor): EnMaaS serves GLM through vLLM, which
   rejects custom tools that carry a grammar format ("only free-form text
   custom tools are supported"). Codex declares apply_patch as such a tool.
   Dropping the grammar keeps it a free-form text custom tool; Codex still
   parses the patch body itself.

2. Messages without a thinking field (claude flavor): Anthropic semantics are
   "no thinking unless requested", but GLM reasons by default. Claude Code's
   auto-mode classifier sends ~40k-token prompts with no thinking field and a
   2112-token stage-1 cap; GLM then reasons 1.5-2k tokens for 20-27s, gets
   truncated or exceeds the client's wall-clock limit, and auto mode reports
   the classifier as "temporarily unavailable (timed out)". Setting
   thinking={type: disabled} restores the Anthropic meaning. Main turns, which
   send thinking explicitly, are unchanged.
"""

from litellm.integrations.custom_logger import CustomLogger

GLM_MODEL_PREFIXES = ("rits/",)


class GlmHybridHooks(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        model = str(data.get("model") or "")
        if not model.startswith(GLM_MODEL_PREFIXES):
            return data
        for tool in data.get("tools") or []:
            if isinstance(tool, dict) and tool.get("type") == "custom":
                fmt = tool.get("format")
                if isinstance(fmt, dict) and fmt.get("type") == "grammar":
                    tool.pop("format", None)
        if "messages" in data and "input" not in data and data.get("thinking") is None:
            data["thinking"] = {"type": "disabled"}
        return data


proxy_handler_instance = GlmHybridHooks()
