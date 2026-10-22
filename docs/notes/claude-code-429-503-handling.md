# Claude Code 2.1.304: how it treats 429 / 503 / 529 from a custom `ANTHROPIC_BASE_URL` gateway

Research date 2026-10-22. Binary `~/.local/share/claude/versions/2.1.304` (Mach-O arm64, minified JS inside).
Offsets below = character offsets in `strings -a <binary>` output (`/tmp/cc429/cc.txt`); minified names are version-specific.
Scope was cut mid-way (user: no more live experiments): items are labelled
**已測** (observed against a local stub gateway) or **僅程式碼推得（未實測）** (read from the bundle, not run).
Consumer reference: T3 `ClaudeAdapterV2.ts` (`git show upstream/main:apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts`, L3162-3180 gateway-503 regex, L7429 `rate_limit_event`).

## Verdict

**Our shape is OK. No change is required for T3 auto-resume to work.** The only thing that matters is the exact string in the stream-json `result`, and it survives intact.
There is **no cleaner native path**: `rate_limit_event` is not emitted for API-key / auth-token + custom-base-URL 429s (已測). Keep the 503 text hack.
Optional hardening patches are listed at the end; two of them are untested.

## Evidence table

| # | Question | Finding (symbol / snippet / offset) | Status | Verdict for our shape |
|---|---|---|---|---|
| 1a | Statuses retried | Main loop `zTe` (@27,365,000-27,377,500). Non-retryable set `qcr=new Set([401,407,429,404,403,413])` only matters for the *exit* branch; retry decision is `Qcr(e)` (@27,381,153): 408, 409, 429 (non-subscriber), `status>=500`, `"type":"overloaded_error"` in message → retry. 529 (`ZW`: `e.status===529\|\|message.includes('"type":"overloaded_error"')`) retried. `x-should-retry:"false"` → `return!1` for ANY status. | 已測 (503, 529, 429 retried; counts below) | 503 retried by default → we rely on that for ≤60s waits. OK |
| 1b | Max retries | `Acr=10`; `tJe()`: `CLAUDE_CODE_MAX_RETRIES` if `>=0`, clamped to `NQe=15` ("clamped to 15" warning); watchdog (`CLAUDE_CODE_RETRY_WATCHDOG`) default `Pcr=300`. | 已測 (plain 503: 11 attempts, `api_retry max_retries:10`) | OK |
| 1c | Backoff | `L$(e,r,a=32000,s=Math.random,n=500)`: `Gy({attempt,baseMs:n,capMs:a,jitter:{proportional,ratio:eWo=0.25}})`; `if(r){let i=parseInt(r,10);if(!isNaN(i))return Math.max(i*1000,o)}`. Plain-503 delays seen: 510, 1171, 2452, 4065, 8018, 16650, 37945, 33252, 36514, 39492 ms (cap 32 s ±25%). | 已測 | n/a |
| 1d | `retry-after` honored, 503 too? | `BQe(e)`=`(e.headers?.["retry-after"]\|\|e.headers?.get?.("retry-after"))??null` (@27,378,536), same path for every retryable error, not 429-specific. Format: **integer seconds only** (`parseInt`; HTTP-date → NaN → ignored). `retry-after-ms` NOT read by the main loop. Seen on our 503: `api_retry retry_delay_ms: 60000, error_status: 503`. | 已測 | `retry-after: <int seconds>` on 503 is honored. OK |
| 1e | `x-should-retry` precedence | `Qcr`: `r=e.headers?.get("x-should-retry");if(r==="true"&&(!kt()\|\|gne()\|\|umn(e)))return!0;if(r==="false"){…return!1}` — checked BEFORE status rules, so `false` beats 5xx/429. SDK layer `shouldRetry` (@20,186,800): `h==="true"→true; h==="false"→false; 408/409/429/>=500→true`. | 僅程式碼推得（未實測）for `false` header on the wire; the >60s fail-fast was 已測 | OK |
| 1f | >60s branch | In `zTe` after computing `xr=L$(Un+q,sr,yr,…)`: `else if(xr>Math.max(Bcr,Math.ceil((yr??0)*(1+eWo))))throw i("tengu_api_retry_after_too_long",{delayMs:xr,status:an.status,provider:_T()}),m("api_request","api_request_retry_after_too_long"),new Gc(an,y)` with `Bcr=60000`, `yr` = `CLAUDE_CODE_OVERLOADED_RETRY_MAX_DELAY_MS` (529 only, else undefined → threshold exactly 60 000 ms). Throws `Gc`(RetryError wrapping the original API error) → no sleep. **60 s exactly still sleeps** (`60000 > 60000` false). Applies to any retryable status (503 included), independent of `x-should-retry`. | 已測: budget case (retry-after ≈813 000 s) → exactly 1 attempt, wall 9.8 s total incl. 6.7 s startup. bare 429→503 `retry-after: 60` → slept 60 000 ms twice (wall 139 s with `MAX_RETRIES=2`). direct 429 `retry-after: 120` → 1 attempt, 42 ms. | Our threshold `CLIENT_RETRY_MAX_SECONDS=60` matches CC's. OK. `x-should-retry:false` is redundant for the main loop (CC already fails fast) but still needed for SDK/side-query retries, see 1g |
| 1g | Other strings | `api_request_usage_limit_wait_too_long` / `api_request_capacity_wait_exhausted` / `tengu_api_persistent_retry_wait` fire only in watchdog mode (`Z4()=CLAUDE_CODE_RETRY_WATCHDOG`): waits up to `imn=21600000` (6 h), usage-limit branch only when `anthropic-ratelimit-unified-status==="rejected"` + `-unified-reset`. `lowPriorityWait` (`ADr`/`Ig`) needs the unified limiter state + `slot_busy`/`capacity_busy`: subscriber feature. Side queries (auto-mode classifier etc.) use the SDK retry: `rTt` (@24,936,420) rewrites 429/529 with `retry-after>=cap` into `x-should-retry:false` + `x-cc-retry-after-too-long`; **503 is not in that list**, so for 503 an explicit `x-should-retry:false` is the only guard (SDK `retryRequest` accepts 0<ms≤2 147 483 647, ≈24.8 days). | 僅程式碼推得（未實測） | Keep our `x-should-retry:false` on long 503. OK |
| 2a | Final error string, 503 | `r6o` (@26,238,800+): `status>=500` → ``{content:`${Nl}: ${H}. This is a server-side issue, usually temporary — try again in a moment.${y}`}`` with `Nl="API Error"`, `H=Ohe(e)` = `"<status> <upstream error.message>"`, `y=Lbr()` = ` If it persists, check your inference gateway (<host:port>).` Trailing `[.!?…]` of H stripped. | 已測 | see 2c |
| 2b | Final error string, 429 / 529 | 429 non-subscriber: ``API Error: Request rejected (429) · <upstream error.message>`` (`ve="Request rejected (429)"`, `we=ke\|\|_e`, `ke=error.message` parsed from JSON). 529: `API Error: 529 Overloaded. This is a server-side issue…` (same 5xx branch). stream-json `result`: `terminal_reason:"api_error"`, `api_error_status:<http status>`, `is_error:true`, subtype `success`. | 已測 (direct stub: `Request rejected (429) · slow down`, status 429; 529 text above) | A raw 429 reaches T3 as `api_error_status:429` with no reset → T3 `usage_limit` without `resetAt` (no auto-resume). Hence our 429→503 rewrite is needed. OK |
| 2c | Does `[429]: {…} (reset after …)` survive? | Yes. Observed `result` (via proxy, budget case): `API Error: 503 [rits/zai-org/glm-5-3] [429]: {"type":"error","error":{"type":"rate_limit_error","message":"Monthly token budget exhausted."}} (reset after 225h 58m 48s). This is a server-side issue, usually temporary — try again in a moment. If it persists, check your inference gateway (127.0.0.1:4158).` with `terminal_reason:"api_error"`, `api_error_status:503`, `is_error:true`. Bare-429 case: `… "message":"Rate limit reached."}} (reset after 1m). This is a server-side…`. | 已測 | T3 regex `^API Error: 503 \[[^\]\r\n]+\] \[429\]: \{"type":"error","error":\{"type":"rate_limit_error",[^\r\n]*\} \(reset after (?:(\d+)h ?)?(?:(\d+)m ?)?(?:(\d+)s)?\)` (copied from upstream/main L3168) matches both real strings (checked: groups `('225','58','48')` and `(None,'1',None)`); not end-anchored so CC's appended sentence is harmless. T3 gate `message.is_error && terminal_reason==="api_error" && api_error_status===503` also true. **OK** |
| 3a | Where unified headers are read | `Re(e,n)` (@22,899,331) reads `anthropic-ratelimit-unified-status/-reset/-overage-status/-overage-reset/-overage-disabled-reason/-representative-claim/-fallback/…` → status object; `CAs(e)` builds `{status:"rejected",resetsAt,rateLimitType,…}` from a 429's headers (@22,896,298); `Sds(e,n)` (@32,901,346) wraps into `{type:"rate_limit_event",rate_limit_info,uuid,session_id}`; listener `Iv` (@52,756,863) subscribes via `Wie` and emits frames. | 僅程式碼推得（未實測） | n/a |
| 3b | Gate | 429 message path `r6o`: `if(e instanceof Ot&&e.status===429){let H=rtn(kt()),q=CAs(e)…if(H&&q&&!Q){let Ie=_bo(q,n);if(Ie)return $s({content:Ie,error:"rate_limit",…_Xs(Ie)&&{apiError:"usage_limit_reached",apiErrorParams:{rate_limit_info:Dbr(q)}}`. `rtn(e)=e\|\|Pe()==="gateway"\|\|Dyt()`; `kt()` = claude.ai OAuth subscriber scopes (`IW(Mn()?.scopes)`); `Pe()==="gateway"` only for host-injected credential slots (`credentialSlots.gatewayAuth/gatewayServerProcess/gatewayRequiredByHostPolicy`, i.e. embedders, NOT plain `ANTHROPIC_BASE_URL`); `Dyt()` is `return!1` in this build. | partial: 已測 (below); the `Pe()==="gateway"` embedder case 僅程式碼推得（未實測） | n/a |
| 3c | Experiment | Direct to stub (no proxy), `ANTHROPIC_AUTH_TOKEN`, isolated `CLAUDE_CONFIG_DIR`, 429 with `anthropic-ratelimit-unified-status: rejected`, `-reset: <epoch+3h>`, `-representative-claim: five_hour`, `-5h-status/-5h-reset/-5h-utilization`: **no `rate_limit_event`** in stream-json (event types: `system:init, system:api_retry ×2, assistant, result`). Retried like a plain 429 (3 attempts, backoffs 590 / 1139 ms), reset header ignored; final `API Error: Request rejected (429) · slow down`, `api_error_status:429`. Adding `retry-after: 7200` + `-overage-disabled-reason: org_level_disabled`: 1 attempt, no retry (`Zcr`/`cmn` billing-style non-retry), same final text, still no event. | 已測 | Native path NOT available for our auth (API-key / auth-token + base URL). Keep the 503 text hack. No header work needed in `ResetAfterHeaders` |
| 4 | Strings that flip CC into throttle / billing handling | see list below | 僅程式碼推得（未實測） | We emit none of them. OK (keep it that way) |
| 5 | Side effect of LiteLLM in front | Each CC attempt made **3 upstream calls** (LiteLLM default `num_retries`, ~1.1 s + ~1.6 s backoff): stub saw 3 hits per CC attempt (budget: 3 hits, +2.7 s before the 503; bare429 `MAX_RETRIES=2`: 9 hits, 3 uvicorn `POST /v1/messages 503` lines). Router cooldown can also answer later attempts itself (`RouterRateLimitError`, no upstream call; our `LAST_LIMIT_RESET` handles it). | 已測 | Not harmful to T3, but wasteful on a hard budget 429. Patch B below |

