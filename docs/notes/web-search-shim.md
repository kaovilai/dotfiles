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

Current mitigation (#602 checklist item, landed in #611): the Go proxy — the
only impl since the LiteLLM retirement (#617) — strips the tools
(`stripWebSearchTools`, `scripts/hosted-only-go/rewrite.go`), the launchers register the free anonymous
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

- Sent through the proxy process (so it observes gateway + vLLM behavior, not
  just the model) with the hosted `web_search` tool present and a forced
  choice — `{"type": "tool", "name": "web_search"}` on the Anthropic dialect,
  the type-only `{"type": "web_search_preview"}` on Responses — but **marked
  and exempted from the proxy's own strip/rewrite/note and fallback paths**,
  otherwise the canary measures our rewrite, not the upstream. (The forced
  choice survives to the upstream because the canary bypasses the strip; the
  ordinary path frees it, which is exactly why the canary cannot ride along.)
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
  startup probe, no cron. Mark the canary (header or model tag) so the usage
  log (`scripts/hosted-only-go/usage.go`, the events JSONL behind `llm-usage`)
  filters it out.
- `cfg.isRits` (`scripts/hosted-only-go/config.go`) stays as the prior /
  fail-closed default so the no-probe path needs no verdict.

## Part 2 — The shim

Proxy-side emulation of the hosted server tool. Hosted-tool-only clients get
real search; clients that speak the native protocol cannot tell the difference.

1. **Request side** (where the strip sits today): when the verdict is
   *ignored*, rewrite `{"type": "web_search..."}` tools into a regular
   function tool named `web_search` exposing **only `{query}`**. GLM/DeepSeek
   handle ordinary function calling fine; only the server-tool shape is
   dropped by vLLM. `allowed_domains` and `max_uses` are caller-set fields on
   the hosted tool definition, not model arguments — the proxy reads them off
   the original tool at rewrite time and enforces them itself
   (`allowed_domains` → Parallel `source_policy.include_domains`,
   `max_uses` → the loop cap). A forced `tool_choice` naming `web_search` is
   **preserved**, not freed: the rewritten tool keeps the name, so a caller's
   explicit requirement to search survives the rewrite. (Freeing the choice
   stays correct only for the pure strip path, where the named tool no longer
   exists.) If the request already declares a non-hosted tool named
   `web_search`, the shim declines for that request (strip + note instead)
   rather than shadowing the client's tool.
2. **Response side** (new): when the upstream emits a `tool_use` for
   `web_search`, the proxy executes the search itself, maps results into the
   native block shape per dialect (Anthropic: `server_tool_use` +
   `web_search_tool_result` with titled chunks and citations; OpenAI Responses:
   `web_search_call` + results), appends the tool result, and re-invokes the
   upstream — looping up to `max_uses` (cap 5) per turn. Loop and streaming
   policy:
   - **Mixed tool calls terminate the loop.** A round whose `tool_use` list is
     exclusively `web_search` calls is consumed server-side. A round that
     also emits any other `tool_use` (a client function) is returned to the
     client as-is so it can execute its tools, and the conversation resumes
     when the client supplies the results — the proxy never hides a client
     tool call or continues without its result.
   - **Buffering.** While the shim tool is in the request, every round is
     buffered: a `web_search` call can follow already-emitted text, and the
     wire protocols allow only one response per request. The terminal round —
     the one with no `web_search` call — is replayed to the client over SSE
     with the accumulated search records prepended, so clients inspecting
     search activity see the full native trail (`server_tool_use` /
     `web_search_tool_result` / `web_search_call` records) before the final
     answer. Requests without the shim tool stream through untouched; the
     cost is that search-capable requests lose live token streaming (the
     final response arrives after generation completes).
   - **Forced choice is enforced, not just preserved.** When the caller
     forced `web_search`, a first round that returns no call is not accepted
     as final: the proxy re-issues it once with the forced choice intact,
     then degrades to strip + note rather than letting the model answer
     without searching.
3. **Failure rule** (matches "a failure in here must never break a request"):
   Parallel call times out (~5 s) or errors → return an `is_error` tool result
   ("web search unavailable this turn") so the loop stays well-formed and the
   model knows; never 500 the turn.
4. **Secrets**: `PARALLEL_API_KEY` lives only in the proxy env next to
   `ENMAAS_API_KEY` (same rule: only the proxy holds upstream keys, clients
   get the local token).
5. **Impl**: Go-only — it has been the only impl since the LiteLLM retirement
   (#617) and already owns the full request path (#610), so it can buffer
   intermediate rounds and stream the final one. Knob:
   `HOSTED_ONLY_SEARCH_SHIM` (off by default until soaked), participating in
   the existing knob/fingerprint restart machinery.
6. **Codex catalog and launcher**: `scripts/codex-provider.zsh` currently pins
   `supports_search_tool=false` + `tool_mode: direct` for these models
   (lines ~129/~228), and the launcher sets `web_search="disabled"`. With the
   shim on, both must flip for shim-enabled models so Codex offers its global
   `web_search` and the proxy serves it — otherwise Codex never sends the
   tool and the shim is dead code on that path.
7. **Note interaction**: while the shim is active, the in-band note must change
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
  garbage; verdict cached and re-read; fail-closed strip when no verdict; the
  canary provably bypasses the strip/rewrite (a stub upstream still receives
  the hosted tool shape and the forced choice).
- Shim: request rewrite turns `web_search_20250305` into the function tool,
  keeps a forced `tool_choice` naming it, and carries `allowed_domains` /
  `max_uses` from the original tool definition into the proxy's own
  enforcement; response loop maps Parallel results
  to both dialects' block shapes; loop capped at `max_uses`; Parallel timeout →
  `is_error` tool result and the turn still completes; shim off →
  byte-identical behavior to today.
- Loop edges: a round mixing `web_search` with a client `tool_use` is returned
  to the client, never consumed server-side; a forced-choice first round with
  no call is re-issued once then degrades to strip + note; the terminal
  response carries the accumulated native search records; a request that
  already declares its own `web_search` tool skips the shim.
- Live: one Claude (`/v1/messages`) and one Codex (`/v1/responses`) request
  through the Go proxy with the shim on, answer cites fetched URLs.
- Tests mirror the existing patterns in `tests/hosted-only-proxy.zsh`,
  `tests/hosted-only-go-proxy.zsh`, `tests/codex-enmaas.zsh`.

## Out of scope

- Extract-backed `web_fetch` tool (phase 2).
- Any change to GPT models' native web search.
- Harness-level changes beyond the note-text switch and the Codex catalog
  flip (the `nudge-web-search-via-luna.sh` policy stays).
