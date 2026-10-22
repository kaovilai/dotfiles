# EnMaaS reset data: forward-compat contract

EnMaaS 429s carry no reset time today (praxis `reject_budget_exhausted()`: bare
429, body `token budget exhausted`; issue redhat-et/pricetag-metering#107 asks
for `Retry-After` plus a JSON reason/reset). `scripts/hosted_only_hooks.py`
already parses every shape we expect, uses the upstream reset when present, and
**says so when upstream sends something it does not handle** instead of
silently mis-handling it. This note is the event contract `llm-usage` renders.

## Where

Events: `${LLM_USAGE_DIR:-~/.local/state/llm-usage}/events-YYYY-MM.jsonl`
(`scripts/litellm_usage_log.py`). Proxy log: one WARNING line per drift signal
per proxy lifetime (`hosted_only_hooks DRIFT [<kind>] <detail> -- <hint>`).

## Event fields (rewritten 429 events; all additive)

| field | value |
|---|---|
| `reset_at` | epoch seconds of the reset the client was told (int) |
| `reset_source` | `upstream-header:<name>`, `upstream-body:<field>`, `estimate:next-month-utc`, `estimate:default`, `reuse:last-reset` (router cooldown re-answers with the last reset), `unknown:rewritten` (logger saw the already-rewritten 503) |
| `drift` | list of `{kind, detail, hint}`; **absent = no drift** |
| `quota` | existing: true when the limit is a quota (monthly) |

Examples:

```json
{"status":503,"upstream_status":429,"rewritten":true,"retry_after":3723,"quota":true,
 "reset_at":1793491200,"reset_source":"upstream-body:reset_at"}
{"upstream_status":429,"retry_after":60,"reset_at":1793000060,"reset_source":"estimate:default",
 "drift":[{"kind":"unhandled_header","detail":"x-quota-window-end=2026-11-01",
           "hint":"update hosted_only_hooks.parse_reset_headers to parse x-quota-window-end"}]}
```

## Drift kinds

| kind | meaning | `detail` | `hint` |
|---|---|---|---|
| `unhandled_header` | upstream response header matching `/rate\|retry\|reset\|quota\|limit/i` that we neither parse nor know to be informational | `<name>=<value, 60 chars>` | `update hosted_only_hooks.parse_reset_headers to parse <name>` |
| `unhandled_body_field` | JSON error body key (top level or under `error`) matching the same pattern that we ignore | `<key>=<value, 60 chars>` | `update hosted_only_hooks.parse_reset_body to parse <key>` |
| `estimate_mismatch` | upstream gave a reset for a quota and our `next-month-utc` estimate differs by more than max(60 s, min(5%, 5 min)) (non-UTC month boundary, rolling window, ...) | `next-month-utc: estimate <iso>, upstream <iso>` | `estimate rule next-month-utc is wrong: upstream says <iso>; update limit_reset` |
| `kind_mismatch` | upstream error type/reason says quota but the `token budget exhausted` text rule says rate-limit, or the reverse; we follow upstream | `upstream says <kind>, text rule says <kind>` | `update hosted_only_hooks.limit_reset: classify with the upstream error type/reason, ...` |
| `shape_changed` | 429 body is JSON (not plain text) and nothing in it is recognised (no reset, no known type/reason) | `json error body keys: <sorted keys>` | `update hosted_only_hooks.parse_reset_body / limit_reset: ...` |

A `drift` entry means "reset/kind may be wrong or less exact than it could be;
code needs the change in `hint`". Unchanged plain-text `token budget
exhausted` produces no drift.

## Shapes parsed (most specific wins)

1. `retry-after-ms`; 2. `Retry-After` (seconds or HTTP-date); 3. JSON body
`error.reset_at` / `resets_at` (epoch or RFC3339), `reset_after_seconds`,
`retry_after` (`_seconds`, `_ms`); 4. OpenAI `x-ratelimit-reset-{requests,tokens,...}`
(`1s`, `6m0s`, `1h2m3.5s`, or bare seconds; the dimension with
`x-ratelimit-remaining-*` = 0 decides, else the earliest); 5. Anthropic
`anthropic-ratelimit-unified-reset`, `-{requests,tokens,input-tokens,output-tokens}-reset`
(RFC3339 or epoch), `-unified-{5h,7d}-reset`; 6. IETF `RateLimit`
(`reset=`/`t=`, `remaining=`/`r=`) and `RateLimit-Reset`; 7. `reset_at` /
`x-ratelimit-reset`; Copilot `x-usage-ratelimit-{session,weekly}` (`rem=<pct>&rst=<ISO>`, rank 6, exhausted one decides). Names verified in source: praxis `token_rate_limit`
(`filters/src/token_rate_limit/mod.rs`) sends `Retry-After` and
`X-RateLimit-{Limit,Remaining,Reset}-Tokens`, reset as bare integer seconds;
LiteLLM sends `retry-after`, `x-ratelimit-{limit,remaining,reset}-{input,output}-tokens`
(reset in seconds) and a `reset_at` header. Quota vs rate limit comes from
`error.reason` (`monthly_*` quota; `per_minute`, `rpm`, ... rate), then
`error.type`/`code` (`insufficient_quota`, `quota_exceeded`, `usage_limit_reached` quota;
`rate_limit_exceeded`, `rate_limit_error` rate), then the `token budget exhausted` text;
an upstream reset more than 24 h away with no explicit kind counts as quota.

## Client rewrite with an upstream reset

The upstream reset replaces the estimate on all routes: Claude 503
`(reset after ...)`, Codex 429 `x-codex-primary-reset-at` + `error.resets_at`,
chat-completions 402 `Quota resets <ISO>` / 429 `retry-after`. On the two 429
routes upstream `retry-after-ms`, `x-ratelimit-*` and `RateLimit-*` headers are
passed through (ours win on `retry-after`, `x-codex-*`). Not passed through: on
the Claude 503 (the handler fixes its headers; only `retry-after`
and `x-should-retry` are added) and on the chat 402 (`retry-after*` would make
OpenCode retry). If upstream starts sending its own `insufficient_quota` / 402,
our rewrite stays consistent: quota on the chat route is already 402
`insufficient_quota`; no change needed.

## Copilot-style limit answers (docs/notes/copilot-api-429-handling.md)

`is_limit_error` also treats as a limit (so they are analysed, logged with
`reset_source`, and rewritten like a 429): status 402 (quota used up), status
503 whose text says `upstream rate limited` (a limit, not a server fault;
`metering system unavailable` stays untouched), and any status with JSON
`error.code == "rate_limited"`. `retry_after` is read from `error` or the top
level. Events keep the real `upstream_status` (402/503); `status` is what the
client sees. A reset inferred only from length (> 24 h, no kind signal) is
treated as quota without an `estimate_mismatch` check.
