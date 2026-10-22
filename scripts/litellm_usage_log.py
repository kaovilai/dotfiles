"""LiteLLM proxy callback: one JSONL line per request, for `llm-usage`.

Wire into a proxy config as a dotted module next to the config file (LiteLLM
1.97 loads `litellm_settings.callbacks` entries from the config's directory,
else from sys.path):

    litellm_settings:
      callbacks: ["litellm_usage_log.proxy_handler_instance"]

Events append to ${LLM_USAGE_DIR:-~/.local/state/llm-usage}/events-YYYY-MM.jsonl
(0600, O_APPEND, one write per line so concurrent proxies don't interleave).
Prompts, completions, keys and header values are never stored; only metadata:
requested model (the name the client asked for), served model (the deployment
LiteLLM actually called), upstream host, token counts, latency, status.

Failures also record `upstream_status` (what the provider answered, e.g. 429
from EnMaaS), `status` (what the client sees), `rewritten`, `retry_after`
(seconds) and `error_type`. Rewritten 429s add `reset_at` (epoch s),
`reset_source` (which upstream header/body field, or which estimate rule, set
it) and, only when upstream sends limit data the hooks do not parse, `drift`;
see docs/notes/enmaas-reset-forward-compat.md. Callback order matters: LiteLLM runs the logging
callbacks when the upstream call raises, *before* the proxy's
async_post_call_failure_hook (hosted_only_hooks.rewrite_limit, which turns a
429 into a 503 "(reset after ...)" for /v1/messages and edits the exception
in place). So the usual view here is the original 429, and the rewrite is
predicted with the hooks' own limit_reset(); if the logger ever runs late and
sees the already-rewritten 503, the "[429]: ... (reset after Xh Ym Zs)" text
is parsed back into upstream 429 + retry_after.

Token fields use Anthropic semantics so every source lines up: `in` is the
fresh (uncached) prompt, `cache_read`/`cache_write` are separate, and the full
context size is in + cache_read + cache_write.

In-flight requests: log_pre_api_call records (litellm_call_id, start, model) in
${state dir}/inflight-<port>-<pid>.json (atomic rewrite, 0600, one file per
proxy process so workers never race); the success/failure callback removes the
id. `llm-usage menubar-data` reads these files and ignores entries older than
INFLIGHT_STALE_S or owned by a dead pid, so a crash or restart leaves nothing
behind for long. Only proxies started with this version report in-flight.

Logging must never break a request: every failure is swallowed.
"""

import json
import math
import os
import re
import sys
import threading
import time
from datetime import datetime, timezone
from urllib.parse import urlparse

from litellm.integrations.custom_logger import CustomLogger

INFLIGHT_STALE_S = 900  # entries older than this are leftovers (crash, client gone), not requests
CLASSIFIER_MARKER = "security monitor for autonomous AI coding agents"


def _state_dir():
    base = os.environ.get("LLM_USAGE_DIR")
    if base:
        return base
    return os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "llm-usage")


def _proxy_port():
    argv = sys.argv
    for i, arg in enumerate(argv):
        if arg == "--port" and i + 1 < len(argv):
            return argv[i + 1]
        if arg.startswith("--port="):
            return arg.split("=", 1)[1]
    return os.environ.get("PORT") or ""


def _get(obj, *names, default=None):
    """First present attribute/key among names, tolerant of dicts and objects."""
    for name in names:
        if isinstance(obj, dict):
            if obj.get(name) is not None:
                return obj[name]
        elif obj is not None:
            value = getattr(obj, name, None)
            if value is not None:
                return value
    return default


def _int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def _usage(response_obj):
    usage = _get(response_obj, "usage")
    if usage is None:
        return {}
    details = _get(usage, "prompt_tokens_details")
    completion_details = _get(usage, "completion_tokens_details")
    return {
        "prompt": _int(_get(usage, "prompt_tokens", "input_tokens")),
        "completion": _int(_get(usage, "completion_tokens", "output_tokens")),
        "cache_read": _int(_get(usage, "cache_read_input_tokens") or _get(details, "cached_tokens")),
        "cache_write": _int(_get(usage, "cache_creation_input_tokens")),
        "reasoning": _int(_get(completion_details, "reasoning_tokens") or _get(usage, "reasoning_tokens")),
        "anthropic_native": _get(usage, "input_tokens") is not None and _get(usage, "prompt_tokens") is None,
    }


