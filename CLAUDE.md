# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a dotfiles repository containing ZSH shell configuration files and utilities for a productive development environment. The main entry point is `.zshrc` which sources all necessary configuration files.

## Conventions

### Shell
- **All code in this repo is ZSH, not Bash.** Use ZSH-specific syntax: `$match` for regex captures (not `$BASH_REMATCH`), `${match[1]}` indexing, `=~` with `$match`, etc.

### Naming
- **All public functions and aliases must use `kebab-case`** (e.g., `create-ocp-aws`, `set-tf-proxy`)
- Private/internal helper functions may use `_underscore_prefix` (e.g., `_lazy_load_openshift`)
- Single-word functions are exempt from this rule (e.g., `progress`, `error`)
- When renaming a function, add a backwards-compatibility alias mapping the old name to the new name

## Common Commands

### Dotfiles Management

**Recommended**: Symlink `~/.zshrc` to the repo so changes are instantly live:
```bash
ln -sf ~/git/dotfiles/.zshrc ~/.zshrc
```

Legacy commands (for non-symlink setups):
- `copy-to-dotfiles-from-zshrc` - Copy local .zshrc to the dotfiles repo
- `push-dotfiles-from-zshrc` - Push changes to the dotfiles repository
- `update-zshrc-from-dotfiles` - Update local .zshrc from the dotfiles repo (recommends symlink)

### Updating .zshrc
When making changes to the ZSH configuration:

1. **Edit in dotfiles repo**:
   ```bash
   cd ~/git/dotfiles
   # Make your changes to files in zsh/
   ```

2. **Test changes locally**:
   ```bash
   # Test specific file
   source ~/git/dotfiles/zsh/[modified-file].zsh

   # If symlinked, changes are already live — just reload:
   exec zsh
   ```

3. **Commit and push**:
   ```bash
   cd ~/git/dotfiles
   git add -A
   git commit -m "feat: description of changes"
   git push
   ```

### Installation
```bash
# Install dependencies from Brewfile
brew bundle --file=~/git/dotfiles/Brewfile

# Run automated migration for new laptop
source ~/git/dotfiles/zsh/functions/migrate-laptop.zsh
migrate-to-new-laptop
```

### Testing & Validation

#### Testing ZSH Changes
No formal test suite exists. Changes should be manually tested by:

1. **Syntax Checking**:
   ```bash
   # Check syntax of a specific file
   zsh -n ~/git/dotfiles/zsh/[modified-file].zsh
   
   # Check entire .zshrc
   zsh -n ~/.zshrc
   ```

2. **Source and Test**:
   ```bash
   # Source the modified file
   source ~/git/dotfiles/zsh/[modified-file].zsh
   
   # Test the modified aliases/functions
   # For functions, check if they're loaded:
   which function_name
   type function_name
   ```

3. **Full Shell Test**:
   ```bash
   # Start a new shell session to test startup
   zsh -l
   
   # Or reload the entire configuration
   exec zsh
   ```

4. **Debug Mode**:
   ```bash
   # Start shell with verbose output for debugging
   zsh -xv
   
   # Or trace specific function execution
   zsh -c 'set -x; function_name'
   ```

#### Common Issues to Check
- **Function conflicts**: Use `which` or `type` to check if a function/alias already exists
- **Syntax errors**: Run `zsh -n` on files before committing
- **Performance**: Use `time zsh -i -c exit` to measure shell startup time
- **Dependencies**: Ensure required commands exist with `command -v cmd_name`

## Architecture

