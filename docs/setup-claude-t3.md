# Claude backends in T3 Code

A **launcher** is the executable entry point T3 runs instead of a shell function. For example, `~/.local/bin/claude-t3-vertex` loads your credentials, prepares or reuses the Vertex proxy, and then starts the real Claude CLI with T3's arguments and input.

## Startup order and shared proxies

1. Make the chosen backend's credentials available: Copilot gateway authorization, Vertex ADC and project/region, or the OpenAI/EnMaaS key configuration described below.
2. Run `claude-t3-<backend> --prepare` and wait for it to complete. Only the backend you intend to use needs preparation.
3. Open T3, select the corresponding **Claude · Backend** instance, and choose an **Auto** tier model. Start a new thread for each backend; switching backends within a conversation has not been tested.

T3 may be opened first: launchers prepare services automatically. Prewarming avoids spending T3's startup timeout on cold service startup and catalog discovery. Credentials are sourced on every normal invocation, so a changed credential file is read on the next launch. A running proxy may still require a restart to adopt changed upstream credentials.

Existing `claude-copilot`, `claude-vertex`, `claude-openai`, and `claude-enmass` shell functions remain usable alongside T3. They share the local proxies with these launchers. Interactive Copilot/Vertex/OpenAI wrappers retain their automatic restart behavior on a changed configuration fingerprint; that restart can interrupt active T3 sessions. The T3 launchers refuse a conflicting fingerprint and request an explicit restart. EnMaaS uses its existing explicit restart policy. Finish active sessions before changing and restarting a shared proxy.

The `claude-t3-*` names are separate from the shell functions and select a fixed backend independently of `claude-mode`. They invoke the native Claude executable directly, bypassing interactive aliases. Launcher locks coordinate T3 preparations only; ordinary shell calls do not participate. Claude configuration, skills, and history still follow the configured Claude home directory.

Installed named instances: **Claude · Copilot**, **Claude · Vertex**, **Claude · OpenAI**, and **Claude · EnMaaS**. In T3's model picker, select the instance and **Auto Sonnet tier** to use that wrapper's current default mapping. Auto Opus/Haiku/Fable tiers are also available where the wrapper supplies them. EnMaaS has no Fable picker entry and additionally has an exact GLM 5.3 entry.

The tier names are wrapper roles: OpenAI's Sonnet/Opus tier currently maps to GPT-6.1 Sol, Haiku to GPT-6 Luna, and Fable to GPT-6 Astra. They are not Claude models on the OpenAI backend. Tier choices use the stable internal IDs `t3-sonnet`, `t3-opus`, `t3-haiku`, and `t3-fable`; the bridge resolves them before the real Claude executable starts. These IDs are only supported through these launchers. T3's bundled model entries remain visible; use the Auto entries or add an exact model the chosen proxy supports. Custom entries currently expose no model-specific effort/fast/context controls.

## Files and credential loading

- `~/.local/bin/claude-t3-{copilot,vertex,openai,enmass}`: executable symlinks to `scripts/claude-provider.zsh` in this repository.
- `scripts/claude-provider-prepare.zsh`: minimal zsh bootstrap and existing-wrapper preparation.
- `scripts/claude-provider.py`: settings merging, credential-free catalog caching, and process supervision.
- `~/.t3/userdata/settings.json`: four named `claudeAgent` instances, each pointing at its own launcher. No credential values were added to T3 settings.
- `~/.t3/userdata/client-settings.json`: per-instance picker preferences. EnMaaS hides the bundled `claude-fable-5-1` and `claude-fable-5` entries through `providerModelPreferences.claude_enmass.hiddenModels`; removing custom entries alone does not hide T3's built-in models.
- `~/secrets.zsh`: loaded at invocation time. The bridge suppresses source output and does not load the interactive `.zshrc`.

Optional per-instance environment settings in T3:

