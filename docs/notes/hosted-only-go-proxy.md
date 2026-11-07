# Go proxy for the hosted-only and EnMaaS launchers

The stdlib-only Go binary in `scripts/hosted-only-go` is the **only** proxy
for these launchers: the hosted-only ones (`claude-hosted-only`,
`codex-hosted-only` and their T3 launchers) and EnMaaS (`claude-enmaas`,
:4146). The LiteLLM impl is retired — a go toolchain is required, and the old
`HOSTED_ONLY_PROXY_IMPL` / `CLAUDE_ENMAAS_PROXY_IMPL` / `LLM_PROXY_IMPL` =
`litellm` escape-hatch knobs now fail loudly. (The openai and vertex launchers
still run LiteLLM for their own flavors.) EnMaaS needed the Messages <->
chat/Responses translators first — see "EnMaaS: dialect translation" below.

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

## Impl knobs (retired)

`HOSTED_ONLY_PROXY_IMPL`, `CLAUDE_ENMAAS_PROXY_IMPL` and `LLM_PROXY_IMPL` used
to pick the impl. They no longer pick anything: the accepted values (unset,
`auto`, `go`) all mean the Go proxy and do not change the fingerprint, so
flipping an old shell from `auto` to `go` reuses the running proxy as fresh.
`litellm` fails the launch with the retirement message; any other value fails
it with the same error naming the knob. A missing go toolchain fails the launch
the same way (install one — `dnf install golang` / `apt install golang-go`).

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
  `stop` also retires a stale LiteLLM listener left over from before the
  retirement), refuses
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
  same knob the `*-hosted-only-restart` commands use.
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
  it.

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

The launcher generates a `config.json` (per-id dialect, `api_base`,
`<id>#responses` siblings, `master_key` — the shape the config generator has
always produced). The Go proxy reads that file as its route table instead of
inventing a second format:

- `anthropic/<id>` → `/v1/messages` at the gateway root (Claude Code, GLM,
  DeepSeek on the Messages dialect).
- `openai/<id>` → `/v1/chat/completions`, or `/v1/responses` when the client
  uses the Responses endpoint.
- `openai/responses/<id>` → Responses dialect.
- `<id>#responses` sibling → served on `/v1/responses` (what the old
  EnMaaS hook routed); the suffix is stripped before upstream.
- `*` (wildcard) → openai chat for any id not registered.
- Local token = `general_settings.master_key`.

Behaviour ported from the old Python hooks: the `rits/` web-search drop
(shared with hosted-only), Codex `additional_tools` items flattened into
`tools`, and per-endpoint fallback naming falls out of the route table. No
Python hooks or DoH sitecustomize shim are installed; the binary resolves the
gateway name over DoH itself.

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

- Dialect translation exists for **Messages clients only** (the EnMaaS case,
  below); chat/Responses clients keep forwarding to deployments of their own
  dialect and are refused with a 400 for an Anthropic-dialect one.
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

## EnMaaS: dialect translation

The EnMaaS flavor serves Claude Code over `/v1/messages` for every catalog
model, GPT and Gemini included. Those are chat (24 routes today) or, when pinned
with `CLAUDE_ENMAAS_MODEL_DIALECTS`, Responses deployments, so something must
convert Messages <-> chat/Responses — tools and streaming included. LiteLLM
used to; since the translators the Go proxy does it itself, which is what let
the LiteLLM impl retire.

- `translate.go` — the `translator` contract (`Request`, `Response`, `Stream`,
  `Error`), the shared SSE reader and the status -> Anthropic error-type map.
- `translate_chat.go` / `translate_responses.go` — one translator instance per
  request. Server wiring is in `server.go` and `translate_server.go`: a Messages
  client on a chat/Responses deployment is bridged instead of refused, errors
  come back Anthropic-shaped, a translatable fallback is translated before the
  primary answer is given up (a failed translation means no fallback, never an
  untranslated Messages body), and `anthropic-beta` only reaches Anthropic
  deployments.

Behaviors found by running it against the real gateway (2026-11-07), not by
unit tests:

- **`max_completion_tokens`** is the default for chat deployments: `gpt-6-sol`
  rejects `max_tokens`; gemini-3.x, gpt-4o-mini and gpt-5.x all accept the new
  name. Self-hosted `rits/` ids keep `max_tokens`.
- **Gemini 3 thought signatures.** Every tool call carries
  `extra_content.google.thought_signature` and the next turn is a 400 unless it
  is echoed back. A Messages `tool_use` block has no slot for it, so it rides in
  the tool_use id (`<id>__thought__<base64url>`), is split again on the request
  side, and the matching tool message carries the original id.
- **gpt-6-\* want function tools on `/v1/responses`.** On that exact 400 the
  proxy retries once through the Responses translator and remembers the model,
  so only the first request pays the failed chat call.
