"""LiteLLM proxy hooks for the shared EnMaaS proxy (claude-enmaas, codex-t3-enmaas).

The shared proxy serves Claude Code (/v1/messages), Codex (/v1/responses) and
chat clients (/v1/chat/completions) from one port. Load it AFTER
hosted_only_hooks (whose vision fallback may swap GLM for DeepSeek first) as a
dotted module next to the proxy config:

    litellm_settings:
      callbacks: ["enmaas_proxy_hooks.proxy_handler_instance"]

1. Dialect per endpoint. EnMaaS-hosted vLLM models (GLM, DeepSeek) are routed
   as `anthropic/<id>` at the gateway root, which Claude Code needs; GPT ids on
   the Responses dialect are routed as `openai/responses/<id>`, a chat->Responses
   bridge that would send its `responses/` prefix upstream on a native
   /v1/responses call. Codex needs the plain Responses passthrough
   (`openai/<id>` at /v1: reasoning items, custom tools, images), so a
   /v1/responses request for such an id is re-pointed at the sibling deployment
   `<id>#responses`. The proxy config registers a sibling for every such id; the
   set is read from the `*#responses` entries of the config.json next to this
   module, plus ENMAAS_RESPONSES_ROUTES (comma separated). Every other model and
   endpoint is untouched; Claude ids are native.

2. Hosted web search (`web_search`, `web_search_preview` tools) on `rits/`
   models: vLLM accepts the tool and silently ignores it, so the model neither
   searches nor knows it cannot and answers from stale training data. The tools
   are dropped, and hosted_only_hooks (loaded first) replaces them with an
   in-band note telling the model to route the lookup to a search-capable
   provider. GPT keeps its native web search. Codex cannot gate this per model
   (its `web_search` setting is global), so it happens here as a backstop.

A failure in here must never break a request: it is logged and the request goes
on unchanged.
"""

import json
import logging
import os

from litellm.integrations.custom_logger import CustomLogger

LOG = logging.getLogger("enmaas_proxy_hooks")
SUFFIX = "#responses"
RESPONSES_CALL_TYPES = ("responses", "aresponses")
HOSTED_PREFIXES = ("rits/",)


def load_routes():
    routes = {r.strip() for r in os.environ.get("ENMAAS_RESPONSES_ROUTES", "").split(",") if r.strip()}
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")) as stream:
            for row in json.load(stream).get("model_list", []):
                name = str(row.get("model_name") or "")
                if name.endswith(SUFFIX) and len(name) > len(SUFFIX):
                    routes.add(name[: -len(SUFFIX)])
    except (OSError, ValueError, AttributeError):
        LOG.warning("enmaas_proxy_hooks: no readable config.json beside the hook; using ENMAAS_RESPONSES_ROUTES only")
    return frozenset(routes)


ROUTES = load_routes()


def route_model(model, call_type):
    """The deployment name to use for this model on this endpoint."""
    if call_type in RESPONSES_CALL_TYPES and model in ROUTES:
        return model + SUFFIX
    return model


def drop_web_search(data):
    """Remove hosted web search tools; True when the request changed."""
    tools = data.get("tools")
    if not isinstance(tools, list):
        return False
    kept = [
        t
        for t in tools
        if not (isinstance(t, dict) and str(t.get("type") or "").startswith("web_search"))
    ]
    if len(kept) == len(tools):
        return False
    if kept:
        data["tools"] = kept
    else:
        data.pop("tools", None)
        data.pop("tool_choice", None)
    return True


class EnmaasProxyHooks(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        try:
            model = str(data.get("model") or "")
            if model.startswith(HOSTED_PREFIXES):
                drop_web_search(data)
            routed = route_model(model, call_type)
            if routed != model:
                data["model"] = routed
        except Exception:
            LOG.exception("enmaas_proxy_hooks: left the request unchanged")
        return data


proxy_handler_instance = EnmaasProxyHooks()
