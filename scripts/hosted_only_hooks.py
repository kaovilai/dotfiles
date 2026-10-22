"""LiteLLM proxy hooks for the hosted-only proxies (scripts/hosted-only-proxy.zsh).

Applies to EnMaaS-hosted vLLM models (rits/...: GLM and DeepSeek) only; other
models pass through untouched. Env knobs are HOSTED_ONLY_*; each also reads its
retired GLM_HYBRID_* name as a fallback.

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
   the classifier as "temporarily unavailable (timed out)". GLM 5.3 is a
   thinking-only model, so thinking={type: disabled} does not turn reasoning
   off: it cuts it to about one sentence (9-14 output tokens on a 26k-token
   prompt, vs 130-270 without it), which is what keeps the classifier inside
   the time limit. chat_template_kwargs.enable_thinking=false is ignored.
   Main turns, which send thinking explicitly, are unchanged. DeepSeek V4.1
   Flash honors disabled fully (no thinking block at all).

3. Vision fallback: GLM is text-only and answers 400 "not a multimodal model"
   to any request with an image anywhere in its history. Such requests are
   re-routed to the DeepSeek route (vision capable, same hosted tier). Only
   requests that actually carry an image move, so real GLM errors are never
   masked. HOSTED_ONLY_VISION_FALLBACK=0 turns this off; HOSTED_ONLY_GLM_MODEL /
   HOSTED_ONLY_DEEPSEEK_MODEL name the two models (set by the proxy launcher).

4. Empty instruction items (codex flavor): Codex appends a developer message
   with empty text when a UserPromptSubmit hook returns empty
   additionalContext. DeepSeek on vLLM rejects an empty developer/system item
   that follows a user item with 500 "Invalid message for role `developer`:
   content ''". Such items carry nothing, so they are dropped from input.

5. Rate-limit rewrite (all models, both flavors): EnMaaS 429s carry no reset
   time, so T3 Code cannot auto-resume a limited thread. A 429 is rewritten
   into the shape each client's T3 adapter turns into a reset time, plus a
   `retry-after` header. Reset time, in order:
   - upstream `retry-after` (seconds or HTTP-date), when the 429 carries one;
   - praxis-proxy `reject_budget_exhausted()` (filters/src/metering/mod.rs):
     429, plain-text body exactly `token budget exhausted`, no headers. That
     is the monthly token quota (pricetag-metering internal/storage/quota.go
     buckets by `date_trunc('month', NOW())`, assumed UTC) -> first instant of
     the next UTC month;
   - any other 429 (per-minute RPM/TPM; GLM is reportedly 100 RPM / 1M TPM)
     -> now + HOSTED_ONLY_RATE_LIMIT_DEFAULT_RETRY_SECONDS (default 60).
   Other statuses are never touched (503 `metering system unavailable` is not
   a limit). HOSTED_ONLY_LIMIT_REWRITE=0 turns this off.
   - Claude (/v1/messages): 503 whose message reads `[<model>] [429]:
     {"type":"error","error":{"type":"rate_limit_error",...}} (reset after
     1h 2m 3s)`, the text T3's ClaudeAdapterV2 parses for a gateway limit.
     Claude Code only emits `rate_limit_event` for claude.ai subscription
     auth, not for a gateway/API-key 429, so the native path is unavailable.
     Waits over HOSTED_ONLY_CLIENT_RETRY_MAX_SECONDS (default 60) also get
     `x-should-retry: false` so Claude Code stops retrying (its SDK would
     sleep for as long as `retry-after`, up to ~24 days); T3 holds and
     resumes. Shorter waits stay retryable inside Claude Code.
   - Codex (/v1/responses): 429 `usage_limit_reached` plus
     `x-codex-primary-{used-percent,window-minutes,reset-at}` headers, which
     Codex 0.163.0 (codex-api api_bridge.rs/rate_limits.rs) turns into
     UsageLimitReached + an `account/rateLimits/updated` snapshot with
     resetsAt, the input of T3's codexUsageLimitResetAt. Codex does not retry
     that error.
"""

import email.utils
import json
import math
import os
import re
import time
from datetime import datetime, timezone

from fastapi import HTTPException
from litellm.integrations.custom_logger import CustomLogger

def knob(name, default):
    """HOSTED_ONLY_<name>, else the retired GLM_HYBRID_<name>, else default."""
    return os.environ.get(f"HOSTED_ONLY_{name}") or os.environ.get(
        f"GLM_HYBRID_{name}", default
    )


def int_knob(name, default, minimum):
    try:
        return max(minimum, int(knob(name, str(default))))
    except ValueError:
        return default