All provider wrappers always clear `DISABLE_NON_ESSENTIAL_MODEL_CALLS` and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` before launching Claude, so Monitor does not require an opt-in flag or a T3 environment entry. These variables must be unset rather than set to `0`. Start a new Claude process to apply wrapper changes. Monitor can still be unavailable if another source sets `DISABLE_TELEMETRY`, a tool restriction applies, or the session runs in bare mode.

| Variable | Purpose |
|---|---|
| `CLAUDE_PROVIDER_CREDENTIALS_FILE` | Override `~/secrets.zsh` with an absolute path to another credential bootstrap. An explicitly configured unreadable source fails. |
| `CLAUDE_PROVIDER_NATIVE_BINARY` | Override the real Claude executable; defaults to `~/.local/bin/claude`. Recursive bridge targets are rejected. |

The native Claude config directory T3 supplied is preserved. Existing shell `claude-mode` and persistent Claude settings are not changed. Preparation clears an inherited backend transport before loading credentials and selecting the fixed wrapper. Upstream OpenAI/EnMaaS keys stay with their proxies rather than being forwarded to the final Claude child. Claude's local transport/settings layer is kept in temporary private files and removed when the invocation exits; transport credentials are not placed on Claude's command line.

## Proxy preparation

Each launcher prepares the corresponding existing wrapper and then starts the real Claude CLI. `--version` and standalone help bypass credential loading and proxy preparation to satisfy T3's short availability checks.

Prewarm a cold service after login/credential changes, before opening a T3 session:

```zsh
claude-t3-copilot --prepare
claude-t3-vertex --prepare
claude-t3-openai --prepare
claude-t3-enmass --prepare
```

The output contains endpoint/model metadata, never credential values. These commands can start the configured local services and discover their catalogs; they send no generation prompt. Copilot requires prior gateway GitHub authorization, Vertex requires its project/region and ADC, OpenAI uses the existing key resolver, and EnMaaS requires its gateway base/key.

Preparation is serialized per backend under `${XDG_STATE_HOME:-~/.local/state}/claude-provider/`. New shared proxies are detached from the preparation process group. Existing healthy services are reused. A different credential/config fingerprint fails with an explicit restart instruction instead of automatically terminating an active shared proxy. Restart using the existing backend's helper after its active sessions finish, then prewarm again.

For a running Vertex proxy, the bridge uses its registered tier inventory before trying Model Garden discovery. Vertex's tier cache was aligned with the current running proxy's 5.5 routes. This prevents a transient catalog failure from demanding a fallback-model restart.

EnMaaS discovery metadata is cached for six hours under `${XDG_CACHE_HOME:-~/.cache}/claude-provider/`. Cache identities include the discovery dialect, endpoint, and a fingerprint of the key; the files contain catalog data, not credentials. On a cache miss, normal SDK launches bound each of the three discovery requests to six seconds with no retries. Explicit `--prepare` retains the wrapper's longer cold-start retry policy. To force fresh catalogs, remove the catalog JSON files in that directory and run `--prepare` again. A changed upstream key/base automatically uses a different cache identity. Cached inventory does not prove inference entitlement.

## Protocol and lifecycle

The bridge gathers a launch profile from the original wrapper, combines generated picker settings with T3's settings, and pins the selected transport environment. It retains SDK permission, resume, MCP, and other settings. A settings file or inline JSON is supported. All remaining argv, stdin, cwd, and native exit status are forwarded.

Diagnostics use stderr; stdout belongs to Claude's protocol. Cancellation stops the invocation's preparation/Claude process group and its descendants, with bounded escalation. Shared detached proxies are not stopped when a session exits or is cancelled. Locks coordinate these launchers; interactive shell invocations continue to use their existing lifecycle and are not covered by those locks.

## Verified on this installation

- Native Claude: 2.1.295.
- Four local proxy preparations completed: Copilot `:4141`, Vertex `:4142`, OpenAI `:4145`, EnMaaS `:4146`.
- Copilot, Vertex, and OpenAI listener PIDs stayed unchanged. EnMaaS was started through its existing service controller.
- The SDK bundled in the installed T3 application initialized through all four launchers without yielding a generation prompt: approximately 0.5–0.6 seconds for Copilot/Vertex/OpenAI and 2 seconds for EnMaaS with warm catalogs.
- Seven offline bridge tests passed: four backend identities, settings precedence, stdin/argv/cwd forwarding, credential isolation, fast version checks, file settings, preparation/failure status, private catalog caching, native descendant cancellation, and preparation cancellation preserving a detached fixture proxy.
- Existing model-picker tests and the EnMaaS proxy/lifecycle suites passed.
- The separate, already-untracked `tests/claude-enmass.zsh` fails at line 23 because it calls the removed `_claude_enmass_program` helper. That failure predates the bridge edits; the current proxy/lifecycle suites cover the present EnMaaS implementation.

No real inference, paid generation, model-quality evaluation, or T3 chat/tool turn was run. SDK initialization verifies executable/protocol startup, not upstream generation entitlement. The installed T3 app was not patched or restarted. The named instances are configured on disk; if an already-open picker has stale options, refresh provider settings or reopen the picker.

Run offline checks:

```zsh
zsh -c 'python3 ~/git/dotfiles/tests/claude-provider.py'
zsh -c 'zsh ~/git/dotfiles/tests/claude-model-picker.zsh'
zsh -c 'zsh ~/git/dotfiles/tests/claude-enmass-proxy.zsh'
zsh -c 'zsh ~/git/dotfiles/tests/claude-enmass-lifecycle.zsh'
```

The optional `tests/claude-provider-sdk.mjs` smoke test imports the SDK from this exact installed app bundle. Run it using the app's Electron executable with `ELECTRON_RUN_AS_NODE=1` and a backend argument. Its module filename is specific to this build and may need updating after a T3 upgrade.

The original T3 settings snapshot is `~/.t3/userdata/settings.before-claude-providers-20261009.json`. To undo only this integration, remove the four `claude_*` entries and four `claude-t3-*` symlinks. Restoring the full snapshot also restores unrelated settings to their earlier values. Dotfiles changes are left uncommitted because the repository already had staged/uncommitted work.
