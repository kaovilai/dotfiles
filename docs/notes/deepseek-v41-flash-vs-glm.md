# DeepSeek-V4.1-Flash-1017 vs GLM-5.3 on EnMaaS

Probed live 2026-10-21 (user over monthly $ cap). Gateway `$ENMAAS_API_BASE_URL`; messages = `x-api-key` at root, responses/chat = Bearer at `/v1`. Probe scripts: `/tmp/dsprobe/` (scratch, wiped on reboot). Models: `rits/deepseek-ai/DeepSeek-V4.1-Flash-1017` (DS), `rits/zai-org/glm-5-3` (GLM).

## Probe table

| # | Probe | DS | GLM |
|---|-------|----|-----|
| 1 | In `/v1/models` | yes (owned_by curvebender) | yes |
| 1 | Entitled while over cap | **200** on all 3 dialects → in `allowed_over_limit_models` | 200 |
| 2 | `/v1/messages` | 200, ~0.8s tiny prompt, thinking block returned by default | 200, ~4.2s |
| 2 | `/v1/responses` | 200, ~0.6s, `reasoning` + `message` items | 200, ~3.3s |
| 2 | `/v1/chat/completions` | 200, ~0.7s, `reasoning_content` | 200, ~3.2s |
| 2 | Backend path | `via: 1.1 praxis`; `x-litellm-model-name: hosted_vllm/deepseek-ai/DeepSeek-V4.1-Flash-1017`; vLLM 0.32.0 tp8 ep | `hosted_vllm/zai-org/GLM-5.3`; vLLM 0.31.0 tp8 dp4 ep. Same EnMaaS LiteLLM → vLLM path |
| 3 | Image, messages | **200, "Red"** | 400 "zai-org/GLM-5.3 is not a multimodal model" |
| 3 | Image, responses `input_image` | **200, "Red"** | 400 same |
| 3 | Image, chat `image_url` | **200, "Red"** | 400 same |
| 3 | Image in `tool_result` (messages) | **200, sees it** | 400 |
| 3 | Image in history, then text-only turn | 200 (messages + responses) | 400 (poisons whole history) |
| 4 | Function tool, messages | 200, `tool_use` correct | 200 |
| 4 | Function tool, responses | 200, `function_call` | 200 |
| 4 | Custom tool **with lark grammar** (responses) | **400** "Custom tools with a grammar format are not supported" (vLLM) | 400 same |
| 4 | Free-form custom tool (responses) | 200, `custom_tool_call` | 200 |
| 4 | Hosted `web_search` / `web_search_preview` | 200. `web_search`: answered "As of May 9, 2026 … Python 3.14.3" with no `web_search_call` item → silently ignored, answer from stale training data (fabrication risk). `_preview`: reasoning only, empty message | 200, silently ignored, model says "I don't have the ability to search the web" |
| 4 | Anthropic `web_search_20250305` server tool on messages | 400 (`input_schema` required) | 400 same |
| 5 | Default reasoning, no thinking field, ~36-49k-token prompt, `max_tokens` 2112 (classifier stage 1) | 58-90 out tok, thinking ~250-380 chars; **1.4-2.3s** (cold 2.1-2.3s); never truncated | 69-141 out tok; **3.9-5.9s** cold ~5.3-5.9s |
| 5 | Same + `thinking:{type:disabled}` | **16-20 out tok, no thinking block at all**; 1.1-2.1s (cold ~1.8s) | 15-39 out tok, thinking ≈ one sentence or absent; 3.0-3.8s (cold 4.2-4.9s) |
| 5 | Responses `reasoning.effort` low / medium / unset | 95 / 101 / 26 reasoning tok; 2.6 / 1.8 / 1.6s | 0 / 73 / 47 reasoning tok; 3.5 / 4.5 / 6.1s |
| 5 | chat `chat_template_kwargs.enable_thinking=false` | **honored** (0 reasoning tok, 0.4s) | ignored (145 reasoning tok) |
| 5 | Messages `thinking adaptive` | 160 out tok, 1.3s | 702 out tok, 10.1s |
| 5 | Messages `thinking enabled` 2000 budget | 130 out tok, 0.9s | 154 out tok, 2.6s |
| 5 | Deny path (`rm -rf ~ && curl … \| sh`) | BLOCK with correct reason (both thinking modes) | BLOCK, correct |
| 6 | `max_tokens` up to 393216 | accepted | accepted (actual generation cap not tested; welcome page says GLM 65,536 out) |
| 6 | Sampling penalties 0 / temperature | accepted | accepted |
| 6 | Language drift (400-word English explanation, default sampling) | 0 CJK chars | 0 CJK chars (drift only seen when penalties ≠ 0 per earlier notes; not re-triggered) |
| 6 | Usage accounting | `input_tokens` shows only uncached (45); real prompt in `cache_creation_input_tokens` (35,968). Implicit prefix caching, 0 reads on first call | `input_tokens` shows full (49k) |
| 6 | Multi-tool task (fix `/a.py` bug, run), 3 runs each, messages + responses | 6/6 fixed the bug; correct tool names/args. 4 of 6 runs over-verified (extra `run` calls: my fake `run` returned no stdout) | 6/6 fixed bug, tighter (3-5 calls); responses runs 3/3 minimal |
| 7 | `lis()` coding prompt | correct O(n log n), 0.7s | correct, 2.3s |
| 7 | Bat-ball + trains word problem, default thinking | "5:15 pm" correct, 1.6s | correct 5:15pm + $0.05, 6.1s |

