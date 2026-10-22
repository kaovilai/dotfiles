# How CLI agents handle HTTP 429 + `Retry-After` from a gateway

Context: redhat-et/pricetag-metering#107 asks the EnMaaS gateway (LiteLLM) to send `Retry-After`
+ a reset time on budget-exhausted / rate-limit 429s. Today: bare 429, body `token budget exhausted`.
Goal: show that Claude Code, Codex CLI and OpenCode (not only T3 Code) behave better with proper headers.

Research date 2026-10-22. Read-only; source read, nothing run against any gateway.
Everything below was read from source/bundle. Behaviour was NOT exercised live against EnMaaS — "unverified" marks gaps.

## Comparison

| | Claude Code 2.1.304 | Codex CLI rust-v0.163.0 | OpenCode v2.1.3 |
|---|---|---|---|
| Retries a 429? | Yes for API-key/gateway auth (`!kt()`); subscription (claude.ai OAuth) only if enterprise / no `anthropic-ratelimit-unified-*` headers | HTTP layer: **no** (`retry_429: false`). Sampling/stream layer: **only if server gave Retry-After**; bare 429 is terminal | Yes (RateLimit is retryable) |
| Max retries (default) | 10 (`Acr`); `CLAUDE_CODE_MAX_RETRIES` clamped to 15 (`NQe`) | `stream_max_retries` 5 (cap 100); `request_max_retries` 4 (cap 100), per provider config | 10 (`Schedule.recurs(10)`) |
| Fallback backoff (no Retry-After) | exp from 500 ms, cap 32 s, ±25% jitter (`L$`) | none for 429: terminal `exceeded retry limit, last status: 429 Too Many Requests` (other retryable errors: 200 ms ×2, ±10%, `backoff()`) | exp from 2 s, cap 10 s/gap, jittered: ~84 s total over 10 retries |
| `Retry-After` format | integer seconds only (`parseInt`); HTTP-date ignored by main loop | seconds or HTTP-date | `retry-after-ms`, seconds, or HTTP-date |
| `retry-after-ms` | main loop: no. Bundled Anthropic SDK `retryRequest`: yes (unverified whether SDK-level retry is active in main call path) | no (in 429 path) | yes |
| `x-should-retry` | honored (`true` forces retry, `false` stops) | not found in 429 path (unverified) | honored |
| Max wait honored | **60 s.** Delay = max(Retry-After, backoff). If > 60 s → gives up at once (`api_request_retry_after_too_long`), no sleep. (Unattended `CLAUDE_CODE_RETRY_WATCHDOG` mode: waits up to 6 h) | **no cap found** — sleeps until the deadline (unverified that no cap exists elsewhere) | **15 min per gap** (`RETRY_AFTER_MAX`); gap = max(backoff, min(RA, 15 min)); up to 10 gaps |
| Shown while waiting | `Retrying in Ns (<reset time if rateLimits.resetsAt>) · attempt N/max` | `Reconnecting... N/max` | `⚠ Retrying in Ns · attempt N · <error message>` |
| After exhaustion | `Request rejected (429)` + provider message | `exceeded retry limit, last status: 429 …` (or usage-limit message, see below) | error message shown (provider body text) |
| Reset-time handling | only Anthropic `anthropic-ratelimit-unified-*` headers (reset epoch) | 429 body `type: usage_limit_reached` + `resets_at` (epoch s) → terminal "usage limit" error; `x-codex-primary-*/secondary-*` headers → rate-limit snapshot | parses `x-ratelimit-*-reset` / `anthropic-ratelimit-*-reset` into details, not used for sleeping (only Retry-After is) |

## Claude Code 2.1.304 (`~/.local/bin/claude`, Mach-O arm64, minified JS in bundle; offsets are in `strings -a` output)