def _headers(kwargs, slo):
    litellm_params = kwargs.get("litellm_params") or {}
    candidates = [
        (litellm_params.get("metadata") or {}).get("headers"),
        (kwargs.get("proxy_server_request") or {}).get("headers"),
        (litellm_params.get("proxy_server_request") or {}).get("headers"),
        ((slo.get("metadata") or {}).get("requester_metadata") or {}).get("headers"),
    ]
    for candidate in candidates:
        if isinstance(candidate, dict) and candidate:
            return {str(k).lower(): v for k, v in candidate.items()}
    return {}


def _client(user_agent):
    ua = (user_agent or "").lower()
    if "claude-cli" in ua or "claude-code" in ua or "anthropic" in ua:
        return "claude-code"
    if "codex" in ua:
        return "codex"
    if "t3" in ua:
        return "t3"
    if "curl" in ua:
        return "curl"
    return ua.split("/")[0][:24] or "unknown"


def _head_text(kwargs):
    parts = []
    system = kwargs.get("system")
    if system is None:
        system = (kwargs.get("optional_params") or {}).get("system")
    if system is not None:
        parts.append(system if isinstance(system, str) else json.dumps(system, default=str)[:2000])
    for message in (kwargs.get("messages") or [])[:2]:
        content = message.get("content") if isinstance(message, dict) else None
        if isinstance(content, str):
            parts.append(content[:2000])
        elif content is not None:
            parts.append(json.dumps(content, default=str)[:2000])
    return " ".join(parts)[:4000]


def _ms(start, end):
    try:
        return round((end - start).total_seconds() * 1000)
    except Exception:
        return None


