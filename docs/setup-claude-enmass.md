# Claude Code through EnMaaS

`claude-enmass` uses the gateway credentials already exported in your shell:

```zsh
export ENMASS_API_BASE_URL='https://REDACTED'
# Set ENMASS_API_KEY through your existing secret/environment setup.
claude-enmass
claude-enmass --model claude-opus-5-5
claude-enmass --model rits/zai-org/glm-5-3
```

The `ENMASS` variable spelling and `claude-enmass` command are intentional. The service itself is named EnMaaS. A base URL ending in `/v1` is also accepted.

## Model discovery and API dialects

The gateway catalog is credential-dependent and can be incomplete. The wrapper combines the Anthropic (`x-api-key`) and gateway Bearer catalogs with the OpenAI upstream catalog reached through the same gateway/key, selects the newest available Claude model per tier, and adds available models to `/model`. Picker ordering favors the newest Claude generation and available GPT alternatives before older Claude models; moving a tier in the list does not change its mapping or Auto Mode. GPT availability and pricing depend on the gateway—sorting cannot enable an unsupported model. Sonnet is the default when discovered; unavailable tiers fall back to the selected default. Set `CLAUDE_ENMASS_MODEL` to override the default, or `CLAUDE_ENMASS_{OPUS,SONNET,HAIKU,FABLE}_MODEL` to override a tier:

```zsh
CLAUDE_ENMASS_OPUS_MODEL='claude-opus-5-5' claude-enmass
CLAUDE_ENMASS_MODEL='rits/zai-org/glm-5-3' claude-enmass
```

### GPT discovery during the gateway beta

The gateway's exact `/v1/models` route currently returns its Vertex inventory and omits GPT even though the OpenAI backend is routed. The wrapper additionally requests `/v1/responses/../models` with Bearer authentication and curl's `--path-as-is`: the gateway's Responses passthrough forwards this raw path, and OpenAI resolves it to its model catalog. This same-origin, read-only workaround was verified with the configured EnMaaS key; no OpenAI key, inference request, or cross-origin redirect is involved. Discovered GPT/reasoning text models use the Responses dialect. Audio/image/realtime/embedding models and dated snapshots are excluded.

Catalog requests retry transient HTTP failures twice. If the passthrough catalog becomes unavailable, the wrapper warns that GPT models may be omitted rather than claiming they are unsupported, and other catalogs still work. The workaround depends on the beta gateway's routing; an official complete discovery endpoint should replace it when provided. Models returned by the upstream catalog are selectable candidates, not proof that every inference capability is enabled.

Model switching needs to change the request dialect, not just the upstream model name. One standard shared LiteLLM proxy translates requests using its per-model routing configuration:

- Anthropic-compatible models → gateway `/v1/messages`, with `x-api-key` and `anthropic-version`.
- OpenAI Chat Completions models → gateway `/v1/chat/completions`, with Bearer authentication.
- Models configured for OpenAI Responses → gateway `/v1/responses`, with Bearer authentication.

For supported models omitted from discovery, or models requiring a particular dialect, declare exact IDs explicitly:

```zsh
CLAUDE_ENMASS_MODEL_DIALECTS='my-model=responses other-model=chat' \
    claude-enmass --model my-model
```

Valid dialects are `anthropic`, `chat`, and `responses`. Confirm gateway support before pinning an unlisted model. A catalog entry is not a guarantee that every upstream provider model is enabled. If discovery is unavailable or empty, set `CLAUDE_ENMASS_MODEL` or pass an exact `--model` ID to continue.

The supplied EnMaaS onboarding guide documents `rits/zai-org/glm-5-3`, so it is available as a pinned picker option even when absent from discovery. Its Claude Code effort setting is `medium`. GLM is text-only, with a documented 262,144-token context window and 65,536-token maximum output; those limits do not apply to other models.

## Coexistence

Launching `claude-enmass` does not change your saved `claude-mode`, calling-shell environment, or persistent Claude settings. Other `claude-*` wrappers and already-running sessions can continue independently. A caller's final `--settings` JSON object or file is merged into the session settings; EnMaaS transport fields, picker options and GLM-specific effort take precedence.

Sessions share one standard LiteLLM proxy at **`http://127.0.0.1:4146`**, using the same `ENMASS_API_BASE_URL`, gateway key and per-model dialect map. The first launch starts it; later launches reuse its PID and local authentication token. Session exit does not stop it. There is no tenant registry, registration server or lease connection.

Private runtime files live in `/tmp/claude-enmass-proxy-<uid>-<port>` (directory 0700, files 0600). Config contains `os.environ/ENMASS_API_KEY`, not the literal upstream key. The proxy inherits that key at startup; Claude children receive only the local proxy token. Different selected models/tier aliases do not rewrite or restart the service. Gateway/key, dependency or required dialect changes fail with an explicit stop/relaunch instruction. New catalog entries needing unloaded routes are omitted from the picker until restart; undiscovered Chat IDs can use the configured wildcard.

Startup is serialized with a per-port file lock. Reuse checks recorded PID birth time/process group, listener ownership and authenticated model readiness. An unrelated occupied port fails explicitly—there is no random-port fallback or adoption. A crashed proxy can be restarted, but its previous local token is invalid and existing sessions must be relaunched. To use another fixed port and later stop that proxy:

```zsh
CLAUDE_ENMASS_PROXY_PORT=4246 claude-enmass
CLAUDE_ENMASS_PROXY_PORT=4246 kill-enmass-api
# Stop the default proxy deliberately (disconnects all active sessions):
kill-enmass-api
```

`kill-enmass-api` (also `claude-enmass-kill`) sends TERM only to the recorded, birth-time-verified proxy process group, with bounded KILL escalation if necessary; it never signals a process merely discovered by port. No automatic last-session shutdown or shared configuration rewrite occurs. Unix-user isolation is the boundary: same-user processes can access private runtime files. A port is an identification convention for UI badges, not authentication proof.

To deliberately make EnMaaS the default dispatcher target:

```zsh
claude-mode enmass
claude
# Restore whichever mode you used previously, for example:
claude-mode copilot
```

## Dependencies and reload

Uses `python3`, `curl`, `jq`, `uv`, `lsof`, and LiteLLM/FastAPI pinned to the repository's proxy versions. Homebrew dependencies are listed in `Brewfile`. No separate gateway service checkout or credentials are needed.

For an existing shell, load both the shared helpers and the new wrapper:

```zsh
source ~/git/dotfiles/zsh/aliases/claude-copilot.zsh
source ~/git/dotfiles/zsh/aliases/claude-enmass.zsh
```

New shells load both through `zsh/alias.zsh`.

## Offline regression checks

```zsh
zsh -n ~/git/dotfiles/zsh/aliases/claude-enmass.zsh
zsh ~/git/dotfiles/tests/claude-enmass.zsh
# Real proxy tests require the pinned uv packages to be cached first:
zsh ~/git/dotfiles/tests/claude-enmass-proxy.zsh
zsh ~/git/dotfiles/tests/claude-enmass-lifecycle.zsh
```

The regression checks use local fixtures, not the live gateway or real credentials. The real proxy test uses `UV_OFFLINE=1` and simultaneous Claude clients sharing the same standard proxy/key/token. It checks all three per-model dialects, authentication, Messages/Chat streaming, Chat tool translation, errors, caller-environment isolation and a remaining client after another session exits. The lifecycle fixture checks unrelated occupied-listener refusal, concurrent startup, unchanged configuration during reuse, explicit restart requirements, crash/restart, old-token rejection and verified stop on its own ephemeral port. Responses streaming is not covered. These checks do not establish live UI badge rendering or real gateway entitlement.