- Symbols (minified): `Qcr(e)` retry predicate; `tJe()` max retries; `L$(attempt, retryAfter, cap=32000, random, base=500)` delay; `BQe(e)` reads `retry-after`; main loop around offset ~27,375,000–27,377,500.
- Retry predicate: honors `x-should-retry` ("true" → retry, "false" → stop). `status===429` → `return !kt() || gne() || umn(e)`: i.e. not a claude.ai subscriber, or enterprise, or no unified-rate-limit headers → retry. A gateway 429 with no Anthropic headers retries.
- Max retries: `Acr=10` default; `CLAUDE_CODE_MAX_RETRIES` honored, clamped to `NQe=15` with warning `CLAUDE_CODE_MAX_RETRIES=n clamped to 15`. Watchdog mode default `Pcr=300`.
- Delay: `L$` = `Gy({attempt, baseMs:500, capMs:32000, jitter proportional 0.25})`; if `retry-after` parses via `parseInt` → `max(seconds*1000, backoff)`. HTTP-date → NaN → ignored (falls back to backoff).
- Wait cap: in the normal (non-watchdog) path, `if (delay > Math.max(Bcr=60000, ceil(yr*1.25))) throw … tengu_api_retry_after_too_long / api_request_retry_after_too_long`. So **Retry-After > 60 s = immediate failure with the 429 error, no waiting**. Retry-After ≤ 60 s is slept.
- Watchdog (`CLAUDE_CODE_RETRY_WATCHDOG`, unattended): sleeps up to `imn=21600000` ms (6 h); only `anthropic-ratelimit-unified-reset` (epoch s, via `rfr`) is used as reset time, and only when `anthropic-ratelimit-unified-status: rejected`.
- `anthropic-ratelimit-unified-*` headers (73 string hits) are read generically off any 429 response (`n4n()` just checks presence of `…-representative-claim` / `…-overage-status`); a gateway that does not send them gets the plain Retry-After path. Whether `rate_limit_event` stream events appear for API-key/gateway auth: **unverified** (19 string hits; not traced).
- Bundled Anthropic SDK `retryRequest` (offset ~20,187,000): `retry-after-ms`, then `retry-after` seconds or HTTP-date, accepts 0 < ms ≤ 2147483647. Many Claude Code clients are built with `maxRetries:0` (22 hits) and the CLI loop above does retries; whether the SDK retry is also active on the main messages call: **unverified**.
- UI: `Retrying in {Ns}{ (reset time)} · attempt {n}/{max}`; on exhaustion `Request rejected (429)`.
- `API_TIMEOUT_MS`: request timeout, not a retry knob (only the "(API_TIMEOUT_MS=… ms, try increasing it)" hint verified).

## Codex CLI openai/codex tag rust-v0.163.0 (commit 83086188ae0614bd882818ff1aa23f3194962012; paths under `codex-rs/`)

- Provider retry config: `model-provider-info/src/lib.rs` — `DEFAULT_STREAM_MAX_RETRIES=5`, `DEFAULT_REQUEST_MAX_RETRIES=4`, caps 100 (lines ~67-75); `ApiRetryConfig { base_delay: 200 ms, retry_429: false, retry_5xx: true, retry_transport: true }` (~line 455). Config keys `request_max_retries`, `stream_max_retries` per `model_providers.<id>` — applies to custom providers (no gate).
- `Retry-After` capture: `http-client/src/retry_after.rs` `RetryAfter::from_headers` — digits-only seconds or HTTP-date; stored as a monotonic deadline (not restarted when error is passed on). Captured on every non-2xx in `http-client/src/transport.rs` (~183, ~224). `retry-after-ms` not read here.
- 429 mapping: `codex-api/src/api_bridge.rs` ~185-241:
  - body `error.type == "usage_limit_reached"` → `UsageLimitReached { resets_at (epoch s), plan_type, limit_window_minutes, rate_limits (from x-codex-* headers) }` → **terminal** (`protocol/src/error.rs` `retry_delay` returns None). User sees "You've hit your usage limit …" text variants (plan specific; includes reset time when `resets_at` present).
  - `usage_not_included` / `insufficient_quota` / codes `credit_balance_exhausted`, `organization_spend_limit_exceeded`, `project_spend_limit_exceeded`, `organization_usage_limit_exceeded` → `QuotaExceeded`, terminal.
  - everything else on 429 (including an EnMaaS-style bare 429 + `token budget exhausted`) → `RetryLimit { status, request_id }`.
  - I did not find `resets_in_seconds` in 0.163.0 `api_bridge.rs`; only `resets_at`.
