# Codex CLI + OpenCode vs hosted-only proxy 429 output (verified from OSS source)

Date 2026-10-22. Companion to `client-429-handling.md` (which this corrects for OpenCode).
Status tags: **[tested]** = observed against a local test proxy + stub gateway; **[source]** = derived from source only, not run.

Sources (shallow clones, untrusted, nothing run from them except the prebuilt `opencode-ai@1.19.4` npm binary was fetched but its run was cut short, see "Unverified"):
- Codex: `openai/codex` tag `rust-v0.163.0` (commit 83086188ae), paths under `codex-rs/`.
- OpenCode: repo is now `anomalyco/opencode` (`sst/opencode` redirects). Latest release **v1.19.4** (commit 148842ef7c, published 2026-10-22). Main CLI = **`packages/opencode`** (retry in `packages/opencode/src/session/retry.ts`, error parse in `provider/error.ts`), AI SDK path (`@ai-sdk/openai-compatible` 2.0.41, `@ai-sdk/provider` 3.0.16). `packages/llm` is an opt-in native runtime (see row O9). The earlier note cited tag `v2.1.3` (`packages/core`, `packages/ai`): not the released CLI; its OpenCode claims (15 min cap, quota-text classification) do **not** hold for v1.19.4.

Our output (hosted_only_hooks.py `rewrite_limit`, lines 208-250): every non-`/v1/messages` 429 (so `/v1/responses` **and** `/v1/chat/completions`) becomes 429 + `retry-after: <sec>` + `x-codex-primary-{used-percent,window-minutes,reset-at}` + JSON body `{"error":{"message":"... Try again in Xh Ym Zs.","type":"usage_limit_reached","param":"None","code":"429"}}` **[tested, both paths]**. Monthly: retry-after ~813k s (9.4 days). Per-minute: now+60s unless upstream retry-after.

## Codex evidence