- Fidelity rules the translators keep: `tool_result` images ride the following
  user message (chat/Responses tool outputs take strings only, so vision
  content survives); `message.refusal` / `delta.refusal` /
  `response.refusal.*` become text instead of a successful empty answer; a
  token-budget cutoff keeps `stop_reason: max_tokens` even when a (truncated)
  tool call was emitted; an upstream SSE error line or `response.failed` ends
  the client stream with an Anthropic `error` event instead of a silent EOF;
  interleaved argument deltas of parallel Responses calls are buffered so no
  call's JSON truncates.

Verified live over gpt-4o-mini, gpt-5-mini, gpt-5.5, gpt-6-sol, gpt-6-luna,
codex-auto-review, gemini-3.7-flash, gemini-3.8-flash and gemini-3.1-pro-preview
(plain, stream, tool call, tool_result follow-up, parallel tools: 48/49, the
miss being a preview model that emitted no tool call and passed on rerun), and
with the real Claude Code client (`-p`, Read tool) on gpt-5.5 and
gemini-3.7-flash. `tests/claude-enmaas-proxy.zsh` runs the offline-gateway
scenarios against both impls and asserts each model reaches the gateway on its
own dialect's endpoint.

Known limits: reasoning/thinking blocks are dropped in both directions; a tool
call whose name arrives in a later stream chunk than its id starts with an empty
name; a signature that arrives in a later chunk than the tool call's id cannot
be added to an already-emitted `tool_use` block.

## Block-diffusion and other vLLM-hosted fast models

Source: the vLLM recipe for `google/diffusiongemma-26B-A4B-it` (read 2026-11-07;
the model was not yet on the gateway). It is a Gemma 4 MoE (26B total, 4B active)
that generates **256-token blocks by iterative denoising** instead of one token
at a time: ~10x the time to first token, 1.9x the output tokens per second.
vLLM serves it on the standard OpenAI chat endpoint, so the proxy sees an
ordinary `openai`-dialect deployment (the `rits/` prefix marks self-hosted vLLM).
Claude Code reaches it through the existing Messages -> chat translation.

What the wire looks like, and what the proxy does about it:

- **Whole-block chunks.** A stream chunk can carry answer text, every complete
  tool call and `finish_reason` together. The translator handles that (tested:
  `TestChatStreamBlockDeliveredChunks`, `TestChatStreamSingleChunkAnswer`).
- **Reasoning.** `--reasoning-parser gemma4` puts thinking in
  `reasoning_content` (older vLLM) or `reasoning` (newer). It is not forwarded:
  a Messages thinking block needs a signature the upstream cannot supply. A
  reasoning-bearing chunk now emits a Messages `ping`, so a long denoising-only
  stretch does not look like a stalled stream.
- **Thinking switch.** Claude Code's `thinking` becomes
  `chat_template_kwargs.enable_thinking` (true for `enabled`/`adaptive`, false for
  `disabled`; `budget_tokens` has no vLLM equivalent). Only `rits/` ids get it: a
  hosted OpenAI-compatible API may reject the field. The recipe says tool calls
  work best in thinking mode, so this is what makes Claude Code's tool use
  dependable on these models.
- **`max_tokens`.** `rits/` ids already keep the classic `max_tokens`. The
  checkpoint's `generation_config.json` caps a request that omits it at 256 unless
  the server runs `--generation-config vllm`; Messages requests always carry
  `max_tokens`, so the proxy is unaffected, but anything else pointed at the
  same server is not.

To put a model like this behind the proxy, add its id to the EnMaaS route table
with the `openai` dialect (`CLAUDE_ENMAAS_MODEL_DIALECTS` overrides the guess) and,
to make it the cheap fast tier, point an alias at it. Gateway-side flags the
recipe requires, for whoever runs it: `--max-num-seqs 4` (diffusion state is
`seqs x 256 x 262K-vocab`, higher OOMs), `--generation-config vllm`,
`--reasoning-parser gemma4 --tool-call-parser gemma4`, `--limit-mm-per-prompt`
`'{"image": 7}'`.

Not done, because the model is not online and the right numbers are not known yet:

- **Per-model context window.** `clampOutput` prices every clamped model against
  one `MaxModelLen` and only covers the two hosted models and aliases. The recipe
  serves 262144, but the gateway's actual limit decides it.
- **Image count limit.** The image budget is bytes. A server started with
  `--limit-mm-per-prompt '{"image": 7}'` answers 400 beyond seven images, however
  small.
- **Concurrency.** `--max-num-seqs 4` queues the fifth request server-side;
  many Claude Code threads on one such model will see latency, not errors.
  A per-model in-flight limit in the proxy would shape that, but needs a measured
  queue behaviour first.
- **Streamed reasoning as thinking blocks**, for the signature reason above.

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