- Retry decision: `protocol/src/error.rs` `retry_delay()` (~410-460): `RetryLimit` / `ServerOverloaded` → `server_retry_delay()` = Retry-After only, **None → terminal**. So: 429 **with** Retry-After → retried; 429 **without** → fails immediately as `exceeded retry limit, last status: 429 Too Many Requests` (error.rs ~694). Other retryable errors (stream, 5xx, timeout, `RateLimitExceeded`) use server advice or `backoff(n)` (`async-utils/src/backoff.rs`: 200 ms ×2^(n-1), ±10% jitter, no cap there).
- Loop: `core/src/responses_retry.rs` ~91-175: up to `stream_max_retries`; `retry_at = retry_after.deadline() or now+delay`; `sleep_until(retry_at)`. No cap on a server-provided deadline found. Emits `Reconnecting... N/max` to the UI. On exhaustion stores the deadline (`ExhaustedResponseRetry`) and returns the error.
- Test confirming: `core/tests/suite/retry_after.rs` `responses_http_429_uses_retry_after` (429 + `Retry-After: 1` + `rate_limit_exceeded` code → retried, completes).
- Rate-limit snapshot: `codex-api/src/rate_limits.rs` `parse_all_rate_limits` / `parse_rate_limit_for_limit` read `x-codex-primary-used-percent|window-minutes|reset-at`, `x-codex-secondary-*`, `x-codex-<limit>-limit-name`, `x-codex-credits-*`, `x-codex-promo-message`, `x-codex-rate-limit-reached-type`. Called from `codex-api/src/sse/responses.rs:44` on any stream response headers and from the 429 path; no provider check found in that code → should work for a custom `model_provider` that emits those headers (UI rendering for non-OpenAI providers: **unverified**).

## OpenCode sst/opencode tag v2.1.3 (commit bb25a2f4a3f3f04d7c344bec0c0574ea3510b3b1)

Note: v2.x rewrite; retry lives in `packages/core` + `packages/ai` (own `@opencode/ai`, Effect-based), not the Vercel `ai` package. Older 1.x line (`packages/opencode/src/session/retry.ts`) **not examined** (unverified).

- Header parse: `packages/ai/src/route/executor.ts` `retryAfterMs()` (~line 22): `retry-after-ms` first; else `retry-after` as seconds; else HTTP-date → ms (clamped ≥0). Also collects `x-ratelimit-{limit,remaining,reset}-*` and `anthropic-ratelimit-*-{limit,remaining,reset}` into `HttpRateLimitDetails` (informational).
- Classification: `packages/ai/src/provider-error.ts` — 429 → `QuotaExceededError` (not retried) only if code in `QUOTA_CODES` (`insufficient_quota`, `usage_not_included`, `billing_error`, …) or body matches `QUOTA_TEXT` = `/insufficient[-_\s]?(quota|balance)|quota[-_\s]?exceeded|budget exceeded|usage limit|limit exhausted|package has expired|plan does not yet include/i`; else any 429 → `RateLimitError` (retryable). **`token budget exhausted` does not match `QUOTA_TEXT`** (it has "budget exhausted", not "budget exceeded"; "limit exhausted" needs the word limit) → treated as a throttle and **retried**, so a permanent budget block costs ~84 s of futile retries today. A `Retry-After`/reset-aware body (or an `insufficient_quota`-style code/text) lets it either wait correctly or fail fast.
- `isRetryable()` (~line 83) honors `x-should-retry` first (`true`/`false`), then RateLimit/ProviderInternal → true.
- Policy: `packages/core/src/model-retry.ts` — `Schedule.exponential(2 s)` min `spaced(10 s)`, `recurs(10)`, jittered (≈2,4,8,10×7 s ≈ 84 s total). `modifyDelay`: delay = max(backoff, min(retryAfterMs, `RETRY_AFTER_MAX` = 15 min)) for `RateLimit`/`ProviderInternal`. Comment: "Bound provider-requested delays so a hostile or buggy retry-after cannot stall a call for hours." Worst case 10 × 15 min.
- UI: `packages/core/src/session/runner/retry.ts` publishes `RetryScheduled{attempt, at, error}`; TUI `packages/tui/src/routes/session/index.tsx` ~2559 renders `⚠ Retrying in {s}s · attempt {n} · {error.message}` (countdown; "Retry due" at 0). Plugin hook `session.retry` can override delay. After exhaustion the error surfaces in the session.
- Without Retry-After: pure backoff above.