### Timing / attempt table (本地 stub 實測 — 已測)

| Scenario | Path | CC attempts | Waits | Wall | Final `result` |
|---|---|---|---|---|---|
| (a) praxis `token budget exhausted` (monthly, >60 s) | CC→proxy→stub | 1 (3 upstream) | none (fail fast, `retry-after`≈813 000 s) | 9.8 s (13.0 s 2nd run) | 503 `[429]: … "Monthly token budget exhausted." … (reset after 225h 58m 48s)` ✔ T3 regex |
| (b) bare 429 (60 s default) | CC→proxy→stub, `CLAUDE_CODE_MAX_RETRIES=2` | 3 (9 upstream) | 60 000 ms ×2 | 139.1 s | 503 `[429]: … "Rate limit reached." … (reset after 1m)` ✔ |
| (b′) same, default 10 retries | — | would be 11 × 60 s ≈ 10.5 min | | | 僅程式碼推得（未實測） |
| (c) upstream `retry-after: 5` via proxy | — | — | — | — | 僅程式碼推得（未實測）: `upstream_retry_after` → 503 `retry-after: 5` → CC sleeps 5 s. Direct (no proxy) 429 `retry-after:5`: 3 attempts, 5000 ms ×2, 10.4 s, `Request rejected (429) · slow down` (已測) |
| (d) plain 503 via proxy | CC→proxy→stub, default retries | 11 | 510 … 39 492 ms | 239.9 s | `API Error: 503 service unavailable. Received Model Group=rits/zai-org/glm-5-3 / Available Model Group Fallbacks=None. This is a server-side issue…` (LiteLLM's own text; not a limit, no `[429]`) |
| (e) 529 | direct stub, `MAX_RETRIES=3` | 4 | 608 / 1021 / 2391 ms | 4.4 s | `API Error: 529 Overloaded. This is a server-side issue…`, `api_error_status:529`. Via proxy: 僅程式碼推得（未實測） (our hook never touches 529) |
| 429 `retry-after: 120` direct | stub | 1 | none | 0.8 s | `Request rejected (429) · slow down` |

## Item 4: strings / signals Claude Code keys off

- Non-retry (billing-style) on 429 — `Qcr` / `Zcr` (@27,381,153+): body `error.details.error_code === "credits_required"`; message (lower-cased) contains `usage credits are required` or `extra usage is required`; message contains `service_spend_limit_reached`; header `anthropic-ratelimit-unified-overage-disabled-reason` in {`org_spend_cap_reached`, `org_level_disabled_until`} (and, when unified claim headers are absent, also `out_of_credits`, `org_level_disabled`, `org_service_level_disabled`); message contains `exceeded_limit` plus `"overageDisabledReason":"<one of those>"`; error `type==="billing_error"` → `api_request_non_retryable`. (已測 for `org_level_disabled` header only.)
- Overload recognition: status 529 **or** any message containing `"type":"overloaded_error"` (`ZW`, even on a 503/200) → retried; after `dZ=3` consecutive 529s with a fallback model configured → model fallback (`tengu_api_opus_fallback_triggered`); without `fallbackModel` and `!IS_SANDBOX` it throws "Repeated 529 Overloaded errors" for opus/fable/sonnet tier models when `FALLBACK_FOR_ALL_PRIMARY_MODELS` or non-subscriber with tier model (`Qle/U2e/b1t`). Avoid `overloaded_error` text in our 503/429 bodies. (僅程式碼推得)
- Rate-limit recognition by text: `_e(e)`: status 429 or message includes `"type":"rate_limit_error"` — our rewritten 503 message contains exactly that; it does not change retry behaviour (retry comes from `Qcr` status>=500), only classification helpers.
- `x-should-retry`: `true` (retry; non-subscriber) / `false` (stop, any status). `request-id` is only surfaced in errors (`requestId`).
- Error-class mapping: 429 → `error:"rate_limit"`; ≥500 and 529 → `error:"server_error"`; `terminal_reason:"api_error"`, `api_error_status` = HTTP status in `result`.
- Do **not** emit: `credit balance`/`usage credits`/`exceeded_limit`/`service_spend_limit_reached` text, `overloaded_error`, `anthropic-ratelimit-unified-*` headers on our errors (they flip CC into subscriber/billing branches; headers alone gave no event but did change retry behaviour in the `org_level_disabled` case).

## Proposed patches (NOT applied; diffs against `~/git/dotfiles`)

### A. Docstring correction only (no behaviour change)

The current note says Claude Code's SDK "would sleep for as long as `retry-after`" on a long wait. The main loop does not (it fails fast >60 s, 已測); only the SDK-level retry (side queries) would, and only for 503 (429/529 get `rTt`).

```diff
--- a/scripts/hosted_only_hooks.py
+++ b/scripts/hosted_only_hooks.py
@@ docstring item 5, Claude bullet
-     Waits over HOSTED_ONLY_CLIENT_RETRY_MAX_SECONDS (default 60) also get
-     `x-should-retry: false` so Claude Code stops retrying (its SDK would
-     sleep for as long as `retry-after`, up to ~24 days); T3 holds and
-     resumes. Shorter waits stay retryable inside Claude Code.
+     Waits over HOSTED_ONLY_CLIENT_RETRY_MAX_SECONDS (default 60) also get
+     `x-should-retry: false`. Claude Code's main loop already gives up when
+     retry-after > 60 s (`api_request_retry_after_too_long`), so the header
+     matters for its SDK-level retries (side queries), which would otherwise
+     honor retry-after up to ~24.8 days on a 503. T3 holds and resumes.
+     Waits <= 60 s stay retryable: Claude Code sleeps retry-after (exactly 60
+     still sleeps) up to 10 times (~10 min) before the error surfaces.
```

### B. Stop LiteLLM from retrying upstream 429s (untested config; recommended after a quick check)

Each Claude Code attempt currently costs 3 upstream calls and ~2.7 s before the rewrite. In `_hosted_only_proxy_config` (`scripts/hosted-only-proxy.zsh`):

```diff
     print -r -- "litellm_settings:
   drop_params: true"
     print -r -- '  callbacks: ["hosted_only_hooks.proxy_handler_instance", "litellm_usage_log.proxy_handler_instance"]'
+    # Claude Code / Codex retry on their own; LiteLLM's default 2 upstream
+    # retries just triple every 429 (3 stub hits per client attempt, +2.7 s).
+    print -r -- "router_settings:
+  num_retries: 0"
     print -r -- "general_settings:
   master_key: os.environ/HOSTED_ONLY_PROXY_TOKEN"
```

Unverified: whether `router_settings.num_retries` applies to the `/v1/messages` passthrough route in litellm 1.97.0 (a private proxy with this setting was started but the test was cut). Changes the config fingerprint → running proxies need the usual restart. Also changes retry behaviour for transient upstream 5xx (client retries instead).

### C. Optional: bound the "default 60 s" stall for T3 (judgement call)

Bare per-minute 429s become 503 `retry-after: 60`, retryable, so Claude Code sleeps 60 s up to 10 times (~10.5 min, 僅程式碼推得 for the default; 139 s measured at `MAX_RETRIES=2`) before T3 sees any error. Choose one:

1. Keep as is (bursts are absorbed silently; sustained limits cost ~10 min).
2. `HOSTED_ONLY_CLIENT_RETRY_MAX_SECONDS=0` → every rewritten 503 gets `x-should-retry:false`, T3 always sees it at once and holds until the stated reset (1 min for per-minute limits).
3. Bound retries in the launcher env, `zsh/functions/claude/providers/hosted-only.zsh` settings `env`: add `CLAUDE_CODE_MAX_RETRIES: "3"` (worst case ~3 min for 60 s waits; also shortens retries for real 5xx).

Recommendation: 3 (or 2 if T3 auto-resume is considered reliable for short waits).

## Housekeeping: ports / pids started and stopped (all stopped; other sessions' processes untouched)

| Port | What | Pid(s) | State |
|---|---|---|---|
| 4159 | stub gateway (first round) | 49766 | killed |
| 4170 | direct stub | 1562 | killed |
| 4158 | claude-flavor test proxy (two instances; 2nd restarted after fingerprint change) | 49795/49798, then 96740/96746 | stopped (`_hosted_only_proxy_stop claude`, then pid kill) |
| 4156 | private proxy (`/tmp/cc429-px`, `router_settings.num_retries:0`, never exercised) | 13783/13793 | killed |
| 4181 | claude-flavor test proxy (assigned port) | 37728/37731 | stopped (`_hosted_only_proxy_stop claude`) |
| 4183 / 4184 | stub gateway / direct stub (assigned ports) | 37695 / 37697 | killed |
| 4157 codex proxy (pids 50640/50643) and stub on 4160 (pid 49725) | **not mine**, never touched | | left running |

Side effect to know about: before the `LLM_USAGE_DIR` instruction arrived, my 4158 test proxy appended to the real `~/.local/state/llm-usage/events-2026-10.jsonl`: 154 events with `"port":"4158"` (111 of them `"upstream":"127.0.0.1:4159"`, i.e. my stub, all failed/limit events). Not deleted (outside my read-only scope); filter them out in `llm-usage` stats with `port=4158` + `upstream=127.0.0.1:4159`. The 4181 run wrote to `/tmp/cc429-usage` instead. Leftover files: `/tmp/cc429*` (scratch, safe to delete), `~/.local/state/hosted-only-claude-4158/` and `-4181/` (test runtime dirs, safe to delete).

## Not verified

- Behaviour of `rate_limit_event` when T3 embeds via the Agent SDK with a host-injected gateway credential (`Pe()==="gateway"` branch) — code-only reading.
- 529 and `retry-after: 5` **through** the proxy (only direct stub measured); `x-should-retry:false` header on the wire for >60 s 503 (fail-fast was observed, but via the `retry-after` rule, not the header); SDK-level side-query retry on 503.
- Patch B effect; whether the 10-retry × 60 s stall actually plays out end to end (measured with `MAX_RETRIES=2` only).
- Successful (200) responses carrying unified headers (could emit `rate_limit_event` for subscribers) — not tested; irrelevant for limit errors.