GLM_MODEL_PREFIXES = ("rits/",)
GLM_MODEL = knob("GLM_MODEL", os.environ.get("GLM_HYBRID_MODEL", "rits/zai-org/glm-5-3"))
DEEPSEEK_MODEL = knob("DEEPSEEK_MODEL", "rits/deepseek-ai/DeepSeek-V4.1-Flash-1017")
VISION_FALLBACK = knob("VISION_FALLBACK", "1") != "0"
IMAGE_BLOCK_TYPES = ("image", "input_image", "image_url")
LIMIT_REWRITE = knob("LIMIT_REWRITE", "1") != "0"
LIMIT_DEFAULT_RETRY_SECONDS = int_knob("RATE_LIMIT_DEFAULT_RETRY_SECONDS", 60, 1)
CLIENT_RETRY_MAX_SECONDS = int_knob("CLIENT_RETRY_MAX_SECONDS", 60, 0)
BUDGET_EXHAUSTED_TEXT = "token budget exhausted"
# Last reset handed out per model: LiteLLM's router cools a deployment down
# after a 429 and answers the next requests itself (RouterRateLimitError), with
# no upstream body, so those reuse the reset the real 429 produced.
LAST_LIMIT_RESET = {}


def has_image(node):
    """True if any content block, however nested, is an image."""
    if isinstance(node, dict):
        if node.get("type") in IMAGE_BLOCK_TYPES:
            return True
        return any(has_image(v) for v in node.values() if isinstance(v, (dict, list)))
    if isinstance(node, list):
        return any(has_image(v) for v in node)
    return False


def is_empty_instruction(item):
    """True for a developer/system Responses input item with only empty text."""
    if not isinstance(item, dict) or item.get("role") not in ("developer", "system"):
        return False
    content = item.get("content")
    if isinstance(content, str):
        return not content.strip()
    if isinstance(content, list):
        return all(
            isinstance(b, dict)
            and b.get("type") in ("input_text", "text")
            and not str(b.get("text") or "").strip()
            for b in content
        )
    return content is None


def status_of(exc):
    for name in ("status_code", "code"):
        try:
            return int(getattr(exc, name))
        except (AttributeError, TypeError, ValueError):
            pass
    return None


def exc_text(exc):
    return str(getattr(exc, "message", None) or exc)


def upstream_retry_after(exc, now):
    """Epoch seconds from an upstream `retry-after` (seconds or HTTP-date)."""
    for source in (exc, getattr(exc, "response", None)):
        headers = getattr(source, "headers", None) or getattr(
            source, "litellm_response_headers", None
        )
        if not headers:
            continue
        try:
            raw = headers.get("retry-after")
        except AttributeError:
            continue
        if not raw:
            continue
        try:
            seconds = float(raw)
        except ValueError:
            try:
                return email.utils.parsedate_to_datetime(str(raw)).timestamp()
            except (TypeError, ValueError):
                continue
        if seconds > 0:
            return now + seconds
    return None


def month_bounds(now):
    """(start, next start) of the UTC calendar month containing `now`, epoch s."""
    at = datetime.fromtimestamp(now, timezone.utc)
    start = datetime(at.year, at.month, 1, tzinfo=timezone.utc)
    nxt = datetime(at.year + (at.month == 12), at.month % 12 + 1, 1, tzinfo=timezone.utc)
    return start.timestamp(), nxt.timestamp()


def limit_reset(exc, model, now):
    """(reset epoch seconds, monthly?) for a 429; see item 5 of the docstring."""
    after = upstream_retry_after(exc, now)
    if after is not None:
        return after, False
    text = exc_text(exc)
    if BUDGET_EXHAUSTED_TEXT in text.lower():
        return month_bounds(now)[1], True
    if type(exc).__name__ == "RouterRateLimitError" or "No deployments available" in text:
        last = LAST_LIMIT_RESET.get(model)
        if last is not None and last > now:
            return last, False
    return now + LIMIT_DEFAULT_RETRY_SECONDS, False


def format_wait(seconds):
    hours, rest = divmod(seconds, 3600)
    minutes, secs = divmod(rest, 60)
    return " ".join(
        f"{n}{unit}" for n, unit in ((hours, "h"), (minutes, "m"), (secs, "s")) if n
    )