## What a very long Retry-After does (e.g. days until month-end)

- Claude Code: > 60 s → **fails immediately** with the 429 error (does not sleep). Good for a budget block, but means ≤60 s values are the only ones that auto-recover.
- Codex: 429 + huge Retry-After → **sleeps until the deadline** (no cap found); the turn looks hung. Prefer a usage-limit style error body (`type: usage_limit_reached`, `resets_at`) for long budget windows — that is terminal with a reset-time message, no sleep.
- OpenCode: clamps to **15 min per attempt**, retries up to 10 times (hours of wall time worst case) unless the body matches its quota patterns / codes (then fails fast).
- So the generic advice: short throttle → `Retry-After` (seconds). Budget exhausted until a far-off reset → still 429, but either omit a huge Retry-After or pair it with an explicit quota-style error (`insufficient_quota` code / "budget exceeded" text) plus a reset timestamp header.

## Generic comment draft (for the EnMaaS issue; lite caveman / plain)

```
Adding data: this is not just a T3 Code thing. I read the source of Claude Code (2.1.304), Codex CLI (0.163.0) and OpenCode (2.1.3).
All three read `Retry-After` (seconds; Codex/OpenCode also HTTP-date) and show the user a wait/retry message; a bare 429 gives them only blind backoff (Codex gives up at once).
Please send `Retry-After` (seconds) plus a reset timestamp header on throttle 429s, e.g. `x-ratelimit-reset-*`. Better still, say it in the body too.
Care for long waits: Claude Code gives up if Retry-After > 60 s, OpenCode caps each wait at 15 min and retries up to 10 times, Codex sleeps until the deadline (no cap found).
For "budget exhausted until month reset", use a quota-style error (`insufficient_quota` code or "budget exceeded" text) + reset time, not a huge Retry-After; OpenCode currently retries "token budget exhausted" as a plain throttle.
Source refs: Claude Code retry loop + `api_request_retry_after_too_long`; Codex `codex-rs/core/src/responses_retry.rs`, `protocol/src/error.rs`; OpenCode `packages/core/src/model-retry.ts`.
```

(Public posting: remember AI attribution footer per global rules before posting.)

## Unverified / caveats

- No live test against EnMaaS/LiteLLM; behaviours are from source reading.
- Claude Code: bundle is minified; names (`L$`, `Qcr`, `tJe`, …) are version-specific and shift between releases. `rate_limit_event` emission for gateway auth not traced. SDK-level retry coexistence not traced.
- Codex: "no cap on Retry-After" based on grep of retry path only; `x-should-retry` not found in 429 path; UI rendering of `x-codex-*` snapshots for non-OpenAI providers not traced.
- OpenCode: only the v2.1.3 tree; the 1.x `packages/opencode` retry path (and any Vercel-AI-SDK retry) not examined.
- Working copies used (untrusted, disposable): `/tmp/r429/{codex,opencode,cc}`.