| # | Claim | Source cite | Empirical |
|---|---|---|---|
| C1 | 429 body `error.type == "usage_limit_reached"` -> `UsageLimitReached{plan_type, resets_at, limit_window_minutes, rate_limits}`; only `resets_at` (epoch s, `Option<i64>`) read from body; `resets_in_seconds` is **not** parsed (appears only in a websocket test, `core/tests/suite/client_websockets.rs:1767`) | `codex-api/src/api_bridge.rs:185-222`, struct `:349-356` | [tested] our body has no `resets_at` -> message "You’ve hit your usage limit. Try again later." (no reset time) |
| C2 | `x-codex-primary-{used-percent,window-minutes,reset-at}` headers -> `RateLimitSnapshot`, attached to the error | `api_bridge.rs:192-205`; `codex-api/src/rate_limits.rs:195-217` | [tested] snapshot produced: `usedPercent 100, windowDurationMins 44640, resetsAt 1793491200` (=2026-11-01T00:00Z) |
| C3 | `UsageLimitReached` is terminal: `retry_delay()` -> None; turn code stores the snapshot and returns | `protocol/src/error.rs:433` (in the `=> None` arm, 410-437); `core/src/session/turn.rs:1798-1803` | [tested] `codex exec`: monthly/bare/ra5 all fail at once, 3 stub hits (those are LiteLLM's own 2 retries, 1 client request), 5 s / 5 s / 16 s wall, text "You’ve hit your usage limit. Try again later." |
| C4 | Custom `model_provider` takes the same path; no provider gate in parse or snapshot code | `api_bridge.rs` (no provider check); `rate_limits.rs` | [tested] wiring used `model_provider=glmonly` (name "RH Hosted Only") |
| C5 | Snapshot reaches app-server `account/rateLimits/updated` for custom providers: `update_rate_limits` -> TokenCount event -> notification | `turn.rs:1798-1803`; `core/src/session/mod.rs:5146-5185`; `app-server/src/bespoke_event_handling.rs:1593-1611` | [tested] raw `app-server` JSON-RPC: `account/rateLimits/updated` (resetsAt 1793491200) then `error` `codexErrorInfo:"usageLimitExceeded"`, `willRetry:false` |
| C6 | 429 that is not usage_limit/quota/flex -> `RetryLimit{status}`; retried only if a `Retry-After` was captured, else terminal `exceeded retry limit, last status: 429` | `api_bridge.rs:231-234`; `error.rs:438-440` (`server_retry_delay()`), Display `error.rs:690-700` | [source] (our rewrite never produces this for 429) |
| C7 | HTTP layer never retries 429 (`retry_429:false`), retries 5xx/transport; defaults request 4 / stream 5, caps 100; per-provider config keys | `model-provider-info/src/lib.rs:67-75, 455-459, 499-509`; `codex-client/src/retry.rs:26-33` | [tested] plain 500 and 503 (not rewritten): 6 stream attempts x 5 HTTP attempts x 3 LiteLLM = **90 stub hits, ~165 s**, final "high demand" (500) / "unexpected status 503 ... metering system unavailable" (503) |
| C8 | `Retry-After`: digits-only seconds or HTTP-date, becomes a monotonic deadline; stream loop sleeps `until` the deadline, **no cap** found | `http-client/src/retry_after.rs:25-39`; `core/src/responses_retry.rs:88,141,165` | [source] |
| C9 | Non-retryable quota classification on 429: `type` `usage_limit_reached` / `usage_not_included` / `insufficient_quota`, or `code` in {`insufficient_quota`, `credit_balance_exhausted`, `organization_spend_limit_exceeded`, `project_spend_limit_exceeded`, `organization_usage_limit_exceeded`} -> `QuotaExceeded` ("Quota exceeded. Check your plan and billing details."), terminal, **no snapshot / no reset** | `api_bridge.rs:223-236`; `error.rs:181-182, 418` | [source] |

### Codex verdict: shape OK, one gap

- OK: `/v1/responses` 429 `usage_limit_reached` + `x-codex-primary-*` is exactly what Codex needs: terminal (no futile retry/sleep) and the reset time reaches `account/rateLimits/updated` (C2-C5 tested). Keep `usage_limit_reached` for monthly: `insufficient_quota` (C9) would lose the snapshot.
- **Gap G1**: body lacks `resets_at`, so the human-visible message says "Try again later." instead of "Try again at <date>." (C1 tested). Fix: add `error.resets_at` (epoch seconds) to the body.
- Design note (not a bug): per-minute 429s also become terminal `usage_limit_reached` (bare + ra5 tested). A standalone Codex user gets a hard stop on a 60 s RPM throttle instead of waiting. Making short waits a plain 429 + `retry-after` would let Codex wait and retry itself (C6/C8, source only), but then neither the snapshot nor T3's reset time exists (after 5 retries Codex ends with `exceeded retry limit, last status: 429`). Not recommended while T3 auto-resume is the goal.
- 5xx amplification (C7): not our output, but each client request is 3 upstream hits via LiteLLM's own retry (tested); consider `num_retries: 0` for 429s later (out of scope).

## OpenCode evidence (v1.19.4, AI SDK path)

| # | Claim | Source cite | Empirical |
|---|---|---|---|
| O1 | `/v1/chat/completions` **is** rewritten today: the non-`/v1/messages` branch applies to every URL | `hosted_only_hooks.py:219,234-250` | [tested] probe on `/v1/chat/completions`: 429, `retry-after: 812674`, `x-codex-primary-*`, body `usage_limit_reached` / `code:"429"` |
| O2 | AI SDK marks every 429 retryable by default (`APICallError.isRetryable = 408/409/429/>=500`); OpenCode passes it through (`openai*` providers only add 404) | `@ai-sdk/provider@3.0.16 dist/index.mjs:52-55`; `opencode/src/provider/error.ts:23-27, 188` | [source] (provider-utils error handler, which sets isRetryable, not read) |
| O3 | `retryable()` returns undefined (stop) only if `!isRetryable && status<500 && message/body do not match a retryable regex`. **No quota/billing check exists on HTTP errors.** `insufficient_quota` is recognised only for in-stream error events (`parseStreamError`, `{"type":"error","error":{"code":"insufficient_quota"}}` -> non-retryable) | `session/retry.ts:86-98`; `provider/error.ts:111-153` (`:117-121`) | [source] so a 429 body of `insufficient_quota` does **not** stop retries |
| O4 | Retry regexes (any hit = retryable even for non-5xx): `/429\|500\|502\|503\|504\|524/`, `rate limit\|rate_limit\|too many requests`, `overloaded\|service unavailable\|internal error\|server error`, `resource exhausted`, `try again (later\|in)`, `at capacity`. Our current body matches `/429/` (its `code:"429"`) and `try again in` | `session/retry.ts:33-41`; test of current body: 2 of 5 patterns hit | [tested] regex check on the real observed body: matches `429` and `try again in` |
| O5 | Delay: `retry-after-ms`, else `retry-after` seconds, else HTTP-date; capped only at **2,147,483,647 ms (24.8 days)**; no 15 min cap. With a headers object but no retry-after: exponential 2 s x2 (no 30 s cap); 30 s cap only when there are no response headers at all | `session/retry.ts:29-31, 44, 46-78` | [source]: our monthly `retry-after: 812674` s -> sleeps ~9.4 days on the first retry |
| O6 | Max retries 5 (`attempt > RETRY_MAX_RETRIES` stops); "retry" status with `next` timestamp feeds the TUI countdown | `retry.ts:31, 193`; `session/processor.ts:674-686` | [source] |
| O7 | Display: AI SDK message from `error.message`; if body is JSON, `body.message \|\| body.error \|\| body.error.message` appended only when `msg === STATUS_CODES[status]`; plain-text body (`token budget exhausted`) shown as `<msg>: <raw body>`; Go-only `GoUsageLimitError` special text | `provider/error.ts:32-78`; `retry.ts:112-139` | [source] |
| O8 | Plain-text `token budget exhausted` 429 (what the raw gateway sends): retried (O2/O3), no `retry-after` -> either 30 s-capped exponential (no headers) or uncapped exponential (headers present), 5 tries | O2, O3, O5 | [source] |
| O9 | Native `@opencode-ai/llm` runtime does classify 429 body `insufficient quota\|quota exceeded` as non-retryable `QuotaExceeded` (cap 10 s, 2 retries) but only for providerID `openai`/`anthropic`/`opencode*` and only with `OPENCODE_EXPERIMENTAL_NATIVE_LLM`; a custom provider never takes it | `packages/llm/src/route/executor.ts:36,38,243`; `opencode/src/session/llm.ts:226`; `session/llm/native-runtime.ts:55`; `effect/runtime-flags.ts:54` | [source] |
| O10 | Only way to make the AI SDK path stop on a quota error: a **non-retryable status** (AI SDK false for e.g. 402) whose `message` and `responseBody` match none of the O4 patterns (no `429/500/502/503/504/524` substrings, no "try again", "rate limit", "exhausted" is fine only without "resource") | O2, O3, O4 | [tested] regex check: proposed 402 message/body (below) matches 0 of 5 patterns |

### OpenCode verdict: **needs change** for monthly quota on `/v1/chat/completions`

- Monthly: our 429 + 813k-second `retry-after` makes OpenCode sleep ~9.4 days (hang) per attempt; `type`/`code` in the body cannot help (O3). Needs a non-retryable status (402) with a clean message.
- Per-minute: 429 + `retry-after: <sec>` works (OpenCode waits that long, up to 5 retries, shows `Retrying in Ns`). **OK**, no change. `retry-after-ms` adds nothing (seconds already honoured, O5), so not proposed.
- Raw gateway bare 429 `token budget exhausted` (without our rewrite) is retried with backoff (O8): the rewrite is a strict improvement only for the per-minute case.

## Proposed patch (NOT applied) to `scripts/hosted_only_hooks.py`

Two changes. Neither was run; both need a restart-time check (see Unverified).

```diff
--- a/scripts/hosted_only_hooks.py
+++ b/scripts/hosted_only_hooks.py
@@ def rewrite_limit(exc, request_data, now=None):
         return HTTPException(status_code=503, detail=message)
+    if monthly and "/v1/chat/completions" in url:
+        # OpenAI-compatible clients (OpenCode via @ai-sdk/openai-compatible)
+        # retry every 429 and sleep `retry-after` for up to 24 days, and do not
+        # read `insufficient_quota` from an HTTP error. A 402 is not retryable
+        # there. Keep the text free of the substrings opencode's retry regexes
+        # match (429/500/502/503/504/524, "try again", "rate limit"); the reset
+        # is always a month start, so the stamp reads 00:00:00.
+        stamp = datetime.fromtimestamp(reset, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
+        out = HTTPException(
+            status_code=402,
+            detail=f"Monthly token budget exhausted. Quota resets {stamp}.",
+        )
+        out.type = "insufficient_quota"
+        return out
     window = (
@@ class ResetAfterHeaders:
+def add_resets_at(start, message):
+    """Codex reads only `error.resets_at` (epoch s) from the body for its
+    "Try again at <date>" text; litellm's body has no such field. Copy it from
+    the x-codex-primary-reset-at header of a rewritten usage_limit_reached 429."""
+    try:
+        reset = int(dict((k.lower(), v) for k, v in start.get("headers", []))[b"x-codex-primary-reset-at"])
+        data = json.loads(message.get("body") or b"")
+        err = data["error"]
+        if err.get("type") != "usage_limit_reached":
+            return start, message
+    except (KeyError, ValueError, TypeError, AttributeError):
+        return start, message
+    err["resets_at"] = reset
+    body = json.dumps(data, separators=(",", ":")).encode()
+    headers = [
+        (k, str(len(body)).encode() if k.lower() == b"content-length" else v)
+        for k, v in start.get("headers", [])
+    ]
+    return {**start, "headers": headers}, {**message, "body": body}
+
@@         async def wrapped(message):
             nonlocal held
-            if message["type"] == "http.response.start" and message["status"] == 503:
+            if message["type"] == "http.response.start" and message["status"] in (429, 503):
                 held = message
                 return
             if held is not None:
                 start, held = held, None
                 if message["type"] == "http.response.body" and not message.get("more_body"):
-                    seconds = reset_after_seconds(message.get("body") or b"")
-                    if seconds:
+                    if start["status"] == 429:
+                        start, message = add_resets_at(start, message)
+                    seconds = reset_after_seconds(message.get("body") or b"") if start["status"] == 503 else None
+                    if seconds:
                         extra = [(b"retry-after", str(seconds).encode())]
```

Expected effect (source-derived): Codex message becomes "You’ve hit your usage limit. Try again at <date>." (C1); OpenCode monthly on chat/completions fails at once with "Monthly token budget exhausted. Quota resets 2026-11-01T00:00:00Z." (O2-O4, O7, O10). Per-minute behaviour unchanged for both clients. Note the docstring item 5 should then mention `/v1/chat/completions` and 402; the `ResetAfterHeaders` class docstring and `/v1/messages` 503 path are untouched.

Considered, not proposed: `retry-after-ms` (no evidence it helps), `insufficient_quota` type for Codex monthly (loses snapshot, C9), non-`usage_limit_reached` 429 for short waits (loses T3 reset, see Codex design note).

## Unverified / limits

- OpenCode was **not** run end to end: the `opencode run` attempt against the test proxy was interrupted, so every OpenCode row except O1/O4/O10 regex checks is source-only. Not read: `@ai-sdk/provider-utils` error handler (sets `isRetryable` for non-JSON bodies), the `opencode.ai` Zen/Go paths.
- 402 through LiteLLM: assumed the body `code` becomes "402" and `type` is copied from the `type` attribute as it was for 429 (tested for 429 only). `add_resets_at` header-name case and streaming (`more_body`) 429s not run.
- Codex: `Retry-After` cap absence is from the retry loop only; behaviour of `x-codex-*` rendering in the TUI for custom providers not checked (app-server path tested).
- Test hygiene: my stub/proxy ports were collided by another teammate mid-run (4157/4158); the Codex runs above used proxy 4157 + stub 4160 before the reassignment, all since stopped (see final reply). A concurrent edit of `scripts/litellm_usage_log.py` at 10:10 by someone else changed the launcher fingerprint, so the app-server run called native `codex app-server` with the same `-c` wiring instead of the wrapper.
