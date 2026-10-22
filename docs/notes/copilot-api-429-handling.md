# copilot-api: how Copilot throttling reaches clients (research, 2026-10-22)

Read-only research. Nothing run, nothing applied, :4141 untouched. Clones (shallow, untrusted, unexecuted) live in `/tmp/copilot-api-429/`.

## 1. User's checkout (~/git/copilot-api)

- Remotes: `origin` https://github.com/kaovilai/copilot-api (fork), `upstream` https://github.com/caozhiyuan/copilot-api.git (a.k.a. `@jeffreycao/copilot-api`). It is the **caozhiyuan lineage, not ericc-ch**.
- Branch `fix-healthcheck-ipv4-loopback`, HEAD `afa54d261e984220832676849b25bb0a4a68e39b` ("Fix healthcheck: use 127.0.0.1"). 33 commits not in `upstream/dev`, including fork-only ones (healthcheck #14, ambiguous-timeout 80s #13, gh-aw upstream sync). The error path below is upstream code, not a local patch.
- Running: `bun run --cwd ~/git/copilot-api ./src/main.ts start --port 4141` (pid seen via pgrep).

### Upstream 429 / 403 / quota on `/v1/messages` and `/v1/chat/completions`
- `src/services/copilot/create-messages.ts:159-163` and `src/services/copilot/create-chat-completions.ts:84-88`: after the fetch, `logCopilotRateLimits(response.headers)` (console only), then `if (!response.ok) throw new HTTPError(...)`. No retry, queue or wait on 429.
- `src/services/copilot/fetch-with-reauth.ts`: only retries a **401** (refresh the Copilot token, once) and `UpstreamHeadersTimeoutError` (pre-response). 429/403/402 are NOT retried.
- `src/routes/messages/route.ts:11-15` and `src/routes/chat-completions/route.ts:10-14`: the catch calls `forwardError`.
- `src/lib/error.ts:58-121` `forwardError` (added upstream in caozhiyuan commit `ddd9903`, 2026-03-27, "forward retry headers"; same code is at `upstream/dev:src/lib/error.ts:68`):
  - status is **passed through** (`error.response.status`, line 112). No rewrite to 500.
  - **Only on 429**: copies `retry-after` and every `x-*` header to the client (lines 88-95). On 403/402/503 headers are dropped.
  - Body: `{"error":{"message":"<raw upstream body text>","type":"error"}}`. This is **not** Anthropic-shaped (`{"type":"error","error":{"type":"rate_limit_error"}}`). The raw upstream JSON is a string inside `message`.
  - Timeouts become 504 `upstream_timeout`. Client abort becomes 499. Non-HTTPError becomes 500.
- Built-in throttle flags: **none**. `src/start.ts` args are host, port, verbose, github-token, claude-code, show-token, proxy-env. No `--rate-limit`, `--wait` or `--manual` (those exist only in ericc-ch and its forks, see 2).
- Streaming: a 429 comes back before any SSE starts, so it is a plain HTTP error. Mid-stream failures become an SSE `{"error":{"type":"upstream_error"}}` (`src/routes/chat-completions/handler.ts:127-165`).
- `/usage` (`src/routes/usage/route.ts`, mounted `src/server.ts:25`): proxies GitHub copilot_internal/user. Fields (`src/services/github/get-copilot-usage.ts:~215-255`): `copilot_plan`, `quota_reset_date`, `quota_snapshots.{chat,completions,premium_interactions}` each `{entitlement, remaining, quota_remaining, percent_remaining, overage_count, overage_permitted, unlimited, quota_id}`, `token_based_billing?`.
  - `/usage` is not in `allowUnauthenticatedPaths` (`src/server.ts:64`), so it needs an API key only if `auth.apiKeys` is configured (unverified).
- Console-only quota hints: `src/lib/copilot-rate-limit.ts:25-31` reads the response header `x-usage-ratelimit-session` / `x-usage-ratelimit-weekly` (`rem=..&rst=..`) and the `copilot_quota_snapshots` keys `5Hour-Session-RateLimits` / `Weekly-Session-RateLimits` (Responses API). They are **logged, not forwarded** to clients.
- Log dir `~/.local/share/copilot-api/logs/` has a single `messages-handler-2026-10-12.log` with zero "Failed to create ..." lines. There is no persistent throttle log today.

## 2. Forks and similar projects

Scanned by cloning and grepping `retry-after|x-ratelimit|rate_limit` (GitHub code search returned nothing for forks, so clones were used). Stars and push dates are from `gh api`/`gh search` on 2026-10-22.

| repo | stars | last push | 429 handling | retry-after fwd? | quota surfaced? | code |
|---|---|---|---|---|---|---|
| ericc-ch/copilot-api (`0ea08fe`) | 4145 | 2025-11-10 | passes status through via `forwardError`; own client-side `--rate-limit N [--wait]` throttle that **itself returns 429** `{"message":"Rate limit exceeded"}` | no (no header) | `/usage` only | src/lib/error.ts:15-36, src/lib/rate-limit.ts:8-46 |
| caozhiyuan/copilot-api (user's upstream, `64e38da`) | 1086 | 2026-10-22 | pass-through status; retry-after and `x-*` forwarded on 429; Retry-After honored in token refresh and device-code poll | **yes (429 only)** | `/usage`; logs `x-usage-ratelimit-*` | src/lib/error.ts:58-121 (commit ddd9903), tests/poll-access-token.test.ts:97 |
| puxu-msft/copilot-api-js (`c09d5b9`) | 22 | 2026-08-12 | richest: classifies 429, `error.code=="rate_limited"`, 402 quota, 503 upstream-rate-limited; Anthropic/OpenAI/Gemini-shaped errors; adaptive limiter with queue and backoff | partial: `Retry-After` header parsed into body `retry_after` (402, 503) and used by the limiter; `Retry-After` set on error responses in messages glue | `/status` route (premium_models / premium_interactions) | src/lib/error/forward.ts:402,431,440; src/lib/adaptive-rate-limiter.ts:379-440; src/routes/messages/error-shaping-glue.ts:106; src/routes/status/route.ts:179-192 |
| ericc-ch PR #162 "adaptive rate limiting with automatic retry" (leocavalcante) | n/a | closed, not merged | queue everything, always emit rate-limit headers | n/a | n/a | https://github.com/ericc-ch/copilot-api/pull/162 |
| betaHi, cuipengfei, kylehuan, billxc, sq-lai/copilot-api-fixed, nghyane | 15, 4, 5, 2, 2, 4 | 2025-06..2026-06 | ericc-ch baseline only (`--rate-limit/--wait`, pass-through status) | no | no | src/start.ts, src/lib/rate-limit.ts (same as ericc) |
| onllm-dev/onWatch | 757 | 2026-10-22 | not examined in depth (appears to be a quota monitor); unverified | ? | ? | https://github.com/onllm-dev/onWatch |
| brita-ai/copilot-api-claude-code | 2 | 2026-02-11 | not examined | ? | ? | |

Issues/PRs: a search for `429`/`rate limit`/`retry` in ericc-ch, caozhiyuan and puxu-msft found no dedicated "forward 429" issue. Closest hits are PR #162 (above, closed), ericc-ch #84 "Account Suspension due to using copilot-api" (closed; why people add `--rate-limit`), and caozhiyuan #250 (CC errors with sonnet-4.6, users suggest `--rate-limit 10 --wait`).

## 3. What GitHub Copilot itself returns (as seen in code only)

- Status 429 (all codebases). Optional `Retry-After` header: caozhiyuan forwards it, so it is known to be at least expected (`src/lib/error.ts:88-95`). Seconds vs HTTP-date both parsed (`src/lib/error.ts:18-37`).
- Body (puxu): JSON `error.code == "rate_limited"` can arrive with a non-429 status (forward.ts:431); optional `retry_after` number at top level or `error.retry_after` (adaptive-rate-limiter.ts:~400-440).
- 402 = quota exceeded (premium requests) (forward.ts:402). 503 with an "upstream rate limited" body text (forward.ts:440, `isUpstreamRateLimited`; exact text not captured).
- Quota headers on **successful** responses: `x-usage-ratelimit-session` and `x-usage-ratelimit-weekly`, value `rem=<n>&rst=<iso>` (caozhiyuan copilot-rate-limit.ts:25-26,45-62). `copilot_quota_snapshots` in Responses SSE: `5Hour-Session-RateLimits`, `Weekly-Session-RateLimits` with `entitlement, percent_remaining, overage_*, reset_date` (lines 28-31, 142-158).
- Unverified (never seen in code or tests): `x-ratelimit-*` header family from Copilot, a 403 quota body, exact 429 body wording, whether the x-usage-ratelimit headers are sent on 429s.

## 4. What Claude Code records

Read-only grep of `~/.claude/projects/**/*.jsonl` (field names only):
- API failures that exhaust retries: `type:"assistant"` with `isApiErrorMessage:true`, `apiErrorStatus` (e.g. 400/401/500/502/503), `error` (`server_error`, `authentication_failed`, `invalid_request`, `unknown`), text starting `API Error: <status> ...`. Found 0 entries with `apiErrorStatus:429`. The string "Request rejected (429)" occurs only inside conversation text (user/assistant/blob lines), not as an error entry.
- **Every retried attempt** is logged as `type:"system", subtype:"api_error"` with `retryAttempt`, `maxRetries` (10), `retryInMs`, `error.{status,message,formatted,rateLimits,noResponse,isNetworkDown,connection}`. Seen: `error.status:429` x7 (formatted "429 No deployments available for selecte..." = LiteLLM, not Copilot), plus 401 x12, 500 x1, connection errors.
- Verdict: **yes, a Copilot throttle would show up** as `system/api_error` lines with `error.status == 429` (and `retryInMs`), even when a later retry succeeds. If retries are exhausted it also shows as an `assistant` + `isApiErrorMessage` + `apiErrorStatus:429`. Caveats: (a) `error.rateLimits` is probably Anthropic-header-based, not Copilot; (b) the transcript has no field saying the failure came from Copilot, so tag by `model` / session provider or by `cwd`/instance; (c) `Retry-After` value is not stored (only Claude Code's own `retryInMs`, which may or may not derive from it, unverified).

## 5. Recommendation

(a) Detection, best to cheapest:
1. **Transcript scan** (zero proxy change): tail `system/api_error` with `error.status in {429,402,403,503}` and `retryInMs`; span = first to last consecutive entry in a session, plus the `isApiErrorMessage` entry for hard failures. Attribute to Copilot via the session's model id / provider instance; the proxy-routed GLM/DeepSeek 429s look identical, so don't mix them.
2. **Poll `/usage`** every few minutes for `quota_snapshots.premium_interactions.percent_remaining` / `remaining` / `quota_reset_date` (and `unlimited`). This gives the quota state and reset, not transient throttles.
3. **Tiny logging shim** in the proxy (patch below) to capture exact upstream status, `retry-after`, and `x-usage-ratelimit-*` per throttle. Needed only if the transcript view is too coarse.

(b) Patch vs switch: do **not** switch forks. The user's lineage already forwards 429 and Retry-After. The only gaps are non-429 header forwarding, Anthropic-shaped error body, and no throttle log. puxu-msft has the nicest classification but is a different codebase (22 stars, different architecture), so porting is large. Suggested patch (NOT applied), `src/lib/error.ts`:

```diff
@@ export async function forwardError(
   if (error instanceof HTTPError) {
-    if (error.response.status === 429) {
+    const status = error.response.status
+    // 402/403/429/503 are all throttle/quota signals from Copilot.
+    if ([402, 403, 429, 503].includes(status)) {
       for (const [name, value] of error.response.headers) {
         const lowerName = name.toLowerCase()
-        if (lowerName === "retry-after" || lowerName.startsWith("x-")) {
+        if (
+          lowerName === "retry-after"
+          || lowerName.startsWith("x-")
+        ) {
           c.header(name, value)
         }
       }
+      // throttle log for llm-usage (one JSON line per throttle)
+      appendThrottleLog({
+        ts: new Date().toISOString(),
+        path: new URL(c.req.url).pathname,
+        status,
+        retryAfter: error.response.headers.get("retry-after"),
+        sessionRl: error.response.headers.get("x-usage-ratelimit-session"),
+        weeklyRl: error.response.headers.get("x-usage-ratelimit-weekly"),
+      })
     }
```
with `appendThrottleLog` = `fs.appendFile(~/.local/share/copilot-api/logs/throttle.jsonl, JSON.stringify(row)+"\n")` (best effort, never throws). Optionally, for `/v1/messages` return `{"type":"error","error":{"type":"rate_limit_error","message":...}}` so Claude Code shows a cleaner message. Also optionally forward `x-usage-ratelimit-*` on success responses so a client can see headroom (needs new header copy in `logCopilotRateLimits` callers). The running process would need a restart to pick this up (coordinate with the user).

(c) Proxy-side drift/reset parsing should also accept if Copilot traffic goes through it:
- `Retry-After` as delta-seconds **and** HTTP-date (error.ts:18-37).
- Body `error.code == "rate_limited"`, body `retry_after` (top-level or `error.retry_after`), status 402 and 503 as throttle, not only 429.
- Copilot quota headers `x-usage-ratelimit-session|weekly` = URL-query style `rem=<pct>&rst=<ISO8601>` (not a plain number); `copilot_quota_snapshots` keys `5Hour-Session-RateLimits`, `Weekly-Session-RateLimits` (fields `percent_remaining`, `reset_date`).
- `/usage` shape: `quota_reset_date` (date) plus `quota_snapshots.premium_interactions|premium_models`; `unlimited:true` means no quota.
- Treat any `x-*` header as untrusted/optional; `x-ratelimit-*` from Copilot is unverified.
