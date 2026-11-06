# Go proxy for the LiteLLM launchers (opt-in)

`LLM_PROXY_IMPL=go` (or per launcher: `HOSTED_ONLY_PROXY_IMPL=go`,
`CLAUDE_ENMAAS_PROXY_IMPL=go`) swaps each `litellm[proxy]` process for the
stdlib-only Go binary in `scripts/hosted-only-go`. LiteLLM stays the default.

It serves all three current flavors from one binary:

| flavor | port | config source |
|---|---|---|
| `enmaas` | 4146 | the launcher's generated `config.json`, read as a route table |
| `codex` (hosted-only) | 4147 | `HOSTED_ONLY_*` env knobs |
| `claude` (hosted-only) | 4148 | `HOSTED_ONLY_*` env knobs |

## Why

The proxies are local, single-upstream protocol shims, but each one paid for a
full AI gateway: measured on this repo's machines, `import litellm` costs
~268 MB and `import litellm` + FastAPI/uvicorn ~377 MB before serving a
request, per flavor, inside a `uv tool` environment. Three proxies (enmaas +
Claude + Codex) meant ~900 MB and three slow cold starts. The Go binary is
~10 MB and starts in milliseconds.

## Enabling

```zsh
LLM_PROXY_IMPL=go claude-hosted-only          # one launcher
LLM_PROXY_IMPL=go claude-enmaas               # shared proxy on :4146
export LLM_PROXY_IMPL=go                      # every launcher in this shell
```

The knob is part of the proxy fingerprint, like a hook edit: an idle proxy is
restarted by the next launch; one serving a request is reused with a notice
until `claude-hosted-only-restart` / `claude-enmaas-restart` /
`codex-hosted-only --stop-proxy`. Unset it to return to LiteLLM.

The first start builds the binary into
`${XDG_STATE_HOME:-~/.local/state}/hosted-only-go/`, rebuilding when a module
source changes. Ports, tokens, state dirs, the fingerprint protocol and the stop
commands are unchanged.

## Why the ports stay

Ports are load-bearing even with one binary:

- **Policy boundary.** :4146 serves the whole discovered EnMaaS catalog; :4147/
  :4148 serve only GLM, DeepSeek and the Claude alias. That allowlist is the
  hosted-only cost guard — one port for everything would make it token-only.
- **Client configuration.** Each launcher points Claude Code at
  `ANTHROPIC_BASE_URL` and Codex at its provider `base_url`; the port *is* the
  mode selector.
- **Usage attribution.** `llm-usage`, the menubar and
  `inflight-<port>-<pid>.json` key providers by port (`PROVIDER_PORTS`).

The **process count** is not a boundary: the same binary serves any flavor on
its own port, and one build can run per flavor. Collapsing to one multi-listener
process would change lifecycle semantics (per-flavor stop/restart, the "never
restart under a live session" rule) for a few MB; it is not done here.

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

- Inline image **pruning/caching** (`IMAGE_BUDGET_BYTES`,
  `IMAGE_CACHE_DAYS`) is not ported.
- Outage **streak persistence** across restarts (`HOSTED_ONLY_OUTAGE_STATE`):
  the Go path backs off in memory only.
- **Drift diagnostics** and the LiteLLM router `reuse:last-reset` path.
- `cost` is not computed (LiteLLM's `model_cost`); `llm-usage` tolerates it.
- The **DoH fallback** (`dns_fallback.py`) is Python-only; the Go binary uses
  the system resolver.
- LiteLLM's chat↔Responses bridge: a chat request for a Responses-only id is
  answered by the deployment's native endpoint, not translated.

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
the wildcard route, and `additional_tools` flattening. It exits 0 with a
`skip:` notice when `go` is not installed.
