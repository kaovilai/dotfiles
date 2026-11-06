# Go proxy for the hosted-only and EnMaaS launchers

The stdlib-only Go binary in `scripts/hosted-only-go` is the **default** proxy
for the hosted-only launchers (`claude-hosted-only`, `codex-hosted-only` and
their T3 launchers); `litellm[proxy]` stays as the escape hatch. EnMaaS
(`claude-enmaas`, :4146) keeps LiteLLM by default and runs Go on request — see
"Why EnMaaS stays on LiteLLM" below.

It serves both current proxies from one binary:

| flavor | port | config source |
|---|---|---|
| `claude` / `codex` (hosted-only) | 4148, one shared process (4147 only when `HOSTED_ONLY_CODEX_PROXY_PORT` splits it off) | the merged `config.yaml`: bare groups = anthropic, `#openai` groups = OpenAI-wire |
| `enmaas` | 4146 | the launcher's generated `config.json`, read as a route table |

## Why

The proxies are local, single-upstream protocol shims, but each one paid for a
full AI gateway: measured on this repo's machines, `import litellm` costs
~268 MB and `import litellm` + FastAPI/uvicorn ~377 MB before serving a
request, per flavor, inside a `uv tool` environment. Before #599 that was three
processes (enmaas + Claude + Codex), ~900 MB and three slow cold starts; today
it is two (enmaas :4146, merged hosted-only :4148). The Go binary is ~10 MB and
starts in milliseconds.

## Choosing the impl

| knob | effect |
|---|---|
| (unset) | hosted-only: `auto` = go when a go toolchain is installed, else litellm. EnMaaS: litellm |
| `HOSTED_ONLY_PROXY_IMPL=litellm\|go\|auto` | the hosted-only launchers (also the retired `GLM_HYBRID_PROXY_IMPL`) |
| `CLAUDE_ENMAAS_PROXY_IMPL=litellm\|go` | the EnMaaS controller |
| `LLM_PROXY_IMPL=litellm\|go` | every proxy at once; a per-launcher knob beats it |

```zsh
LLM_PROXY_IMPL=litellm claude-hosted-only     # the escape hatch, this launch
export LLM_PROXY_IMPL=litellm                 # every launcher in this shell
CLAUDE_ENMAAS_PROXY_IMPL=go claude-enmaas     # opt the EnMaaS proxy into Go
```

The knob is part of the proxy fingerprint, like a hook edit, so flipping it
restarts an idle proxy on the next launch; one serving a request is reused with
a notice until `claude-hosted-only-restart` / `claude-enmaas-restart` /
`codex-hosted-only --stop-proxy`. The first restart after the default flipped is
a LiteLLM→Go swap on the shared port: the running LiteLLM listener shares it
through the runtime shim's `SO_REUSEPORT` (#613), the old pid is retired only
once the Go listener answers, and the probe in the soak saw zero refusals.

The first start builds the binary into
`${XDG_STATE_HOME:-~/.local/state}/hosted-only-go/`, rebuilding when a module
source changes. Ports, tokens, state dirs, the fingerprint protocol and the stop
commands are unchanged.

## Lifecycle (Go impl)

The binary owns its own process management, so the launcher's Go path is a knob
resolution plus one call (and the watcher is one static process instead of a
zsh loop that spawns lsof/jq twice a second):