### Directory Structure
- **zsh/**: Main configuration directory
  - **aliases/**: Organized aliases by category (docker, git, github, code, etc.)
  - **functions/**: Complex shell functions
    - **openshift/**: Modular OpenShift cluster management functions
  - **znap.zsh**: Plugin manager configuration
  - **alias.zsh**: Main alias loader that sources all category files

### Key Design Patterns
1. **Modular Aliases**: Aliases are organized by category in separate files under `zsh/aliases/`
2. **Function Organization**: Functions are defined plainly as `name() { ... }`. Never prefix a definition with `znap` (i.e. `znap name() { ... }` or `znap function name() { ... }`) — zsh reads `word name() { ... }` as a multi-name function definition, which silently redefines `znap` itself with that body and breaks the plugin manager for the rest of the session.
3. **OpenShift Functions**: Hierarchically organized by cloud provider and functionality
4. **Environment Detection**: Special handling for VS Code terminal vs regular terminal
5. **Command Caching**: Uses completion file caching for performance

### Important Files
- `zsh/alias.zsh`: Sources all alias category files
- `zsh/functions/openshift/load.zsh`: Loads all OpenShift-related functions
- `zsh/functions/claude/load.zsh`: Loads Claude provider wrappers (`common.zsh`, one file per provider in `providers/`, then `mode.zsh`)
- `zsh/functions/claude/providers/openshell.zsh`: `openshell-<backend>` runs a `claude-<backend>` wrapper with Claude Code inside an NVIDIA OpenShell sandbox; image, design notes and deferred work in `zsh/functions/claude/openshell/`
- `zsh/znap.zsh`: Manages ZSH plugins (pure prompt, syntax highlighting, autocomplete)
- `Brewfile`: Defines all Homebrew dependencies

### Context-Mode Shared Daemon
Every Claude session's context-mode MCP server runs as ONE shared daemon per machine (loopback Streamable HTTP, default `127.0.0.1:8790`) instead of a per-session stdio spawn (~87 MB x sessions -> 87 MB x machine). The plugin (our fork `kaovilai/context-mode`, v2.2+) is hooks-only; sessions reach the daemon through a user-scope registration named `context-mode`.

- `scripts/context-mode-daemon-sync.zsh` (run by `fleet-sync` every pass, idempotent): ensures node >= 24.15 (PATH, `~/.local/lib/node-v24*`, Homebrew `node@24`; else auto-installs the sha256-verified nodejs.org tarball into `~/.local/lib` unless `CONTEXT_MODE_DAEMON_NODE_AUTOINSTALL=0`), re-installs the daemon unit when the plugin's versioned cache path moves (Linux systemd user unit `context-mode-daemon.service`; macOS LaunchAgent `com.kaovilai.context-mode-daemon`), and adds the user-scope `claude mcp add --scope user --transport http context-mode http://127.0.0.1:8790/mcp` registration when missing.
- Marketplace + plugin distribution already go through `settings.json` (`extraKnownMarketplaces` / `enabledPlugins`) via `sync-claude-plugins`.
- Loopback is not user-isolated: on a shared host another OS user can reach the daemon (and `ctx_execute` with the owner's permissions) — the daemon has no inbound auth by design (see the fork's docs/daemon.md); run it only on single-user machines or behind OS-level access controls.
- Check health: `systemctl --user status context-mode-daemon` (or the launchd equivalent), `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8790/healthz` (want 204), `claude mcp get context-mode`. The daemon needs restarting only via its unit; plugin updates re-point the unit automatically on the next fleet-sync.
- `tests/context-mode-daemon-sync.zsh` covers the sync decisions offline (stub node/claude/systemctl/curl).

## Adding New Features

### Adding Aliases
1. Determine appropriate category file in `zsh/aliases/`
2. Add alias to the file
3. For new categories, create file and add source line to `zsh/alias.zsh`

### Adding Functions
1. For simple functions: Add to `zsh/util.zsh`
2. For complex functions: Create new file in `zsh/functions/`
3. For OpenShift functions: Follow the structure in `zsh/functions/openshift/`

### OpenShift Cluster Management

#### Listing and Using Clusters
- `list-ocp-clusters` - List all OpenShift clusters (AWS, GCP, Azure, ROSA)
- `use-ocp-cluster [PATTERN]` - Set KUBECONFIG to a selected cluster
- `check-for-existing-clusters [PROVIDER] [PATTERN]` - Check for existing clusters before creating new ones

#### Supported Cloud Providers
- **AWS**: Traditional OpenShift on AWS (`*-aws-*` naming pattern)
- **GCP**: Google Cloud Platform with Workload Identity (`*-gcp-wif*` naming pattern)
- **Azure**: Azure with STS/Workload Identity (`*-azure-sts*` naming pattern)
- **ROSA**: Red Hat OpenShift Service on AWS (`*-rosa-sts-*` naming pattern)

#### Directory Structure
Clusters are stored in `$OCP_MANIFESTS_DIR` with naming patterns:
- AWS: `$TODAY-aws-$ARCH` (e.g., `20250131-aws-arm64`)
- GCP: `$TODAY-gcp-wif` (e.g., `20250131-gcp-wif`)
- Azure: `$TODAY-azure-sts` (e.g., `20250131-azure-sts`)
- ROSA: `$TODAY-rosa-sts-$ARCH` (e.g., `20250131-rosa-sts-amd64`)

Note: ROSA clusters may not have traditional kubeconfig files. Use `use-rosa-sts` functions to connect.

### OpenShift Version-Matched oc Binary

When any OCP create function calls `oc adm release extract`, it **must** use a version-matched `oc` binary from the release image. The system `oc` may have stale filtering logic (see OCPBUGS-77845) that extracts wrong credential requests, causing cluster creation failures.

Use the `get-release-oc` helper from `common-functions.zsh`:
```bash
local OC_BIN=$(get-release-oc "$RELEASE_IMAGE")
$OC_BIN adm release extract --cloud=gcp ...
```

The helper extracts `oc` from the release image to `/tmp/oc-<version>/oc` and caches it. Always pass `--cloud=<provider>` (gcp, azure, aws) with `--included` and `--install-config` for credential extraction.

### Dependencies
When adding features that require new tools, update the `Brewfile` with the necessary formulae or casks.

### Post-Merge Fleet Rollout (llm-usage / menubar)
`fleet-sync` updates every machine's dotfiles checkout, but it cannot fix everything a merged llm-usage change needs. After merging a PR that touches these, verify:
- **`scripts/llm-usage` (Python)**: nothing extra — fresh process per invocation; the menubar helper picks it up on its next 30 s poll (details: `docs/notes/change-take-effect.md`).
- **`scripts/llm-usage-menubar/main.swift`**: fixed by fleet-sync now — every pass runs `llm-usage menubar reload` (rebuild when stale + restart the running helper; no-op on a Mac that never built it). Only do it by hand when you want the new code before the next fleet-sync pass: `llm-usage menubar reload`.
- **Peer-side fleet subcommands** (`export`, `watch-inflight`): the aggregator runs them from the peer's checkout, so a not-yet-synced peer fails its pull/stream until its next fleet-sync — expected and self-healing; do not chase it as a bug.
- **`scripts/litellm_usage_log.py` / proxy callbacks**: running proxies keep old code until `llm-proxy-restart` (or the idle-restart in `llm-proxy-sync`) on each machine.

## Hosted-only / EnMaaS models and search

Requirements for `scripts/hosted-only-proxy.zsh`, `scripts/hosted-only-go/`,
`zsh/functions/claude/providers/{hosted-only,enmaas}.zsh`, `scripts/codex-provider.zsh`
and `scripts/llm-usage`. Read `docs/notes/hosted-only-go-proxy.md` and
`docs/notes/web-search-shim.md` before changing them.

### Model pair (slot-based)

- `HOSTED_ONLY_GLM_MODEL` is the **primary** slot, `HOSTED_ONLY_DEEPSEEK_MODEL` the
  **fallback + vision** slot. The names predate the 2026-11-14 pair swap; the pair
  picker, the vision reroute and the `[1m]` picker refs all key off the slots, so a
  swap changes the ids, not the machinery.
- Primary = the stronger coder (benchmarks in the pair-swap PR); fallback = the model
  that takes images and can reason longer. Both are `rits/` ids with the 1M window.
- Short-name knob values (`glm`, `deepseek`) follow the **slots**, not the model names —
  a pin made before a swap means a different model afterwards. Pin a full id to fix
  which model a slot holds; it does not stop a request moving between slots (the vision
  reroute and the router fallback still do that).
- A retired model must keep working for sessions that stored it: add its id to
  `HOSTED_ONLY_ALIAS_MODELS` (legacy name `GLM_HYBRID_ALIAS_MODELS`; a bare
  `ALIAS_MODELS` is never read — an alias is served by the primary slot) instead of
  letting the cost guard answer 400 on continue.
- `config.go`'s built-in defaults are per flavor: claude/codex default to the swapped
  pair plus the launcher's alias set, so a hand-run `ensure`/`watch` regenerates what
  those ports serve. The route-table flavors keep the **EnMaaS** pair (GLM 5.3 +
  DeepSeek V4.1 Flash, no aliases) because nothing sets those knobs for them — but
  **exported** `HOSTED_ONLY_*` knobs do reach the EnMaaS child (its controller forwards
  `CHILD_ENV_PREFIXES`), so exporting `HOSTED_ONLY_{GLM,DEEPSEEK}_MODEL` or
  `HOSTED_ONLY_ALIAS_MODELS` also changes that flavor's slots, aliases, vision reroute,
  fallback pairing and output clamp. These model/alias knobs only reach the child when
  exported, and they do not behave alike: a non-exported `HOSTED_ONLY_{GLM,DEEPSEEK}_MODEL`
  still lands in the EnMaaS route table (`_claude_enmaas_{glm,deepseek}_id`, and
  `ENMAAS_RESPONSES_ROUTES` from it), so the advertised routes and the child's slots can
  diverge, while a non-exported `HOSTED_ONLY_ALIAS_MODELS` is ignored by EnMaaS entirely.
  Knobs on the launchers' shared list (`SEARCH_NUDGE`, image, timeout, …) are re-exported
  by both, so a non-exported value there does reach the child.
- A new model also needs its rollup entries in `scripts/llm-usage` (`strip_model`,
  `family`, `reroute_kind`'s slot set, `BRANDS`, `MODEL_VENDORS`). Traffic still shows
  without them, but lumped under "Other" or its raw id: no brand color, no logo, and
  `reroute_kind` cannot classify its moves.

### Web search: Parallel-injected or not at all — for every served model

- `HOSTED_ONLY_SEARCH_SHIM=1` ⇒ the proxy rewrites the hosted `web_search` tool into a
  `{query}` function tool and serves it from Parallel, with per-(model, gateway)
  verdicts. An unknown verdict falls back to the strip — which is the
  `SEARCH_NUDGE`-gated strip below, so `SEARCH_SHIM=1` with `SEARCH_NUDGE=0` leaves a
  `rits/` model with an unknown verdict — or a request the shim declines before the
  verdict (client owns the `web_search` name, no hosted tool, chat `/v1/chat/completions`
  dialect — the shim serves both anthropic and responses wire shapes) —
  holding the tool with neither behavior. Off/unset ⇒ every `rits/`
  model gets the tool stripped plus the "no web search — route it through the Parallel
  MCP tools" note.
  The strip and its note are gated on `SEARCH_NUDGE` (`rewrite.go`): with
  `HOSTED_ONLY_SEARCH_NUDGE=0` and the shim off, a `rits/` model keeps the hosted tool
  and gets no note. The shim half is gated separately — `SEARCH_SHIM` plus the
  per-model verdict (`searchshim.go`), so it still serves with `SEARCH_NUDGE=0`, and a
  `native` verdict passes the tool through instead of rewriting it. The verdict is
  looked up for the *requested* model before the vision reroute, so a primary's
  `native` verdict also covers a request later rerouted to the fallback slot, even when
  that slot alone would report `ignored`.
- The decision is per `rits/` id, never per slot: a new pair member, the retired alias
  and the `claude-*` aliases all get the same treatment, pinned by
  `scripts/hosted-only-go/searchparity_test.go`. Never ship a served model with neither
  behavior.
- Tool search (deferred tool **definitions**: `tool_search_tool_*` + `defer_loading`) is
  a different feature. `openDeferredTools` opens those definitions inline for `rits/`
  models because a vLLM upstream cannot run the server tool; non-`rits/` Claude models
  and the vertex flavor stay on the native path.

### Catalogs and rollout

- Codex catalog shape versions (`shape1` → `shape2`) bump whenever entry **content**
  changes, not just the ids — otherwise a mislabeled cache from an intermediate revision
  survives the revert. Each flavor labels its own pair (the EnMaaS catalog is GLM 5.3
  text-only + DeepSeek V4.1 Flash).
- Never restart a proxy a live session is routed through. A changed config, hook, key or
  model pair changes the fingerprint; under a busy proxy the launcher refuses to restart
  and names the ids the running proxy does not serve. `<flavor>-hosted-only-restart`
  forces the restart immediately (`HOSTED_ONLY_FORCE_RESTART=1`, zero-refuse swap) — it
  does not wait for idle, so run it only once the sessions have finished.
- Every knob the Go child reads must be forwarded by the launcher — parity in both
  directions is enforced by `tests/go-proxy-knob-parity.zsh` — **and** hashed into the
  fingerprint (`_hosted_only_proxy_fp`'s knob list). That second half is not covered by
  the parity test: a forwarded knob missing from the list leaves a running proxy
  "fresh", so the old value keeps serving until a restart. Check the list when adding a
  knob; `SEARCH_VERDICTS`, `PARALLEL_STATE`, `PARALLEL_MCP`, `PARALLEL_ACCOUNT` and
  `QUOTA_MONTH_TZ` are currently forwarded without being hashed.

### Tests for any change in this area

`zsh tests/hosted-only-proxy.zsh`, `zsh tests/hosted-only-go-proxy.zsh`,
`zsh tests/codex-enmaas.zsh`, `zsh tests/t3-claude-launchers.zsh`,
`zsh tests/go-proxy-knob-parity.zsh`, and
`cd scripts/hosted-only-go && go vet ./... && go test ./...`.
`tests/llm-usage.zsh` fails on clean `main` in the menubar scenarios — diff against a
baseline instead of chasing it.

The required `review` status check is this repo's own hosted-only-review workflow. It
runs on EnMaaS-hosted models and follows `DOTFILES_REF` (default `main`), so its model
is whatever the hosted-only pair currently holds — never name it here. CodeRabbit is
advisory and frequently rate-limited.
