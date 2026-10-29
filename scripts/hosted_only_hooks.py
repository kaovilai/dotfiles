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
   `retry-after` header. Reset time, in order (parse_reset_headers /
   parse_reset_body; the winning one is logged as `reset_source`):
   - what upstream sends, most specific first: `retry-after-ms`, `retry-after`
     (seconds or HTTP-date), JSON body `error.{reset_at,resets_at,
     reset_after_seconds,retry_after}`, OpenAI `x-ratelimit-reset-*` (praxis
     token_rate_limit's `X-RateLimit-Reset-Tokens`, LiteLLM's), Anthropic
     `anthropic-ratelimit-*-reset`, Copilot `x-usage-ratelimit-{session,weekly}`
     (`rem=<n>&rst=<ISO>`), IETF `RateLimit`/`RateLimit-Reset`, `reset_at`.
     An upstream error type/reason (`insufficient_quota`, `monthly_*`, ...) sets
     quota vs rate limit; an upstream reset over 24 h out counts as quota. It
     also drives the client rewrite below, and rate-limit headers clients
     already read (`retry-after-ms`, `x-ratelimit-*`, `RateLimit-*`) are passed
     through on the 429 routes (not on the Claude 503, whose headers the
     handler fixes, nor the chat 402, which must not look retryable);
   - praxis-proxy `reject_budget_exhausted()` (filters/src/metering/mod.rs):
     429, plain-text body exactly `token budget exhausted`, no headers. That
     is the monthly token quota (pricetag-metering internal/storage/quota.go
     buckets by `date_trunc('month', NOW())`, assumed UTC) -> first instant of
     the next UTC month;
   - any other 429 (per-minute RPM/TPM; GLM is reportedly 100 RPM / 1M TPM)
     -> now + HOSTED_ONLY_RATE_LIMIT_DEFAULT_RETRY_SECONDS (default 60).
   Other statuses are never touched, except Copilot-style limit answers (402;
   503 `upstream rate limited`; any status with error.code `rate_limited`; see
   is_limit_error): 503 `metering system unavailable` is not a limit. HOSTED_ONLY_LIMIT_REWRITE=0 turns this off.
   Drift: when upstream starts sending limit data this code does not parse (an
   unknown rate/retry/reset/quota/limit header or JSON key, an unrecognised
   JSON body, a monthly reset that is not the next UTC month start, a
   quota/rate-limit classification that disagrees with ours) the event records
   `drift` and the proxy log gets one WARNING per signal per lifetime. Contract:
   docs/notes/enmaas-reset-forward-compat.md.
   - Claude (/v1/messages): 503 whose message reads `[<model>] [429]:
     {"type":"error","error":{"type":"rate_limit_error",...}} (reset after
     1h 2m 3s)`, the text T3's ClaudeAdapterV2 parses for a gateway limit.
     Claude Code only emits `rate_limit_event` for claude.ai subscription
     auth, not for a gateway/API-key 429, so the native path is unavailable.
     Waits over HOSTED_ONLY_CLIENT_RETRY_MAX_SECONDS (default 60) also get
     `x-should-retry: false`. Claude Code's main loop already gives up when
     retry-after > 60 s (`api_request_retry_after_too_long`), so the header
     matters for its SDK-level retries (side queries), which would otherwise
     honor retry-after up to ~24.8 days on a 503. T3 holds and resumes.
     Waits <= 60 s stay retryable: Claude Code sleeps retry-after (exactly 60
     still sleeps) up to 10 times (~10 min) before the error surfaces.
   - Codex (/v1/responses): 429 `usage_limit_reached` plus
     `x-codex-primary-{used-percent,window-minutes,reset-at}` headers, which
     Codex 0.163.0 (codex-api api_bridge.rs/rate_limits.rs) turns into
     UsageLimitReached + an `account/rateLimits/updated` snapshot with
     resetsAt, the input of T3's codexUsageLimitResetAt. Codex does not retry
     that error. The 429 body also carries `error.resets_at` (epoch s, copied
     from the reset-at header by ResetAfterHeaders): Codex reads only that
     field from the body for its "Try again at <date>" text.
   - OpenAI chat (/v1/chat/completions, OpenCode via the AI SDK): per-minute
     limits stay 429 + `retry-after` seconds (OpenCode waits that long, up to 5
     retries). The monthly quota becomes HTTP 402 `insufficient_quota`, message
     "Monthly token budget exhausted. Quota resets <ISO>.", no `retry-after`:
     the AI SDK retries every 429 and would sleep the ~9-day retry-after, and
     only a non-retryable status stops it. The text avoids OpenCode's retry
     regexes (session/retry.ts: 429/500/502/503/504/524, rate limit, try again,
     overloaded, resource exhausted, at capacity).