def _iso(value):
    if isinstance(value, datetime):
        if value.tzinfo is None:
            value = value.astimezone()
        return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(value, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    return None


RESET_AFTER_RE = re.compile(r"\[429\]: .*\(reset after (?:(\d+)h ?)?(?:(\d+)m ?)?(?:(\d+)s)?\)", re.S)
QUOTA_RE = re.compile(r"token budget exhausted|monthly token budget", re.I)


def _status(exc):
    for name in ("status_code", "code"):
        try:
            return int(getattr(exc, name))
        except (AttributeError, TypeError, ValueError):
            pass
    return None


def _hooks_module():
    """The glm/hosted-only hooks module when it is loaded in this proxy."""
    try:
        import litellm
        for callback in litellm.callbacks:
            if type(callback).__name__ in ("GlmHybridHooks", "HostedOnlyHooks"):
                return sys.modules.get(type(callback).__module__)
    except Exception:
        pass
    return None


def _is_limit(hooks, exc):
    """Non-429 limit answers (Copilot-style 402 / 503 `upstream rate limited` /
    error.code `rate_limited`) as the hooks classify them."""
    check = getattr(hooks, "is_limit_error", None)
    try:
        return bool(check and check(exc))
    except Exception:
        return False


def error_fields(kwargs, slo):
    """status / upstream_status / rewritten / retry_after / error_type / quota for a failed call."""
    exc = kwargs.get("exception")
    info = slo.get("error_information") or {}
    message = str(info.get("error_message") or _get(exc, "message") or exc or "")
    out = {"error_type": (info.get("error_class") or (type(exc).__name__ if exc is not None else None)) or None}
    upstream = _int(info.get("error_code")) or _status(exc) or None
    client = upstream
    match = RESET_AFTER_RE.search(message)
    if match:  # already rewritten (logger ran after the hook)
        h, m, s = (int(g or 0) for g in match.groups())
        out["retry_after"] = h * 3600 + m * 60 + s
        upstream, client = 429, 503
        out["rewritten"] = True
        out["reset_source"] = "unknown:rewritten"
        out["reset_at"] = int(time.time()) + out["retry_after"]
    elif upstream == 429 or _is_limit(_hooks_module(), exc):
        hooks = _hooks_module()
        if hooks is not None and getattr(hooks, "LIMIT_REWRITE", False):
            url = str((kwargs.get("proxy_server_request") or {}).get("url") or "")
            client = 503 if "/v1/messages" in url else 429
            out["rewritten"] = True
            try:
                now = time.time()
                model = str(kwargs.get("model") or "")
                analyze = getattr(hooks, "analyze_limit", None)
                if analyze is not None:
                    info = analyze(exc, model, now)
                    reset, monthly = info["reset"], info["monthly"]
                    out["reset_source"] = info["source"]
                    if info["drift"]:
                        out["drift"] = info["drift"]
                        getattr(hooks, "warn_drift", lambda _d: None)(info["drift"])
                else:
                    reset, monthly = hooks.limit_reset(exc, model, now)
                out["reset_at"] = int(reset)
                out["retry_after"] = max(1, math.ceil(reset - now))
                if monthly:
                    out["quota"] = True
                    if "/v1/chat/completions" in url:  # hooks answer a monthly quota with 402 here
                        client = 402
            except Exception:
                pass
    if upstream == 429 and QUOTA_RE.search(message):
        out["quota"] = True
    if upstream:
        out["upstream_status"] = upstream
    if client:
        out["status"] = client
    return out


def build_event(kwargs, response_obj, start_time, end_time, ok):
    slo = kwargs.get("standard_logging_object") or {}
    litellm_params = kwargs.get("litellm_params") or {}
    meta = litellm_params.get("metadata") or {}
    optional = kwargs.get("optional_params") or {}
    headers = _headers(kwargs, slo)
    usage = _usage(response_obj)

    cache_read = usage.get("cache_read") or _int(slo.get("cache_read_input_tokens"))
    cache_write = usage.get("cache_write") or _int(slo.get("cache_creation_input_tokens"))
    completion = _int(slo.get("completion_tokens")) or usage.get("completion", 0)
    total_prompt = _int(slo.get("prompt_tokens")) or usage.get("prompt", 0)
    # LiteLLM's standardized prompt_tokens includes cached tokens (OpenAI
    # semantics); the Anthropic-native `input_tokens` does not.
    fresh = total_prompt if usage.get("anthropic_native") and not slo.get("prompt_tokens") else max(total_prompt - cache_read - cache_write, 0)

    api_base = slo.get("api_base") or litellm_params.get("api_base") or ""
    host = urlparse(api_base).netloc or api_base
    requested = slo.get("model_group") or meta.get("model_group") or kwargs.get("model")
    served = slo.get("model") or kwargs.get("model")
    provider = slo.get("custom_llm_provider") or litellm_params.get("custom_llm_provider")
    if provider and isinstance(served, str) and served.startswith(provider + "/"):
        served = served[len(provider) + 1:]
    previous = meta.get("previous_models") or []

    start = _iso(start_time)
    first = slo.get("completionStartTime")
    ttft = None
    try:
        if first and start_time:
            ttft = round((first - start_time).total_seconds() * 1000) if isinstance(first, datetime) else round((float(first) - start_time.timestamp()) * 1000)
    except Exception:
        ttft = None

    head = _head_text(kwargs)
    tools = optional.get("tools") or kwargs.get("tools") or []
    error = None
    if not ok:
        error = str(slo.get("error_str") or kwargs.get("exception") or "")[:300]

    event = {
        "ts": _iso(end_time) or _iso(datetime.now(timezone.utc)),
        "start": start,
        "port": _proxy_port(),
        "call_type": slo.get("call_type") or kwargs.get("call_type"),
        "client": _client(headers.get("user-agent")),
        "ua": (headers.get("user-agent") or "")[:80],
        "requested": requested,
        "served": served,
        "response_model": _get(response_obj, "model"),
        "provider": provider,
        "upstream": host,
        "ok": bool(ok),
        "error": error,
        "ms": _ms(start_time, end_time),
        "ttft_ms": ttft,
        "in": fresh,
        "out": completion,
        "cache_read": cache_read,
        "cache_write": cache_write,
        "reasoning": usage.get("reasoning", 0),
        "cost": slo.get("response_cost"),
        "stream": bool(kwargs.get("stream") or optional.get("stream")),
        "tools": len(tools) if isinstance(tools, list) else 0,
        "max_tokens": optional.get("max_tokens") or kwargs.get("max_tokens"),
        "thinking": (optional.get("thinking") or {}).get("type") if isinstance(optional.get("thinking"), dict) else None,
        "role": "classifier" if CLASSIFIER_MARKER in head else None,
        "fallback": bool(previous),
    }
    if ok:
        event["status"] = 200
    else:
        event.update(error_fields(kwargs, slo))
    return {k: v for k, v in event.items() if v is not None}


def _pid_alive(pid):
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except (PermissionError, ValueError, TypeError):
        return True
    return True


class UsageLog(CustomLogger):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._lock = threading.Lock()
        self._inflight = {}
        self._inflight_dir = None
        self._cleanup_inflight()

    # -- in-flight table ------------------------------------------------------
    def _inflight_path(self):
        return os.path.join(_state_dir(), f"inflight-{_proxy_port() or 'unknown'}-{os.getpid()}.json")

    def _cleanup_inflight(self):
        """Drop in-flight files left by dead proxy processes on this port (and any older instance of this pid)."""
        try:
            import glob
            for path in glob.glob(os.path.join(_state_dir(), f"inflight-{_proxy_port() or 'unknown'}-*.json")):
                pid = path.rsplit("-", 1)[-1].split(".")[0]
                if pid == str(os.getpid()) or not _pid_alive(pid):
                    os.remove(path)
        except Exception:
            pass

    def _inflight_flush(self):
        """Caller holds self._lock."""
        now = time.time()
        self._inflight = {k: v for k, v in self._inflight.items() if now - v["t"] <= INFLIGHT_STALE_S}
        directory = _state_dir()
        os.makedirs(directory, mode=0o700, exist_ok=True)
        path = self._inflight_path()
        tmp = f"{path}.tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.write(fd, json.dumps({"pid": os.getpid(), "port": _proxy_port(), "updated": now, "requests": self._inflight},
                                    separators=(",", ":")).encode())
        finally:
            os.close(fd)
        os.replace(tmp, path)

    def _inflight_start(self, call_id, model, requested):
        try:
            if not call_id:
                return
            with self._lock:
                self._inflight[str(call_id)] = {"t": time.time(), "model": model, "requested": requested}
                self._inflight_flush()
        except Exception:
            pass

    def _inflight_end(self, kwargs):
        try:
            slo = kwargs.get("standard_logging_object") or {}
            call_id = kwargs.get("litellm_call_id") or slo.get("id")
            if not call_id:
                return
            with self._lock:
                if self._inflight.pop(str(call_id), None) is not None:
                    self._inflight_flush()
        except Exception:
            pass

    def log_pre_api_call(self, model, messages, kwargs):
        try:
            params = (kwargs or {}).get("litellm_params") or {}
            requested = (params.get("metadata") or {}).get("model_group") or model
            self._inflight_start((kwargs or {}).get("litellm_call_id"), model, requested)
        except Exception:
            pass

    def _write(self, kwargs, response_obj, start_time, end_time, ok):
        self._inflight_end(kwargs)
        try:
            event = build_event(kwargs, response_obj, start_time, end_time, ok)
            # LiteLLM also reports its internal MCP tool listing/calls here; not LLM traffic.
            if "mcp" in str(event.get("call_type") or "").lower() or str(event.get("requested") or "").startswith("MCP:"):
                return
            directory = _state_dir()
            os.makedirs(directory, mode=0o700, exist_ok=True)
            path = os.path.join(directory, f"events-{event['ts'][:7]}.jsonl")
            line = (json.dumps(event, separators=(",", ":"), default=str) + "\n").encode()
            with self._lock:
                fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
                try:
                    os.write(fd, line)
                finally:
                    os.close(fd)
        except Exception:
            pass

    def log_success_event(self, kwargs, response_obj, start_time, end_time):
        self._write(kwargs, response_obj, start_time, end_time, True)

    def log_failure_event(self, kwargs, response_obj, start_time, end_time):
        self._write(kwargs, response_obj, start_time, end_time, False)

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        self._write(kwargs, response_obj, start_time, end_time, True)

    async def async_log_failure_event(self, kwargs, response_obj, start_time, end_time):
        self._write(kwargs, response_obj, start_time, end_time, False)


proxy_handler_instance = UsageLog()
