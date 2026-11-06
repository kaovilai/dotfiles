# hosted-only Go proxy (opt-in)

`HOSTED_ONLY_PROXY_IMPL=go` swaps the `litellm[proxy]` process behind
`claude-hosted-only` / `codex-hosted-only` for a stdlib-only Go binary
(`scripts/hosted-only-go`, no dependencies). LiteLLM stays the default.

## Why

The hosted-only proxies are a local, single-upstream protocol shim, but each one
pays for a full AI gateway: measured on this repo's machines, `import litellm`
costs ~268 MB and `import litellm` + FastAPI/uvicorn ~377 MB before serving a
request, per flavor (Claude :4148, Codex :4147), inside a `uv tool` environment
that also has to resolve and start. The Go binary is ~10 MB, starts in
milliseconds, and needs no Python at run time.

## Enabling

```zsh
HOSTED_ONLY_PROXY_IMPL=go claude-hosted-only      # or codex-hosted-only
HOSTED_ONLY_PROXY_IMPL=go claude-hosted-only-restart
```

The knob is part of the proxy fingerprint, like a hook edit: an idle proxy is
restarted by the next launch; a proxy serving a request is reused with a notice
until `claude-hosted-only-restart` / `codex-hosted-only --stop-proxy`. Unset it
(or set `litellm`) to go back.

The first start builds the binary with `go build` into
`${XDG_STATE_HOME:-~/.local/state}/hosted-only-go/hosted-only-proxy`; the build
is skipped until a file under `scripts/hosted-only-go` changes. Ports, token,
state dirs, the fingerprint protocol, `claude-hosted-only-kill` and
`codex-hosted-only --stop-proxy` are unchanged.

## What the Go path implements

Behaviour is ported from `scripts/hosted_only_hooks.py` and verified by
`rewrite_test.go`, `limits_test.go` and `tests/hosted-only-go-proxy.zsh`:

- **Transport:** `/v1/messages` (Anthropic), `/v1/chat/completions`,
  `/v1/responses`, SSE streaming with per-chunk flush, `/health/liveliness`,
  `/v1/models`, `/v1/messages/count_tokens` (byte estimate, no tokenizer).
- **Auth:** the local token via `x-api-key` or `Authorization: Bearer`; the
  upstream key never reaches the client.
- **Request rewrites** for `rits/` models and GLM aliases: alias → GLM id,
  image-in-history → DeepSeek (`VISION_FALLBACK`), grammar strip on custom
  tools, hosted `web_search` removed plus the in-band note (`SEARCH_NUDGE`,
  `T3_WEB_SEARCH_DELEGATE`), `thinking: disabled` on Messages requests that send
  none, empty developer/system items dropped, `tool_reference` blocks dropped,
  `max_tokens` clamped to the window (`MAX_MODEL_LEN`, `OUTPUT_RESERVE`,
  `MIN_OUTPUT`, `BYTES_PER_TOKEN`) with the same compaction 400 at the edge.
- **Limit/outage rewrite** (`LIMIT_REWRITE`): 429/402, 503 `upstream rate
  limited` and JSON `error.code: rate_limited` are classified as limits; 408/
  502/504/524, 503 `no_db_connection` and 500 connection errors as outages.
  Reset comes from the ranked upstream header/body signals the hooks parse
  (`retry-after[-ms]`, `x-ratelimit-reset-*`, Anthropic resets,
  `x-usage-ratelimit-*`, IETF `RateLimit`, body `reset_at`/`retry_after*`),
  else the next-month estimate (`HOSTED_ONLY_QUOTA_MONTH_TZ`) or the per-minute
  default. Shapes match the hooks: Messages → 503 `[model] [429]: … (reset
  after Xm)` + `retry-after` and `x-should-retry: false` above
  `CLIENT_RETRY_MAX_SECONDS`; chat monthly → 402 `insufficient_quota` with no
  `retry-after`; chat/responses rate limit → 429 with `x-codex-primary-*`, and
  `error.resets_at` on Responses.
- **Model fallback:** one retry with the other hosted model for image-free
  requests on 408/429/5xx/transport errors (`FALLBACK`).
- **Usage:** the same `events-YYYY-MM.jsonl` schema (`llm-usage`) and the
  `inflight-<port>-<pid>.json` file, including token counts parsed from SSE.

## Known differences from the LiteLLM path

These are deliberate gaps in the first version; LiteLLM remains the default
until they are closed (or accepted):

- Inline image **pruning/caching** (`IMAGE_BUDGET_BYTES`,
  `IMAGE_CACHE_DAYS`): large image histories are sent as-is.
- Outage **streak persistence** across restarts (`HOSTED_ONLY_OUTAGE_STATE`):
  the Go path doubles 60 s → 600 s in memory only.
- **Drift diagnostics** (`unhandled_header`, `unhandled_body_field`,
  `shape_changed`, `estimate_mismatch` warnings) and the LiteLLM router
  `reuse:last-reset` path.
- The **DoH fallback** (`dns_fallback.py`, `HOSTED_ONLY_DNS_FALLBACK`) is only
  installed on the Python path; the Go binary uses the system resolver.
- `cost` is not computed (LiteLLM's `model_cost`); `llm-usage` tolerates it,
  and the menubar's cost view stays empty for Go-served requests.
- Only the three hosted routes: no embeddings, MCP, management API, budgets or
  virtual keys (hosted-only never used them).

## Tests

```zsh
cd scripts/hosted-only-go && go test ./...   # rewrites + limit parsing/rendering
zsh tests/hosted-only-go-proxy.zsh           # end-to-end against a stub upstream
```

The zsh test starts a local stub upstream (200 with usage, 429 with
`retry-after`, quota 429), runs the real binary, and asserts auth, alias
routing, pass-through, the 503/429/402 shapes and headers, the usage JSONL
fields, and that the stop helper finds the process by its runtime dir. It exits
0 with a `skip:` notice when `go` is not installed.
