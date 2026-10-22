"""LiteLLM proxy hook for the shared EnMaaS proxy (claude-enmaas / codex-t3-enmaas).

Codex can send tools as a Responses input item {"type": "additional_tools",
"tools": [...]} (deferred/namespaced tools). vLLM-served `rits/` models reject
that item, so it is flattened into the request's `tools` list: function tools
are kept (also those nested in a namespace), other kinds are dropped with the
item. Only `rits/` models are touched; GPT and Claude traffic passes through.

Load it as a dotted module next to the proxy config (LiteLLM splits the
callback on '.', so a file path or `file.py:name` cannot work):

    litellm_settings:
      callbacks: ["unwrap_tools_middleware.proxy_handler_instance"]

A failure in here must never break a request: it is logged and the request goes
on unchanged.
"""

import logging

from litellm.integrations.custom_logger import CustomLogger

LOG = logging.getLogger("unwrap_tools_middleware")
MODEL_PREFIXES = ("rits/",)


def flatten_additional_tools(data):
    """Move function tools out of `additional_tools` input items into `tools`.
    Returns True when the request changed."""
    items = data.get("input")
    if not isinstance(items, list):
        return False
    extracted = []
    kept = []
    found = False
    for item in items:
        if not (isinstance(item, dict) and item.get("type") == "additional_tools"):
            kept.append(item)
            continue
        found = True
        for tool in item.get("tools") or []:
            if not isinstance(tool, dict):
                continue
            if tool.get("type") == "namespace":
                extracted.extend(
                    t
                    for t in tool.get("tools") or []
                    if isinstance(t, dict) and t.get("type") == "function"
                )
            elif tool.get("type") == "function":
                extracted.append(tool)
    if not found:
        return False
    if extracted:
        data["tools"] = list(data.get("tools") or []) + extracted
    data["input"] = kept
    return True


class UnwrapAdditionalToolsMiddleware(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        try:
            if str(data.get("model") or "").startswith(MODEL_PREFIXES):
                flatten_additional_tools(data)
        except Exception:
            LOG.exception("unwrap_tools_middleware: left the request unchanged")
        return data


proxy_handler_instance = UnwrapAdditionalToolsMiddleware()