6. Image budget prune (all models, every endpoint): praxis caps each request
   body at 10 MiB (DEFAULT_MAX_BODY_BYTES; redhat-et/pricetag-metering#115)
   and answers 413. Claude Code and Codex resend the whole history every
   turn with every viewed image inline as base64 (Codex's only AttachmentStore
   in the open-source tree is the inline passthrough; its compaction is
   token-based and prices each image at ~1.8k tokens whatever its bytes), so a
   review loop that renders and views a few slides per round crosses the cap
   after ~50 images even when every image was shrunk to 1000 px (thread
   53d71f17, 2026-10-28: 54 images, 9.9 MB base64). When the content fields
   serialize to more than HOSTED_ONLY_IMAGE_BUDGET_BYTES (default 8 MiB; 0
   turns this off), inline image blocks are replaced oldest-first with a text
   block until the body fits. The text names where the image still lives, so
   the model can re-view it on demand: the path from the tool call that
   produced it (Codex view_image `path`, Claude Read `file_path`, matched by
   call_id / tool_use_id), the T3 attachment file when the bytes match one in
   ~/.t3/userdata/attachments (a pasted image), and a copy this proxy keeps in
   HOSTED_ONLY_IMAGE_CACHE_DIR (default $XDG_STATE_HOME/hosted-only-image-cache,
   content-addressed, expired after HOSTED_ONLY_IMAGE_CACHE_DAYS, default 5;
   0 keeps no copies). The same bytes always give the same text, so the
   replaced prefix stays stable for prompt caching across turns.
"""

import base64
import email.utils
import hashlib
import json
import logging
import math
import os
import re
import time
from datetime import datetime, timezone
from urllib.parse import parse_qs

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
IMAGE_BUDGET_BYTES = int_knob("IMAGE_BUDGET_BYTES", 8 * 1024 * 1024, 0)
IMAGE_CACHE_DAYS = int_knob("IMAGE_CACHE_DAYS", 5, 0)
IMAGE_CACHE_DIR = knob(
    "IMAGE_CACHE_DIR",
    os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
        "hosted-only-image-cache",
    ),
)
T3_ATTACHMENTS_DIR = os.path.expanduser("~/.t3/userdata/attachments")
PRUNE_MARKER = "[image-pruned]"
LIMIT_DEFAULT_RETRY_SECONDS = int_knob("RATE_LIMIT_DEFAULT_RETRY_SECONDS", 60, 1)
CLIENT_RETRY_MAX_SECONDS = int_knob("CLIENT_RETRY_MAX_SECONDS", 60, 0)
BUDGET_EXHAUSTED_TEXT = "token budget exhausted"
# Last reset handed out per model: LiteLLM's router cools a deployment down
# after a 429 and answers the next requests itself (RouterRateLimitError), with
# no upstream body, so those reuse the reset the real 429 produced.
LAST_LIMIT_RESET = {}
LAST_LIMIT_KIND = {}


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


def image_payload(block):
    """(base64 text, mime) of an inline image block; None for URLs/file ids."""
    kind = block.get("type")
    if kind == "input_image":
        url = block.get("image_url")
    elif kind == "image_url":
        url = block.get("image_url")
        if isinstance(url, dict):
            url = url.get("url")
    elif kind == "image":
        source = block.get("source")
        if not isinstance(source, dict) or source.get("type") != "base64":
            return None
        data = source.get("data")
        if not isinstance(data, str) or not data:
            return None
        return data, str(source.get("media_type") or "image/png")
    else:
        return None
    if not isinstance(url, str) or not url.startswith("data:"):
        return None
    header, sep, data = url.partition(",")
    if not sep or ";base64" not in header or not data:
        return None
    return data, header[len("data:"):].split(";", 1)[0] or "image/png"


def collect_image_blocks(node, out, parent=None, key=None, anchor=None):
    """Inline image blocks in document order as (parent list, index, block,
    id of the enclosing tool call/result), oldest first."""
    if isinstance(node, dict):
        if node.get("type") in IMAGE_BLOCK_TYPES and image_payload(node):
            if isinstance(parent, list):
                out.append((parent, key, node, anchor))
            return
        own = node.get("call_id") or node.get("tool_use_id")
        if isinstance(own, str):
            anchor = own
        for k, v in node.items():
            if isinstance(v, (dict, list)):
                collect_image_blocks(v, out, node, k, anchor)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            collect_image_blocks(v, out, node, i, anchor)


def _path_from_args(args):
    if isinstance(args, str):
        try:
            args = json.loads(args)
        except ValueError:
            return None
    if not isinstance(args, dict):
        return None
    for name in ("path", "file_path", "image_path", "image"):
        value = args.get(name)
        if isinstance(value, str) and value.strip() and "/" in value:
            return value.strip()
    return None


def tool_path_index(data):
    """tool call id -> file path argument, for Responses function_call items,
    Anthropic tool_use blocks and chat tool_calls."""
    index = {}
    for item in data.get("input") if isinstance(data.get("input"), list) else []:
        if isinstance(item, dict) and item.get("type") == "function_call":
            path = _path_from_args(item.get("arguments"))
            if path and isinstance(item.get("call_id"), str):
                index[item["call_id"]] = path
    for message in data.get("messages") if isinstance(data.get("messages"), list) else []:
        if not isinstance(message, dict):
            continue
        for block in message.get("content") if isinstance(message.get("content"), list) else []:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                path = _path_from_args(block.get("input"))
                if path and isinstance(block.get("id"), str):
                    index[block["id"]] = path
        for call in message.get("tool_calls") if isinstance(message.get("tool_calls"), list) else []:
            if isinstance(call, dict):
                path = _path_from_args((call.get("function") or {}).get("arguments"))
                if path and isinstance(call.get("id"), str):
                    index[call["id"]] = path
    return index


_ATTACHMENT_INDEX = {"stamp": None, "by_sha": {}, "hashed": {}}


def attachment_match(sha, directory=None):
    """Path of a T3 attachment whose bytes hash to sha, else None. Files are
    hashed once per (size, mtime); the index is rebuilt when the dir changes."""
    directory = directory or T3_ATTACHMENTS_DIR
    try:
        stamp = (directory, os.stat(directory).st_mtime_ns)
    except OSError:
        return None
    state = _ATTACHMENT_INDEX
    if state["stamp"] != stamp:
        by_sha, hashed = {}, state["hashed"]
        with os.scandir(directory) as entries:
            for entry in entries:
                if not entry.is_file(follow_symlinks=False):
                    continue
                if not entry.name.lower().endswith((".png", ".jpg", ".jpeg", ".gif", ".webp")):
                    continue
                st = entry.stat(follow_symlinks=False)
                key = (entry.path, st.st_size, st.st_mtime_ns)
                digest = hashed.get(key)
                if digest is None:
                    try:
                        with open(entry.path, "rb") as stream:
                            digest = hashlib.sha1(stream.read()).hexdigest()
                    except OSError:
                        continue
                    hashed[key] = digest
                by_sha[digest] = entry.path
        live = set(by_sha.values())
        state["hashed"] = {k: v for k, v in hashed.items() if k[0] in live}
        state["by_sha"], state["stamp"] = by_sha, stamp
    return state["by_sha"].get(sha)


_CACHE_SWEEP = {"at": 0.0}
_MIME_EXT = {"image/jpeg": "jpg", "image/jpg": "jpg", "image/gif": "gif", "image/webp": "webp"}


def cache_image(raw, sha, mime, directory=None, days=None, now=None):
    """Keep a copy of pruned image bytes at <dir>/<sha>.<ext>; returns the path
    or None when caching is off or failed. Expired copies are swept hourly."""
    days = IMAGE_CACHE_DAYS if days is None else days
    directory = directory or IMAGE_CACHE_DIR
    if days <= 0:
        return None
    now = time.time() if now is None else now
    try:
        os.makedirs(directory, mode=0o700, exist_ok=True)
        path = os.path.join(directory, f"{sha}.{_MIME_EXT.get(mime, 'png')}")
        if os.path.exists(path):
            os.utime(path, (now, now))
        else:
            tmp = f"{path}.{os.getpid()}.tmp"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as stream:
                stream.write(raw)
            os.replace(tmp, path)
        if now - _CACHE_SWEEP["at"] > 3600:
            _CACHE_SWEEP["at"] = now
            cutoff = now - days * 86400
            with os.scandir(directory) as entries:
                for entry in entries:
                    try:
                        if entry.is_file(follow_symlinks=False) and entry.stat().st_mtime < cutoff:
                            os.unlink(entry.path)
                    except OSError:
                        pass
        return path
    except OSError as error:
        LOG.warning("hosted_only_hooks: image cache unavailable: %s", error)
        return None


def prune_placeholder(source, attachment, cached):
    where = []
    if source:
        where.append(f"source file {source}")
    if attachment:
        where.append(f"T3 attachment {attachment}")
    if cached:
        where.append(f"proxy copy {cached} (kept {IMAGE_CACHE_DAYS} days)")
    tail = ("; it is still at " + ", ".join(where) + ". View that path again if you need the image.") if where else (
        ". Re-create and view it again if you need it.")
    return f"{PRUNE_MARKER} Image removed by the local proxy to keep this request under the gateway's body limit{tail}"


def prune_replacement(block, text):
    kind = block.get("type")
    if kind == "input_image":
        return {"type": "input_text", "text": text}
    return {"type": "text", "text": text}


CONTENT_KEYS = ("messages", "input", "system", "instructions", "tools")


def content_size(data):
    """Approximate serialized size of the request's content fields (the body
    LiteLLM sends upstream, minus its own bookkeeping keys)."""
    size = 0
    for key in CONTENT_KEYS:
        value = data.get(key)
        if value is not None:
            size += len(json.dumps(value, separators=(",", ":")))
    return size


def prune_images(data, budget=None, cache_dir=None, cache_days=None, attachments_dir=None):
    """Replace inline images, oldest first, until the content fits the budget.
    Returns the number of images replaced."""
    budget = IMAGE_BUDGET_BYTES if budget is None else budget
    if budget <= 0 or not has_image(data.get("messages") or data.get("input")):
        return 0
    size = before = content_size(data)
    if size <= budget:
        return 0
    blocks = []
    collect_image_blocks(data.get("messages"), blocks)
    collect_image_blocks(data.get("input"), blocks)
    if not blocks:
        return 0
    index = tool_path_index(data)
    pruned = 0
    for parent, key, block, anchor in blocks:
        if size <= budget:
            break
        payload = image_payload(block)
        if payload is None or parent[key] is not block:
            continue
        encoded, mime = payload
        try:
            raw = base64.b64decode(encoded, validate=False)
        except (ValueError, TypeError):
            raw = None
        sha = hashlib.sha1(raw).hexdigest() if raw else None
        cached = cache_image(raw, sha, mime, cache_dir, cache_days) if raw else None
        attachment = attachment_match(sha, attachments_dir) if sha else None
        text = prune_placeholder(index.get(anchor), attachment, cached)
        parent[key] = prune_replacement(block, text)
        size -= len(encoded) - len(text)
        pruned += 1
    if pruned:
        LOG.warning(
            "hosted_only_hooks: pruned %d of %d inline images for %s (content %d -> ~%d bytes, budget %d)",
            pruned, len(blocks), data.get("model"), before, size, budget,
        )
    return pruned


# Hosted vLLM models (rits/) have no server-side web search: upstream accepts
# the tool, ignores it, and answers from stale weights. Dropping it silently
# leaves the model believing it searched. Drop the tool and say so in-band, so
# the model routes the lookup somewhere that can actually search (the same
# policy nudge-web-search-via-luna.sh applies at the harness level).
# HOSTED_ONLY_SEARCH_NUDGE=0 turns the note off.
SEARCH_TOOL_PREFIX = "web_search"
SEARCH_NOTE_MARKER = "[web-search-unavailable]"
SEARCH_NUDGE = knob("SEARCH_NUDGE", "1") != "0"


def strip_web_search_tools(data):
    """Remove hosted web_search tools; True when the request changed."""
    tools = data.get("tools")
    if not isinstance(tools, list):
        return False
    kept = [
        tool
        for tool in tools
        if not (
            isinstance(tool, dict)
            and str(tool.get("type") or "").startswith(SEARCH_TOOL_PREFIX)
        )
    ]
    if len(kept) == len(tools):
        return False
    if kept:
        data["tools"] = kept
    else:
        data.pop("tools", None)
        data.pop("tool_choice", None)
    return True


def search_note_text():
    """In-band note replacing the dropped tool: no search, route it instead."""
    route = os.environ.get("T3_WEB_SEARCH_DELEGATE", "").strip()
    provider, _, model = route.partition(":")
    if provider and model:
        where = f"T3 delegate_task with providerInstanceId={provider} model={model}"
    elif provider:
        where = f"T3 delegate_task with providerInstanceId={provider}"
    else:
        where = "a search-capable model or provider (for example T3 delegate_task)"
    return (
        f"{SEARCH_NOTE_MARKER} This model has no web search: the hosted upstream "
        "ignores the web_search tool, so it was removed for this request. Never "
        "claim to have searched, and never guess or invent a URL. When the task "
        "needs current information (news, releases, versions, prices, events) or "
        f"the user asks you to look something up, route the lookup to {where}: "
        "ask it to search, open every URL it returns, report findings with their "
        "URLs, drop dead/403/404 links, one URL per story. If no search-capable "
        "provider is available, say web search is unavailable instead of "
        "answering from memory. For a known URL, fetch it directly."
    )


def search_note_present(data):
    """True when this request already carries the note (retries, fallbacks)."""
    probe = {k: data.get(k) for k in ("system", "instructions", "messages", "input")}
    try:
        return SEARCH_NOTE_MARKER in json.dumps(probe)
    except (TypeError, ValueError):
        return False


def add_to_system(data, text):
    """Anthropic /v1/messages: top-level system string or text blocks."""
    system = data.get("system")
    if isinstance(system, str):
        data["system"] = [{"type": "text", "text": system}, {"type": "text", "text": text}]
        return True
    if isinstance(system, list):
        system.append({"type": "text", "text": text})
        return True
    if system is None:
        data["system"] = text
        return True
    return False


def add_to_instructions(data, text):
    """Responses: the instructions field, set or appended."""
    instructions = data.get("instructions")
    if isinstance(instructions, str) and instructions.strip():
        data["instructions"] = instructions + "\n\n" + text
        return True
    if instructions is None:
        data["instructions"] = text
        return True
    return False


def add_to_chat_messages(data, text):
    """Chat completions: extend the system message, else prepend one."""
    messages = data.get("messages")
    if not isinstance(messages, list):
        return False
    for message in messages:
        if isinstance(message, dict) and message.get("role") == "system":
            content = message.get("content")
            if isinstance(content, str):
                message["content"] = content + "\n\n" + text
            elif isinstance(content, list):
                content.append({"type": "text", "text": text})
            else:
                message["content"] = text
            return True
    messages.insert(0, {"role": "system", "content": text})
    return True


def add_to_responses_input(data, text):
    """Responses without an instructions field: prepend a developer item."""
    item = {"role": "developer", "content": [{"type": "input_text", "text": text}]}
    items = data.get("input")
    if isinstance(items, list):
        items.insert(0, item)
        return True
    if isinstance(items, str):
        data["input"] = [
            item,
            {"role": "user", "content": [{"type": "input_text", "text": items}]},
        ]
        return True
    return False


def inject_search_note(data, text, call_type=""):
    """Attach the note in the dialect this request already speaks."""
    kind = str(call_type or "")
    if "system" in data or "message" in kind:
        return add_to_system(data, text)
    if "instructions" in data or "input" in data or kind in ("responses", "aresponses"):
        # A developer item inside input survives every Responses upstream;
        # `instructions` support varies, so it is only the fallback.
        return add_to_responses_input(data, text) or add_to_instructions(data, text)
    if "messages" in data:
        return add_to_chat_messages(data, text)
    return False


def status_of(exc):
    for name in ("status_code", "code"):
        try:
            return int(getattr(exc, name))
        except (AttributeError, TypeError, ValueError):
            pass
    return None


def exc_text(exc):
    return str(getattr(exc, "message", None) or exc)


def month_bounds(now):
    """(start, next start) of the UTC calendar month containing `now`, epoch s."""
    at = datetime.fromtimestamp(now, timezone.utc)
    start = datetime(at.year, at.month, 1, tzinfo=timezone.utc)
    nxt = datetime(at.year + (at.month == 12), at.month % 12 + 1, 1, tzinfo=timezone.utc)
    return start.timestamp(), nxt.timestamp()


LOG = logging.getLogger("hosted_only_hooks")
LIMIT_KEY_RE = re.compile(r"rate|retry|reset|quota|limit", re.I)
# Headers that match LIMIT_KEY_RE but are not an upstream limit signal.
HEADER_IGNORED_RE = re.compile(
    r"^(x-litellm-|x-should-retry$|access-control-|x-stainless-|x-envoy-upstream-)"
)
# Limit headers we read for information only (no reset in them).
HEADER_INFO_RE = re.compile(
    r"^(x-ratelimit-(limit|remaining)(-[a-z-]+)?|ratelimit-(limit|remaining|policy)"
    r"|anthropic-ratelimit-[a-z0-9-]+-(limit|remaining)"
    r"|anthropic-ratelimit-unified-(status|representative-claim|fallback|fallback-percentage)"
    r"|rate_limit_type)$"
)
ANTHROPIC_DIMS = ("requests", "tokens", "input-tokens", "output-tokens")
BODY_RESET_KEYS = (
    "reset_at", "resets_at", "reset_after_seconds",
    "retry_after", "retry_after_seconds", "retry_after_ms",
)
BODY_INFO_KEYS = {"rate_limit_type"}
QUOTA_NAMES = {
    "insufficient_quota", "quota_exceeded", "quota_exhausted", "budget_exceeded",
    "billing_hard_limit_reached", "usage_limit_reached",
}
RATE_NAMES = {
    "rate_limit_exceeded", "rate_limit_error", "rate_limited", "too_many_requests",
    "requests", "tokens",
}
RATE_REASON_RE = re.compile(r"per_(second|minute|hour)|^(rpm|tpm)$|rate_limit", re.I)
LONG_WAIT_QUOTA_SECONDS = 86400  # an upstream reset this far out is a quota, not a rate limit
ESTIMATE_TOLERANCE_CAP = 300     # estimate vs upstream reset: max(60 s, min(5%, 5 min))
DURATION_RE = re.compile(r"(\d+(?:\.\d+)?)(ms|h|m|s)")
# Upstream limit signals already seen and warned about (kind, key); see warn_drift.
DRIFT_SEEN = set()


def parse_duration(raw):
    """Seconds from `6m0s` / `1h2m3.5s` / `250ms` (Go style, OpenAI x-ratelimit-reset-*)
    or a bare number (seconds, as praxis and LiteLLM send). None when unparseable."""
    raw = str(raw).strip()
    try:
        number = float(raw)
        return number if math.isfinite(number) else None
    except ValueError:
        pass
    parts = DURATION_RE.findall(raw)
    if not parts or "".join(n + u for n, u in parts) != raw:
        return None
    scale = {"h": 3600, "m": 60, "s": 1, "ms": 0.001}
    return sum(float(n) * scale[u] for n, u in parts)


def parse_when(raw, now):
    """Epoch seconds from an epoch (s or ms), RFC3339 or HTTP-date. A small bare number
    is a delta in seconds. None when unparseable."""
    if isinstance(raw, bool):
        return None
    if isinstance(raw, (int, float)) or re.fullmatch(r"\d+(\.\d+)?", str(raw).strip()):
        value = float(raw)
        if value > 1e12:
            return value / 1000
        return value if value > 1e9 else now + value
    text = str(raw).strip()
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
    except ValueError:
        pass
    try:
        return email.utils.parsedate_to_datetime(text).timestamp()
    except (TypeError, ValueError):
        return None


def norm_headers(exc):
    """{lowercase name: str value} of the upstream response headers on `exc`.
    LiteLLM prefixes forwarded provider headers with `llm_provider-`."""
    merged = {}
    for source in (getattr(exc, "response", None), exc):
        for attr in ("headers", "litellm_response_headers"):
            headers = getattr(source, attr, None)
            try:
                items = list(headers.items()) if headers else []
            except AttributeError:
                continue
            for name, value in items:
                name = str(name).lower()
                name = name.removeprefix("llm_provider-")
                merged.setdefault(name, str(value))
    return merged


def error_body(exc, text):
    """Parsed JSON error body (dict) of `exc`, else None. Plain text bodies give None."""
    body = getattr(exc, "body", None)
    if isinstance(body, dict):
        return body
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        data = json.loads(text[start : end + 1])
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def pick_reset(pairs):
    """pairs: [(dimension, reset epoch, remaining or None, header)]. The limit that is
    exhausted (remaining 0) decides, the slowest one if several; when remaining is not
    reported the earliest reset wins (a retry that is still limited costs one 429)."""
    exhausted = [p for p in pairs if p[2] is not None and p[2] <= 0]
    if exhausted:
        return max(exhausted, key=lambda p: p[1])
    return min(pairs, key=lambda p: p[1]) if pairs else None


def parse_reset_headers(headers, now):
    """Reset candidates from upstream headers: ([(rank, epoch, source)], handled names).
    Lower rank wins: retry-after-ms, retry-after, OpenAI x-ratelimit-reset-*, Anthropic
    anthropic-ratelimit-*-reset, IETF RateLimit/RateLimit-Reset, LiteLLM reset_at.
    praxis token_rate_limit sends Retry-After + X-RateLimit-{Limit,Remaining,Reset}-Tokens
    (reset = bare seconds); LiteLLM sends retry-after and x-ratelimit-reset-{input,output}-tokens
    (seconds) and a reset_at header. Update this function when EnMaaS sends anything else."""
    cands, handled = [], set()

    def add(rank, epoch, name):
        handled.add(name)
        if epoch is not None:
            cands.append((rank, epoch, f"upstream-header:{name}"))

    def remaining(name):
        raw = headers.get(name)
        number = parse_duration(raw) if raw is not None else None
        if raw is not None:
            handled.add(name)
        return number

    if "retry-after-ms" in headers:
        ms = parse_duration(headers["retry-after-ms"])
        add(0, now + ms / 1000 if ms and ms > 0 else None, "retry-after-ms")
    if "retry-after" in headers:
        raw = headers["retry-after"]
        seconds = parse_duration(raw)
        if seconds is None:
            add(1, parse_when(raw, now), "retry-after")
        else:
            add(1, now + seconds if seconds > 0 else None, "retry-after")
    openai = []
    for name in headers:
        match = re.fullmatch(r"x-ratelimit-reset-(.+)", name)
        if match:
            seconds = parse_duration(headers[name])
            handled.add(name)
            if seconds is not None:
                openai.append(
                    (match[1], now + seconds, remaining(f"x-ratelimit-remaining-{match[1]}"), name)
                )
    chosen = pick_reset(openai)
    if chosen:
        add(3, chosen[1], chosen[3])
    pairs = []
    for dim in ANTHROPIC_DIMS:
        name = f"anthropic-ratelimit-{dim}-reset"
        if name in headers:
            handled.add(name)
            when = parse_when(headers[name], now)
            if when is not None:
                pairs.append((dim, when, remaining(f"anthropic-ratelimit-{dim}-remaining"), name))
    if "anthropic-ratelimit-unified-reset" in headers:
        add(4, parse_when(headers["anthropic-ratelimit-unified-reset"], now),
            "anthropic-ratelimit-unified-reset")
    chosen = pick_reset(pairs)
    if chosen:
        add(5, chosen[1], chosen[3])
    for name in ("anthropic-ratelimit-unified-5h-reset", "anthropic-ratelimit-unified-7d-reset"):
        if name in headers:
            add(6, parse_when(headers[name], now), name)
    usage = []
    for scope in ("session", "weekly"):  # GitHub Copilot: `rem=<pct>&rst=<ISO>`
        name = f"x-usage-ratelimit-{scope}"
        if name not in headers:
            continue
        fields = parse_qs(headers[name])
        left = parse_duration(fields["rem"][0]) if "rem" in fields else None
        when = parse_when(fields["rst"][0], now) if "rst" in fields else None
        if when is not None:
            handled.add(name)
            usage.append((scope, when, left, name))
        elif left is not None:
            handled.add(name)
    chosen = pick_reset(usage)
    if chosen:
        add(6, chosen[1], chosen[3])
    if "ratelimit" in headers:  # draft-07 `reset=30` or draft-08 `"default";r=0;t=30`
        handled.add("ratelimit")
        found = []
        for item in re.split(r',\s*(?=")', headers["ratelimit"]):
            reset = re.search(r"(?:^|[;,\s])(?:reset|t)=(\d+(?:\.\d+)?)", item)
            left = re.search(r"(?:^|[;,\s])(?:remaining|r)=(\d+)", item)
            if reset:
                found.append((float(reset[1]), int(left[1]) if left else None))
        zero = [f for f in found if f[1] == 0]
        use = max(zero) if zero else (min(found) if found else None)
        if use:
            add(7, now + use[0], "ratelimit")
    if "ratelimit-reset" in headers:
        seconds = parse_duration(headers["ratelimit-reset"])
        add(7, now + seconds if seconds is not None else None, "ratelimit-reset")
    for name in ("reset_at", "x-ratelimit-reset"):
        if name in headers:
            add(8, parse_when(headers[name], now), name)
    return cands, handled


def body_kind(err):
    """'quota' / 'rate-limit' / None from error.reason, then type, then code."""
    reason = str(err.get("reason") or "").lower()
    if reason.startswith("monthly_") or reason in QUOTA_NAMES:
        return "quota"
    if reason and RATE_REASON_RE.search(reason):
        return "rate-limit"
    for field in ("type", "code"):
        value = str(err.get(field) or "").lower()
        if value in QUOTA_NAMES:
            return "quota"
        if value in RATE_NAMES:
            return "rate-limit"
    return None


def parse_reset_body(body, now):
    """(candidates, kind, handled keys) from a JSON error body shaped like our #107
    proposal: error.{reset_at,resets_at,reset_after_seconds,retry_after,type,code,reason}.
    Update this function when EnMaaS puts the reset anywhere else."""
    if not body:
        return [], None, set()
    err = body.get("error") if isinstance(body.get("error"), dict) else body
    cands, handled = [], set()
    for key in BODY_RESET_KEYS:
        if key in err:  # error.retry_after, else top-level (Copilot: both occur)
            raw = err[key]
        elif key in body:
            raw = body[key]
        else:
            continue
        handled.add(key)
        if key in ("reset_at", "resets_at"):
            epoch = parse_when(raw, now)
        else:
            seconds = parse_duration(raw)
            if seconds is not None and key == "retry_after_ms":
                seconds /= 1000
            epoch = now + seconds if seconds is not None and seconds > 0 else None
        if epoch is not None:
            cands.append((2, epoch, f"upstream-body:{key}"))
    return cands, body_kind(err), handled | BODY_INFO_KEYS


def month_estimate(now):
    return month_bounds(now)[1]


def drift_item(kind, detail, hint):
    return {"kind": kind, "detail": detail, "hint": hint}


def drift_key(item):
    """Dedupe key: unhandled_* and estimate_mismatch ignore the varying value."""
    detail = item["detail"]
    if item["kind"] in ("unhandled_header", "unhandled_body_field", "estimate_mismatch"):
        detail = re.split(r"[=:]", detail, maxsplit=1)[0]
    return (item["kind"], detail)


def warn_drift(drift):
    """One WARNING per (kind, key) per proxy lifetime, so it shows in the proxy log."""
    for item in drift:
        key = drift_key(item)
        if key in DRIFT_SEEN:
            continue
        DRIFT_SEEN.add(key)
        LOG.warning(
            "hosted_only_hooks DRIFT [%s] %s -- %s", item["kind"], item["detail"], item["hint"]
        )


UPSTREAM_RATE_LIMITED_TEXT = "upstream rate limited"


def is_limit_error(exc):
    """True for an upstream limit answer: 429; 402 (quota used up); 503 whose text
    says `upstream rate limited` (a limit, not a server fault; `metering system
    unavailable` is not); or any status whose JSON body has error.code
    `rate_limited` (GitHub Copilot shapes, docs/notes/copilot-api-429-handling.md)."""
    status = status_of(exc)
    if status in (429, 402):
        return True
    text = exc_text(exc)
    if status == 503 and UPSTREAM_RATE_LIMITED_TEXT in text.lower():
        return True
    body = error_body(exc, text)
    err = body.get("error") if body and isinstance(body.get("error"), dict) else body
    return bool(err) and str(err.get("code") or "").lower() == "rate_limited"


def analyze_limit(exc, model, now):
    """Everything known about a 429: {reset: epoch s, monthly: bool, kind:
    'quota'|'rate-limit', source, drift: [...], passthrough: {header: value}}.
    `source` is upstream-header:<name> | upstream-body:<field> | estimate:next-month-utc |
    estimate:default | reuse:last-reset. See docs/notes/enmaas-reset-forward-compat.md."""
    text = exc_text(exc)
    router = type(exc).__name__ == "RouterRateLimitError" or "No deployments available" in text
    headers = {} if router else norm_headers(exc)
    body = None if router else error_body(exc, text)
    cands, handled = parse_reset_headers(headers, now)
    bcands, upstream_kind, bhandled = parse_reset_body(body, now)
    cands = sorted(cands + bcands, key=lambda c: c[0])
    quota_text = BUDGET_EXHAUSTED_TEXT in text.lower() or status_of(exc) == 402
    ours_kind = "quota" if quota_text else "rate-limit"
    kind = upstream_kind or ours_kind
    inferred = False
    drift = []
    for name, value in headers.items():
        if (
            LIMIT_KEY_RE.search(name)
            and name not in handled
            and not HEADER_IGNORED_RE.match(name)
            and not HEADER_INFO_RE.match(name)
        ):
            drift.append(drift_item(
                "unhandled_header", f"{name}={value[:60]}",
                f"update hosted_only_hooks.parse_reset_headers to parse {name}",
            ))
    if body:
        err = body.get("error") if isinstance(body.get("error"), dict) else body
        for key in {*body, *err}:
            if LIMIT_KEY_RE.search(str(key)) and key not in bhandled:
                sample = str(err.get(key, body.get(key)))[:60]
                drift.append(drift_item(
                    "unhandled_body_field", f"{key}={sample}",
                    f"update hosted_only_hooks.parse_reset_body to parse {key}",
                ))
        if not bcands and upstream_kind is None and ours_kind != "quota":
            keys = ",".join(sorted(map(str, {*body, *err})))[:80]
            drift.append(drift_item(
                "shape_changed", f"json error body keys: {keys}",
                "update hosted_only_hooks.parse_reset_body / limit_reset: 429 body is no "
                "longer plain text and not recognised",
            ))
    if upstream_kind and upstream_kind != ours_kind:
        drift.append(drift_item(
            "kind_mismatch", f"upstream says {upstream_kind}, text rule says {ours_kind}",
            "update hosted_only_hooks.limit_reset: classify with the upstream error "
            "type/reason, not only the `token budget exhausted` text",
        ))
    if cands:
        _, reset, source = cands[0]
        if not upstream_kind and kind != "quota" and reset - now > LONG_WAIT_QUOTA_SECONDS:
            kind, inferred = "quota", True
        if kind == "quota" and not inferred:
            estimate = month_estimate(now)
            wait = max(reset - now, 0)
            tolerance = max(60, min(0.05 * wait, ESTIMATE_TOLERANCE_CAP))
            if abs(reset - estimate) > tolerance:
                shown = datetime.fromtimestamp(reset, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                drift.append(drift_item(
                    "estimate_mismatch",
                    f"next-month-utc: estimate {datetime.fromtimestamp(estimate, timezone.utc):%Y-%m-%dT%H:%M:%SZ}, upstream {shown}",
                    f"estimate rule next-month-utc is wrong: upstream says {shown}; update limit_reset",
                ))
    elif router and LAST_LIMIT_RESET.get(model, 0) > now:
        reset, source = LAST_LIMIT_RESET[model], "reuse:last-reset"
        kind = LAST_LIMIT_KIND.get(model, kind)
    elif kind == "quota":
        reset, source = month_estimate(now), "estimate:next-month-utc"
    else:
        reset, source = now + LIMIT_DEFAULT_RETRY_SECONDS, "estimate:default"
    passthrough = {}
    if source.startswith("upstream-"):
        for name, value in headers.items():
            if name == "retry-after-ms":
                passthrough[name] = str(max(1, math.ceil((reset - now) * 1000)))
            elif re.match(r"^(x-ratelimit-(limit|remaining|reset)-|ratelimit(-limit|-remaining|-policy|-reset)?$)", name):
                passthrough[name] = value
    return {
        "reset": reset, "monthly": kind == "quota", "kind": kind, "source": source,
        "drift": drift, "passthrough": passthrough,
    }


def limit_reset(exc, model, now):
    """(reset epoch seconds, monthly?) for a 429; see item 5 of the docstring."""
    info = analyze_limit(exc, model, now)
    warn_drift(info["drift"])
    return info["reset"], info["monthly"]


def format_wait(seconds):
    hours, rest = divmod(seconds, 3600)
    minutes, secs = divmod(rest, 60)
    return " ".join(
        f"{n}{unit}" for n, unit in ((hours, "h"), (minutes, "m"), (secs, "s")) if n
    )


def rewrite_limit(exc, request_data, now=None):
    """HTTPException replacing a 429, or None to leave the error as it is."""
    if not is_limit_error(exc):
        return None
    now = time.time() if now is None else now
    model = str(request_data.get("model") or "")
    info = analyze_limit(exc, model, now)
    warn_drift(info["drift"])
    reset, monthly = info["reset"], info["monthly"]
    LAST_LIMIT_RESET[model] = reset
    LAST_LIMIT_KIND[model] = info["kind"]
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
    if monthly and "/v1/chat/completions" in url:
        # OpenAI-compatible clients (OpenCode via @ai-sdk/openai-compatible)
        # retry every 429 and sleep `retry-after` for up to 24 days, and do not
        # read `insufficient_quota` from an HTTP error; a 402 is not retryable
        # there. Keep the text free of what OpenCode's retry regexes match
        # (429/500/502/503/504/524, "try again", "rate limit", ...). No
        # retry-after header either.
        stamp = datetime.fromtimestamp(reset, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        out = HTTPException(
            status_code=402,
            detail=f"Monthly token budget exhausted. Quota resets {stamp}.",
        )
        # litellm builds the body from `type` and takes `code` from the status
        # (proxy/common_request_processing.py:2758-2764), so code reads "402".
        out.type = "insufficient_quota"
        return out
    window = (
        round((month_bounds(now)[1] - month_bounds(now)[0]) / 60)
        if monthly
        else math.ceil(seconds / 60)
    )
    out = HTTPException(
        status_code=429,
        detail=f"{reason} Try again in {format_wait(seconds)}.",
        # upstream rate-limit headers clients already read (retry-after-ms,
        # x-ratelimit-*, RateLimit-*) go through; ours win on any clash
        headers={
            **info["passthrough"],
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


def add_resets_at(start, message):
    """(start, message) for a 429 rewrite_limit wrote for /v1/responses, with
    `error.resets_at` (epoch s) added to the JSON body, copied from the
    x-codex-primary-reset-at header: Codex reads only that field from the body
    for its "Try again at <date>" text. Content-length follows the new body.
    Anything that is not our rewrite (no such header, other `type`, body that
    does not parse) comes back untouched."""
    headers = start.get("headers") or []
    try:
        reset = int(
            next(v for k, v in headers if k.lower() == b"x-codex-primary-reset-at")
        )
        data = json.loads(message.get("body") or b"")
        err = data["error"]
        if err.get("type") != "usage_limit_reached":
            return start, message
    except (StopIteration, KeyError, ValueError, TypeError, AttributeError):
        return start, message
    err["resets_at"] = reset
    body = json.dumps(data, separators=(",", ":")).encode()
    headers = [
        (k, str(len(body)).encode() if k.lower() == b"content-length" else v)
        for k, v in headers
    ]
    return {**start, "headers": headers}, {**message, "body": body}


class ResetAfterHeaders:
    """ASGI wrapper adding `retry-after` (and, for long waits,
    `x-should-retry: false`) to the 503 written by rewrite_limit on
    /v1/messages, where litellm gives hooks no way to set response headers.
    It also adds `error.resets_at` to our rewritten 429 `usage_limit_reached`
    bodies (add_resets_at); every other response passes through unchanged.
    Waits up to HOSTED_ONLY_CLIENT_RETRY_MAX_SECONDS (default 60) stay
    retryable: Claude Code's main loop sleeps `retry-after` and retries, so
    short per-minute bursts never stop the turn, and if its retries run out the
    final error still carries "reset after". Longer waits get
    `x-should-retry: false`: the main loop already fails at once above 60 s,
    and the header stops its SDK-level retries (side queries) from sleeping for
    days; T3 Code then holds the thread and resumes at the reset time."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        held = None

        async def wrapped(message):
            nonlocal held
            if message["type"] == "http.response.start" and message["status"] in (429, 503):
                held = message
                return
            if held is not None:
                start, held = held, None
                if message["type"] == "http.response.body" and not message.get("more_body"):
                    if start["status"] == 429:
                        start, message = add_resets_at(start, message)
                    seconds = (
                        reset_after_seconds(message.get("body") or b"")
                        if start["status"] == 503
                        else None
                    )
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
        try:
            prune_images(data)
        except Exception:
            LOG.exception("hosted_only_hooks: image prune skipped")
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
        if SEARCH_NUDGE and strip_web_search_tools(data) and not search_note_present(data):
            inject_search_note(data, search_note_text(), call_type)
        # Why thinking is disabled here (docstring item 2 has the full story):
        # Anthropic Messages semantics are "no thinking unless requested", but
        # GLM reasons by default. The request that trips on this is Claude
        # Code's auto-mode classifier: ~40k-token prompt, no thinking field,
        # 2112-token stage-1 cap. GLM's default reasoning (1.5-2k tokens,
        # 20-27 s) blows that cap and auto mode reports the classifier as
        # "temporarily unavailable (timed out)". GLM 5.3 is a thinking-only
        # model, so {"type": "disabled"} does not turn reasoning off — it cuts
        # it to about one sentence (9-14 output tokens on a 26k-token prompt,
        # vs 130-270 without), which is what keeps the classifier inside its
        # limit; the server ignores chat_template_kwargs.enable_thinking=false.
        # The guard leaves everything else as sent: `thinking is None` means
        # main turns, which request thinking explicitly, are untouched, and
        # messages-without-input is the Anthropic Messages dialect only —
        # Codex's Responses requests carry no thinking field. DeepSeek (which
        # the vision reroute above may have swapped in) honors disabled fully.
        if "messages" in data and "input" not in data and data.get("thinking") is None:
            data["thinking"] = {"type": "disabled"}
        if isinstance(data.get("input"), list):
            data["input"] = [i for i in data["input"] if not is_empty_instruction(i)]
        return data


proxy_handler_instance = HostedOnlyHooks()
if LIMIT_REWRITE:
    install_reset_after_headers()