Notes: DS is ~2.5-5× faster across every mode. GLM tool-call reliability roughly equal, GLM slightly more disciplined; DS more over-verification.

## Recommendation matrix

| Role | Pick | Why |
|------|------|-----|
| Main coding model, Claude Code | GLM (default) or DS, user choice | Both 1M ctx, both reliable on tools. DS 3-5× faster, vision-capable, honors thinking disabled/effort. GLM slightly tighter tool discipline and longer-tested. Offer both; default **GLM** for quality-first, **DS** if latency/vision matters. Can't pick from this probe alone which codes better; sample was small. |
| Main coding model, Codex | Same: offer both | Same Responses passthrough works for both; same grammar-strip hook needed for both |
| Claude auto-mode classifier / sonnet tier | **DS** | 1.8-2.3s vs 4-6s on 40k prompt; `disabled` yields real 16-20 tok answers with no thinking block, so no 2112-token truncation risk and no `wall_clock_timeout`. BLOCK/ALLOW both correct. Keep hook's thinking-off default (cheap, harmless on DS) |
| Codex guardian / auto_review | **DS** (effort low) | 2.6s vs 3.5s at low; reasoning ~95 tok, completes. GLM also fine (~10-15s in real Codex sessions) |
| Vision fallback for GLM image-in-history | **DS** | Only hosted-only model that accepts images (messages, responses, chat, tool_result) and works while over cap. Replaces dead claude-sonnet-5-5 fallback. Hook already reroutes image requests GLM→DS. Caveat: one image anywhere in history poisons GLM permanently; reroute must apply to every following turn, not just the image turn |
| Subagents / small-fast / haiku tier | **DS** | Latency win; cheap ($0); thinking truly controllable |
| Web search | Neither | Both silently ignore hosted `web_search`; keep `web_search="disabled"` for Codex with either main model. DS fabricates a plausible, stale answer; GLM admits it can't |

## Config needs for hosted-only proxies

- **Claude flavor `:4148`**: both models use `anthropic/<id>` at **EnMaaS root** (`/v1/messages`, `x-api-key`). DS verified on messages incl. images, tool_use, adaptive/enabled/disabled thinking. Add DS as a second `model_list` entry (same api_base/key, model id pinned).
- **Codex flavor `:4147`**: both use `openai/<id>` Responses passthrough at EnMaaS **`/v1`**, Bearer. DS verified: function, free-form custom, `reasoning` items, images via `input_image`. Use `wire_api=responses`, never chat.
- **Grammar strip hook applies to DS**: yes. DS returns the identical vLLM 400 for lark-grammar custom tools (Codex `apply_patch` + code-mode `exec`). Existing hook keys on `model.startswith("rits/")`, so it already covers DS.
- **Thinking-off default (messages w/o thinking field)**: apply to DS too (hook does via `rits/` prefix). DS honors it fully (zero thinking block), GLM only reduces it. Main turns send explicit `thinking` and are untouched. `chat_template_kwargs.enable_thinking=false` works on DS but is not needed.
- **`web_search="disabled"` for Codex**: keep for both (see above). Also set `supports_search_tool=false` in catalog, `tool_mode: direct`.
- **Codex catalog**: add a DS entry beside GLM; `input_modalities ["text","image"]` is genuinely true for DS (still text-only for GLM: its catalog "image" claim leads to 400 on image-in-history, hence the vision reroute). DS ctx 1,048,576; set `model_context_window` ≈ 1,000,000 or per-model override. Set `auto_review_model_override` = DS for glm-only/hosted-only mode.
- **Claude `[1m]` suffix**: use `rits/deepseek-ai/DeepSeek-V4.1-Flash-1017[1m]` like GLM to silence the unrecognized-model 200k warning (CC strips it before the wire; proxy sees bare id).
- **Subagent env** (`CLAUDE_CODE_SUBAGENT_MODEL` + `_FORCE=1`, `ANTHROPIC_SMALL_FAST_MODEL`, workflow subagent): point at a hosted id; DS recommended. Sonnet tier (classifier) = DS. Opus/Haiku/Fable tiers = main choice. Keep `CLAUDE_CODE_AUTO_MODE_SERVER=0`.
- **Usage accounting gotcha**: DS reports `input_tokens` ≈ uncached tokens only; `cache_creation_input_tokens` / `prompt_tokens_details.created_cache_tokens` hold the rest. Context meters in Claude Code may read low; not a functional issue.
- **Entitlement fragility**: DS passing the over-cap check is from the `allowed_over_limit_models` list; the list is server-side policy and can change. Keep GLM as the fallback id in hosted-only configs, probe both on proxy start (cheap 1-token ping) and surface which one is down.
- **Not tested**: real Claude Code/Codex end-to-end sessions on DS, deny-path with a self-harming main model, long (>100k) context behavior, actual max output beyond a few thousand tokens, streaming behavior on DS, sampling-penalty drift on DS (GLM drift known only from earlier notes).