def rewrite_limit(exc, request_data, now=None):
    """HTTPException replacing a 429, or None to leave the error as it is."""
    if status_of(exc) != 429:
        return None
    now = time.time() if now is None else now
    model = str(request_data.get("model") or "")
    reset, monthly = limit_reset(exc, model, now)
    LAST_LIMIT_RESET[model] = reset
    seconds = max(1, math.ceil(reset - now))
    reason = "Monthly token budget exhausted." if monthly else "Rate limit reached."
    url = str((request_data.get("proxy_server_request") or {}).get("url") or "")
    if "/v1/messages" in url:
        body = json.dumps(
            {"type": "error", "error": {"type": "rate_limit_error", "message": reason}},
            separators=(",", ":"),
        )
        message = f"[{model}] [429]: {body} (reset after {format_wait(seconds)})"
        # litellm's /v1/messages handler discards the hook's return value and
        # rebuilds the error from the original exception, so edit that in
        # place; the response headers are added by ResetAfterHeaders below.
        for name, value in (("status_code", 503), ("message", message), ("type", "api_error")):
            try:
                setattr(exc, name, value)
            except AttributeError:
                pass
        return HTTPException(status_code=503, detail=message)
    window = (
        round((month_bounds(now)[1] - month_bounds(now)[0]) / 60)
        if monthly
        else math.ceil(seconds / 60)
    )
    out = HTTPException(
        status_code=429,
        detail=f"{reason} Try again in {format_wait(seconds)}.",
        headers={
            "retry-after": str(seconds),
            "x-codex-primary-used-percent": "100",
            "x-codex-primary-window-minutes": str(window),
            "x-codex-primary-reset-at": str(math.ceil(reset)),
        },
    )
    out.type = "usage_limit_reached"
    return out


RESET_AFTER_RE = re.compile(
    rb"\[429\]: .*\(reset after (?:(\d+)h ?)?(?:(\d+)m ?)?(?:(\d+)s)?\)"
)


def reset_after_seconds(body):
    match = RESET_AFTER_RE.search(body)
    if not match:
        return None
    h, m, s = (int(g or 0) for g in match.groups())
    return (h * 3600 + m * 60 + s) or None


class ResetAfterHeaders:
    """ASGI wrapper adding `retry-after` (and, for long waits,
    `x-should-retry: false`) to the 503 written by rewrite_limit on
    /v1/messages, where litellm gives hooks no way to set response headers.
    Waits up to HOSTED_ONLY_CLIENT_RETRY_MAX_SECONDS (default 60) stay
    retryable: Claude Code's SDK sleeps `retry-after` and retries, so short
    per-minute bursts never stop the turn, and if its retries run out the final
    error still carries "reset after". Longer waits get `x-should-retry: false`
    so Claude Code fails at once instead of sleeping for days; T3 Code then
    holds the thread and resumes at the reset time."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        held = None

        async def wrapped(message):
            nonlocal held
            if message["type"] == "http.response.start" and message["status"] == 503:
                held = message
                return
            if held is not None:
                start, held = held, None
                if message["type"] == "http.response.body" and not message.get("more_body"):
                    seconds = reset_after_seconds(message.get("body") or b"")
                    if seconds:
                        extra = [(b"retry-after", str(seconds).encode())]
                        if seconds > CLIENT_RETRY_MAX_SECONDS:
                            extra.append((b"x-should-retry", b"false"))
                        start = {**start, "headers": [*start.get("headers", []), *extra]}
                await send(start)
            await send(message)

        await self.app(scope, receive, wrapped)


def install_reset_after_headers():
    """Wrap the proxy app once. The app's middleware stack is built at startup,
    normally before callbacks load (the pre-call hook retries for a late import)."""
    try:
        from litellm.proxy.proxy_server import app
    except Exception:
        return
    stack = getattr(app, "middleware_stack", None)
    if stack is not None and not isinstance(stack, ResetAfterHeaders):
        app.middleware_stack = ResetAfterHeaders(stack)


class HostedOnlyHooks(CustomLogger):
    async def async_post_call_failure_hook(
        self, request_data, original_exception, user_api_key_dict, traceback_str=None
    ):
        if not LIMIT_REWRITE:
            return None
        try:
            return rewrite_limit(original_exception, request_data)
        except Exception:
            return None

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        if LIMIT_REWRITE:
            install_reset_after_headers()
        model = str(data.get("model") or "")
        if not model.startswith(GLM_MODEL_PREFIXES):
            return data
        if (
            VISION_FALLBACK
            and model == GLM_MODEL
            and DEEPSEEK_MODEL != GLM_MODEL
            and has_image(data.get("messages") or data.get("input"))
        ):
            data["model"] = DEEPSEEK_MODEL
        for tool in data.get("tools") or []:
            if isinstance(tool, dict) and tool.get("type") == "custom":
                fmt = tool.get("format")
                if isinstance(fmt, dict) and fmt.get("type") == "grammar":
                    tool.pop("format", None)
        if "messages" in data and "input" not in data and data.get("thinking") is None:
            data["thinking"] = {"type": "disabled"}
        if isinstance(data.get("input"), list):
            data["input"] = [i for i in data["input"] if not is_empty_instruction(i)]
        return data


proxy_handler_instance = HostedOnlyHooks()
if LIMIT_REWRITE:
    install_reset_after_headers()
