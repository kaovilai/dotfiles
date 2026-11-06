# Hosted-only context edge: why we clamp, and how close to native we can get

Date 2026-11-06, after `ab9c535` (clamp + compaction hint in
`scripts/hosted_only_hooks.py`). Companion to the COUPLED SETTINGS comment block
above `MIN_OUTPUT` there; that block says *what* is coupled, this note says
*why the seam exists* and what closing it further would cost.

## The rule is upstream, not a vLLM bug

vLLM rejects `input_tokens + max_tokens > max_model_len` at admission — before
any generation, so nothing is metered/billed. OpenAI's API enforces the same
rule with a near-identical error ("This model's maximum context length is X
tokens. However, you requested Y tokens (Z in the messages, W in the
completion)"). Anthropic's native "prompt is too long: X tokens > Y maximum"
is the same shape, and is the wording our hint 400 mirrors. Relaxing it
server-side has years-old vLLM feature requests; not adopted.

## Why native Claude Code never hits the edge

1. The server reports exact `usage.input_tokens` every turn, so the client's
   context estimate recalibrates on real numbers and auto-compact fires
   reliably, with margin (~92% of window, not the edge).
2. Output caps are small relative to the window (32k vs 200k).
3. The same tokenizer counts both sides — no drift.

## Why our path hit it

1. Client token heuristic drifts from vLLM's tokenizer over ~1M of tool
   results — overran its own compact threshold (1,048,750 vs 1,048,576).
2. We advertise the full 1M window, so the client lets input grow to the edge.
3. We raised the output cap to 128000 (`CLAUDE_CODE_MAX_OUTPUT_TOKENS`);
   the client's edge math reserves nothing for it.

The clamp + hint (`clamp_output`, `HOSTED_ONLY_MIN_OUTPUT`) is the native edge
behavior replicated proxy-side: trim `max_tokens` to the room left, and below
`MIN_OUTPUT` answer the "prompt is too long" 400 so the client compacts and
retries. Post-failure we are native-shaped.

## Getting closer to native — two levers, and their cost

**Lever 1 — exact usage passthrough (real native behavior).** vLLM returns
exact `prompt_tokens`; LiteLLM maps it to Anthropic `usage.input_tokens`. If
that reaches Claude Code through our anthropic-dialect bridge, drift shrinks
to one turn of growth. UNVERIFIED: log one live session's usage field to
confirm it flows. Cannot fully close the gap either way — the compaction check
happens between turns, so one huge tool result can still jump the edge within
a turn (native has the same race; 200k windows + 32k caps just make it rare).

**Lever 2 — advertise a smaller window.** Catalog 960k instead of 1M (the
Codex flavor already does 1,000,000 vs real 1,048,576 in
`scripts/codex-provider.zsh`). Client compacts at its own fraction of the
advertised number, so real headroom appears. Cheap and robust, but costs ~90k
usable context and more frequent compaction (more detail lost per session).

## Verdict recorded 2026-11-06

- Lever 1: pure win if missing, verify first. Not yet verified.
- Lever 2: only if hint-400s recur often — each mid-task 400 costs a round
  trip plus possible lost work. One occurrence in weeks means the clamp
  backstop is enough and 90k of real context is worth more than the avoided
  retry.
- Full native fidelity is unreachable: Claude Code's internal pre-send
  heuristic is not ours to change — only what we advertise (lever 2) and what
  usage we report (lever 1) are. Levers + clamp ≈ 90% of native safety;
  the clamp keeps the last 10%.
