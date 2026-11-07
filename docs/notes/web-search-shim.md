# Web search shim — detect the silent ignore, emulate hosted `web_search`

Design note. Status: designed 2026-11-06, not implemented. Tracking issue links here.

## Problem

On `rits/` models (GLM, DeepSeek) the EnMaaS/vLLM upstream accepts hosted web
search tools (`web_search`, `web_search_preview`, `web_search_20250305`) with
HTTP 200 and silently ignores them: no `server_tool_use` / `web_search_call`
item comes back, and the model answers from stale training data without knowing
it cannot search (evidence in `docs/notes/deepseek-v41-flash-vs-glm.md`). The
Anthropic server-tool shape 400s outright (`input_schema` required). GPT models
keep native hosted search and are never touched.

Current mitigation (#602 checklist item, landed in #611): both proxy impls
strip the tools (`strip_web_search_tools` in `scripts/hosted_only_hooks.py`,
`drop_web_search` in `scripts/enmaas_proxy_hooks.py`, `stripWebSearchTools` in
`scripts/hosted-only-go/rewrite.go`), the launchers register the free anonymous
Parallel MCP per session (`HOSTED_ONLY_SEARCH_MCP_URL` /
`ENMAAS_SEARCH_MCP_URL`), and an in-band `[web-search-unavailable]` note points
the model at `mcp__parallel__web_search` / `mcp__parallel__web_fetch`.

That covers clients that execute tools themselves (Claude Code + MCP). It does
not cover clients that only speak hosted server tools — Codex with its global
`web_search` setting (currently just disabled per-model via the generated
catalog, `supports_search_tool=false`) — or sessions where the MCP is not
registered. This note designs the upgrade path: detect the upstream behavior
instead of hardcoding it, and make hosted `web_search` actually work by having
the proxy execute it against the Parallel Search API.

## Part 1 — Detection

Per-request detection is impossible: "tool was offered, no call came back" is
indistinguishable from the model choosing not to search. Use a forced-choice
canary instead:

- Sent through the proxy itself (so it observes gateway + vLLM behavior, not
  just the model), with the hosted `web_search` tool present and
  `tool_choice: {"type": "tool", "name": "web_search"}` forced — the shape
  already exercised by `tests/hosted-only-proxy.zsh`.
- Verdicts:
  - response contains a search call item → **native** → passthrough, no strip;
  - 200 with no call item, or a 400 naming the tool → **ignored** → strip + shim;
  - anything else → **unknown** → fail closed to today's strip + note.
- Cache the verdict per (model, gateway) in the proxy state dir beside
  `config.json`; the restart fingerprint already invalidates on gateway change.
  TTL it so an EnMaaS-side vLLM upgrade re-probes — the strip auto-retires if
  real support ever ships.
- Scheduling: piggyback — hold the first real request that carries a
  web_search tool for a verdict-less model, run the canary, then forward the
  real request rewritten per verdict. One extra round trip once per model; no
  startup probe, no cron. Mark the canary (header or model tag) so
  `litellm_usage_log` filters it from `llm-usage`.
- `HOSTED_PREFIXES = ("rits/",)` stays as the prior / fail-closed default so
  the no-probe path needs no verdict.

## Part 2 — The shim

Proxy-side emulation of the hosted server tool. Hosted-tool-only clients get
real search; clients that speak the native protocol cannot tell the difference.

1. **Request side** (where the strip sits today): when the verdict is
   *ignored*, rewrite `{"type": "web_search..."}` tools into a regular
   function tool named `web_search` with a `{query, allowed_domains?,
   max_uses?}` schema. GLM/DeepSeek handle ordinary function calling fine; only
   the server-tool shape is dropped by vLLM.
2. **Response side** (new): when the upstream emits a `tool_use` for
   `web_search`, the proxy executes the search itself, maps results into the
   native block shape per dialect (Anthropic: `server_tool_use` +
   `web_search_tool_result` with titled chunks and citations; OpenAI Responses:
   `web_search_call` + results), appends the tool result, and re-invokes the
   upstream — looping up to `max_uses` (cap 5) per turn. The final round
   streams to the client; intermediate tool-call rounds are buffered (they are
   not client-visible anyway).
3. **Failure rule** (matches "a failure in here must never break a request"):
   Parallel call times out (~5 s) or errors → return an `is_error` tool result
   ("web search unavailable this turn") so the loop stays well-formed and the
   model knows; never 500 the turn.
4. **Secrets**: `PARALLEL_API_KEY` lives only in the proxy env next to
   `ENMAAS_API_KEY` (same rule: only the proxy holds upstream keys, clients
   get the local token).
5. **Impl order**: Go first — it owns the request path (#610) and can buffer
   intermediate rounds and stream the final one; the LiteLLM hook surface
   makes a response-side loop awkward, and LiteLLM is headed for retirement
   (#602). Knob: `HOSTED_ONLY_SEARCH_SHIM` (off by default until soaked),
   participating in the existing knob/fingerprint restart machinery.
6. **Note interaction**: while the shim is active, the in-band note must change
   text — "use the web_search tool" instead of "route to
   `mcp__parallel__web_search`" — or the model gets contradictory
   instructions. The MCP registration stays: harness-level `web_fetch` for
   known URLs is still useful and free.

## Part 3 — Parallel API configuration

The caller's model writes the answer from evidence, has no URLs yet, the
caller waits interactively, and volume is model-discretionary → **Search**.
Not Responses/Task (Parallel would write the answer, changing the agent's
contract); not Extract (no URLs in hand — a possible later `web_fetch`-style
tool would use Extract at $1/1k URLs).

- **Tier: `fast`, pinned explicitly** (~700 ms, $1/1k requests). Omitted
  `mode` on REST means `advanced` — a quiet 5×. Pinning requires
  authentication, so the shim needs `PARALLEL_API_KEY`; the anonymous free MCP
  tier rejects overrides and cannot be reused server-side.
- **Knobs**: `max_results` 8, `excerpt_settings.max_chars_per_result` 2000
  (≈ one native `web_search_tool_result`); `objective` = the model's `query`
  verbatim; `allowed_domains` → `source_policy.include_domains`; `max_uses` →
  loop cap. Read `errors` as well as `results`.

```http
POST /v1/search
Authorization: Bearer $PARALLEL_API_KEY
{
  "objective": "<model's web_search query, verbatim>",
  "search_queries": ["<query as keywords>"],
  "mode": "fast",
  "advanced_settings": {
    "max_results": 8,
    "excerpt_settings": {"max_chars_per_result": 2000}
  }
}
```

- **Arithmetic**: $0.001 + ~0.7 s per search; a search-heavy 3-call turn
  ≈ $0.003. Against the free anonymous MCP, the paid REST key buys exactly one
  thing: hosted-tool clients getting search at all.
- **Escalation**: on real-traffic misses, raise `max_results` /
  `max_chars_per_result` first (the usual cause), then measure `advanced`
  ($5/1k) on 10–20 real queries before adopting.

## Verification

- Canary: forced-choice probe returns *ignored* against a stub upstream that
  200s without a call item, *native* against one that emits it, *unknown* on
  garbage; verdict cached and re-read; fail-closed strip when no verdict.
- Shim: request rewrite turns `web_search_20250305` into the function tool and
  frees a forced `tool_choice` naming it; response loop maps Parallel results
  to both dialects' block shapes; loop capped at `max_uses`; Parallel timeout →
  `is_error` tool result and the turn still completes; shim off →
  byte-identical behavior to today.
- Live: one Claude (`/v1/messages`) and one Codex (`/v1/responses`) request
  through the Go proxy with the shim on, answer cites fetched URLs.
- Tests mirror the existing patterns in `tests/hosted-only-proxy.zsh`,
  `tests/hosted-only-go-proxy.zsh`, `tests/codex-enmaas.zsh`.

## Out of scope

- Extract-backed `web_fetch` tool (phase 2).
- Any change to GPT models' native web search.
- Harness-level changes beyond the note-text switch (the
  `nudge-web-search-via-luna.sh` policy stays).