- `ensure --flavor F --port P --runtime-dir D --fingerprint FP --token-fp TF`
  takes `startup.lock` (interoperating with the zsh launcher's flock), compares
  the running proxy's recorded fingerprint, restarts an idle stale one (the Go
  `stop` also retires a stale LiteLLM listener after an impl switch), refuses
  only a token change under a busy proxy, spawns the serve mode detached with
  the same 8 MB log rotation, waits for health (~ms, not LiteLLM's 96 s) and
  records the fingerprint. For the hosted-only flavors it writes `routes.json`
  itself from the knobs, so a watcher-driven restart never pairs a new
  fingerprint with an old route table.
- **Zero-refuse restarts (#612).** The serve listener binds with `SO_REUSEPORT`
  (`reuseport_linux.go` carries the Linux constant the stdlib does not export),
  so a stale restart starts the replacement ALONGSIDE the old listener, waits
  until a listener outside the old pid set answers health, then retires the old
  pids — a request arriving mid-restart is never refused. An old listener that
  predates the patch cannot share the port; the new process then exits at bind
  and `ensure` falls back to stop-then-start once. `HOSTED_ONLY_FORCE_RESTART`
  forces the swap even when the fingerprint is current or the proxy is busy, the
  same knob the `*-hosted-only-restart` commands use on the LiteLLM path.
- `stop --flavor F --port P --runtime-dir D [--legacy-runtime D…]` is the
  identity-checked stop: only listeners whose command line names this proxy's
  config under the current or a legacy runtime dir.
- `status` reports health, busy, listener pids and the recorded fingerprint as
  JSON.
- `watch … --name N --state-dir DIR` is the Go `llm-proxy-watch`: polls the
  port's inflight files (same source as `_claude_port_serving`), restarts at
  the first idle moment (two consecutive idle polls), keeps the
  `watch-<name>.{pid,log}` contract and exits when current, gone, restarted or
  past `LLM_PROXY_WATCH_TIMEOUT`. `llm-proxy-watch glm-claude|glm-codex` execs
  it when the impl is go; LiteLLM proxies keep the zsh loop.

## Why the ports stay

Ports are load-bearing even with one binary:

- **Policy boundary.** :4146 serves the whole discovered EnMaaS catalog; the
  hosted-only proxy serves only the merged groups in its own config (GLM,
  DeepSeek, the Claude alias — no wildcard). That allowlist is the hosted-only
  cost guard.
- **Client configuration.** Each launcher points Claude Code at
  `ANTHROPIC_BASE_URL` and Codex at its provider `base_url`; the port *is* the
  mode selector. The two hosted-only clients already share :4148 (main's #599
  merge); EnMaaS stays on :4146 because it is a different catalog and policy.
- **Usage attribution.** `llm-usage`, the menubar and
  `inflight-<port>-<pid>.json` key providers by port (`PROVIDER_PORTS`).

The **process count** is not a boundary: the same binary serves any flavor on
its own port, and one build can run per flavor. Collapsing to one multi-listener
process would change lifecycle semantics (per-flavor stop/restart, the "never
restart under a live session" rule) for a few MB; it is not done here.

## Hosted-only flavor (merged config)

After #599 the launcher generates one `model_list` with both dialects of both
models: bare groups carry `anthropic/<id>` (Messages at the gateway root) and
`<id>#openai` groups carry `openai/<id>` (chat/Responses at `/v1`). The launcher
derives an equivalent `routes.json` from the same knobs (the Go binary does not
parse YAML) and the proxy picks the group by endpoint — bare on `/v1/messages`,
the `#openai` sibling on OpenAI-wire paths — so one process serves both clients,
exactly like the merged LiteLLM. Tokens, the shared runtime dir, the fingerprint
and the stop helper are unchanged; the cost guard is the absence of a wildcard
in that table, and an id outside it answers 400.

## EnMaaS flavor

The launcher already generates LiteLLM `config.json` (per-id dialect,
`api_base`, `<id>#responses` siblings, `master_key`). The Go proxy reads that
file as its route table instead of inventing a second format:

- `anthropic/<id>` → `/v1/messages` at the gateway root (Claude Code, GLM,
  DeepSeek on the Messages dialect).
- `openai/<id>` → `/v1/chat/completions`, or `/v1/responses` when the client
  uses the Responses endpoint.
- `openai/responses/<id>` → Responses dialect.
- `<id>#responses` sibling → served on `/v1/responses` (mirrors
  `enmaas_proxy_hooks.route_model`); the suffix is stripped before upstream.
- `*` (wildcard) → openai chat for any id not registered.
- Local token = `general_settings.master_key`.

Behaviour ported from the EnMaaS hooks: the `rits/` web-search drop (shared with
hosted-only), Codex `additional_tools` items flattened into `tools`
(`unwrap_tools_middleware.py`), and per-endpoint fallback naming falls out of
the route table. Python hooks and the DoH shim are not installed on this path.

## What the Go path implements (all flavors)

- **Transport:** `/v1/messages`, `/v1/chat/completions`, `/v1/responses`, SSE
  streaming with per-chunk flush, `/health/liveliness`, `/v1/models`,
  `/v1/messages/count_tokens` (byte estimate, no tokenizer).
- **Auth:** the local token via `x-api-key` or `Authorization: Bearer`; the
  upstream key never reaches the client.
- **Request rewrites** for `rits/` models and GLM aliases: alias → GLM id,
  image-in-history → DeepSeek, grammar strip, hosted `web_search` removed plus
  the in-band note, `thinking: disabled` on Messages requests that send none,
  empty developer items dropped, `tool_reference` blocks dropped, `max_tokens`
  clamped to the window with the compaction 400.
- **Cost guard:** the hosted-only flavors answer 400 for any model id they do
  not serve (LiteLLM's `model_list` restriction), instead of forwarding it with
  the real upstream key.
- **Limit/outage rewrite:** 429/402, 503 `upstream rate limited` and JSON
  `error.code: rate_limited`; outages are 408/502/504/524, 503
  `no_db_connection`, 500 connection errors and transport failures (excluding
  client cancels). Reset from the ranked header/body signals, else the
  next-month quota estimate or the per-minute default, with the same per-dialect
  shapes: Messages → 503 + `retry-after`/`x-should-retry`; chat → 429 or 402
  `insufficient_quota`; Responses → 429 with `resets_at` + `x-codex-*`.
  Backoff uses `HOSTED_ONLY_OUTAGE_RETRY_SECONDS` / `_MAX_SECONDS`.
- **Model fallback:** one retry with the other hosted model for image-free
  requests on 408/429/5xx/transport errors.
- **Usage:** the same `events-YYYY-MM.jsonl` schema (`llm-usage`) and the
  `inflight-<port>-<pid>.json` file, with token counts parsed from SSE and
  OpenAI cached tokens normalized (`in` excludes `cache_read`).
- **Performance:** one keep-alive/HTTP/2 transport per process; a request whose
  body the rewrites did not change is forwarded byte-for-byte instead of being
  re-marshaled (the common EnMaaS path).

## Known differences from the LiteLLM path

- **No dialect translation** (the reason EnMaaS stays on LiteLLM, below).
- **Drift diagnostics** and the LiteLLM router `reuse:last-reset` path.
- `cost` is not computed (LiteLLM's `model_cost`); `llm-usage` tolerates it.

Ported since the first cut, each pinned by a test mirroring the Python hook's:
outage-streak **persistence** across restarts (`HOSTED_ONLY_OUTAGE_STATE`,
atomic, only when the episode count moves, pruned past two windows) with the
coalesce window and the success clear; the **DoH fallback** for the allow-listed
gateway name; the **inline image budget prune**
(`HOSTED_ONLY_IMAGE_BUDGET_BYTES`, default 2.5 MB — the gateway caps a body and
answers 413 — oldest image first, replaced by a note naming the tool call's
path, a matching T3 attachment and a one-day content-addressed proxy copy, same
text every turn for prompt caching; the copies live in
`HOSTED_ONLY_IMAGE_CACHE_DIR`, which must be a directory dedicated to this
proxy: the hourly sweep deletes expired files named `<sha1>.<image ext>`, so a
shared directory could lose a file that happens to match) and the **per-image pricing** in the window
clamp (`HOSTED_ONLY_IMAGE_TOKENS`); the **outage shapes** — 529, the gateway's
503 `metering system unavailable` / `service unavailable`, connect/DNS 500s —
and the `LIMIT_REWRITE` / `OUTAGE_REWRITE` gate split; the **quota-aware
fallback skip** (an account-wide monthly quota gains nothing from trying the
other model); nested `tool_reference` stripping; and the forced `tool_choice`
cleanup after a `web_search` tool is dropped. Graceful drain: SIGTERM stops
accepting and lets in-flight requests finish within a 10 s budget; a swap or
stop waits 15 s before escalating to SIGKILL. A response that takes longer than
the 10 s budget is still cut — the drain is a bound, not a guarantee for long
streams.

## Why EnMaaS stays on LiteLLM

The EnMaaS flavor serves Claude Code over `/v1/messages` for every catalog
model, GPT and Gemini included. Those are chat/Responses deployments, so
something must convert Messages <-> Chat/Responses — tools and streaming
included. LiteLLM does; this proxy forwards bodies, it does not translate. Hosted-only is
unaffected: GLM and DeepSeek speak the Anthropic dialect natively, and the Codex
clients speak the OpenAI wire to the `#openai` deployments.

With the Go impl on EnMaaS, a request whose client dialect does not match the
deployment's is refused with an actionable 400 naming
`CLAUDE_ENMAAS_PROXY_IMPL=litellm`, instead of forwarding a body the upstream
cannot use and handing the client an answer it cannot parse.
`tests/claude-enmaas-proxy.zsh` runs the real-launcher scenarios against both
impls and asserts exactly this boundary. The EnMaaS default flips to Go when the
proxy can translate.

## Tests

```zsh
cd scripts/hosted-only-go && go test ./...   # rewrites, routes, limits, usage
zsh tests/hosted-only-go-proxy.zsh           # end-to-end against a stub upstream
```

The zsh test starts a local stub upstream and the real binary, then covers:
hosted-only auth/alias/pass-through, the 503/429/402 shapes and headers, the
cost guard rejecting an unserved model, usage JSONL fields, the stop helper —
and the EnMaaS flavor: `master_key` auth, anthropic vs chat vs
`#responses`-sibling routing (asserted by the upstream path the stub received),
the wildcard route, and `additional_tools` flattening. It also drives the
launcher's Go path end to end: `ensure` start / fresh no-op / stale restart
with `routes.json` regenerated from the knobs, the `watch` idle restart with
its pid/log contract, and the Go branch of the zsh stop helper. It exits 0
with a `skip:` notice when `go` is not installed.
