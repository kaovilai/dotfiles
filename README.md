# Dotfiles

A collection of shell configuration files and utilities for a productive development environment.

## Structure

- **zsh/**: ZSH shell configuration files
  - **aliases/**: Organized aliases by category
    - **docker.zsh**: Docker-related aliases
    - **git.zsh**: Git command shortcuts
    - **github.zsh**: GitHub CLI commands
    - **code.zsh**: VSCode related aliases
    - **ibmcloud.zsh**: IBM Cloud commands
    - **velero.zsh**: Velero-specific commands
    - **misc.zsh**: Miscellaneous aliases
  - **alias.zsh**: Main alias loader
  - **colors.zsh**: Color definitions
  - **completions.zsh**: Command completion configuration
  - **paths.zsh**: PATH environment variable configuration
  - **util.zsh**: Utility functions
  - **znap.zsh**: ZSH Snap plugin manager configuration
  - Other tool-specific configuration files

## Usage

The main entry point is `.zshrc` which sources all the necessary files.

### Key Commands

- `copy-to-dotfiles-from-zshrc`: Copy your local .zshrc to the dotfiles repo
- `push-dotfiles-from-zshrc`: Push changes to the dotfiles repository
- `update-zshrc-from-dotfiles`: Update your local .zshrc from the dotfiles repo

### Migration Commands

- `migrate-to-new-laptop`: Set up a new laptop with your development environment
- `export-wifi-credentials`: Export WiFi network names for migration
- `import-wifi-credentials`: Import WiFi networks on new laptop
- `list-wifi-networks`: List currently saved WiFi networks

### Claude providers

`claude` dispatches to the provider saved by `claude-mode`; each provider also has its own `claude-<provider>` / `claude-<provider>-kill` commands. Every provider lives in one file under `zsh/functions/claude/providers/`, whose header comment documents its requirements and environment variables. Non-interactive launchers for apps such as T3 Code are documented in `scripts/claude-provider.zsh`.

**EnMaaS** (`claude-enmaas`, `claude-t3-enmaas`, `codex-t3-enmaas`): every EnMaaS model, no tier pinning: Claude via Messages, GPT/Gemini via Responses/Chat (per the discovered catalogs), GLM 5.3 and DeepSeek V4.1 Flash via the Anthropic dialect. One shared loopback LiteLLM proxy (default :4146, `CLAUDE_ENMAAS_PROXY_PORT`; runtime `/tmp/claude-enmaas-proxy-<uid>-<port>/`, boot log `proxy.log` there) serves Claude Code (`/v1/messages`) and Codex (`/v1/responses`, `/v1/chat/completions`); `codex-t3-enmaas` wires Codex to it with `-c` overrides that replace T3's direct-to-gateway launchArgs (everything else in the launchArgs, e.g. `review_model`, `approvals_reviewer`, stays) and a generated model catalog (bundled entries + GLM text + DeepSeek text/image, `$XDG_STATE_HOME/codex-enmaas/models.json`); Codex only gets the proxy's local token. `CODEX_ENMAAS_DIRECT=1` restores the old direct route. Hooks copied next to the proxy config and loaded as dotted modules (`hosted_only_hooks`, `unwrap_tools_middleware`, `enmaas_proxy_hooks`, `litellm_usage_log` in `scripts/`): vLLM workarounds for `rits/` models only (grammar strip for `apply_patch`, empty developer item filter, thinking-off default, hosted `web_search` dropped, GLM image requests to DeepSeek), `/v1/responses` served by a `<id>#responses` passthrough sibling route (for GLM/DeepSeek and every Responses-dialect GPT id), and the 429 reset rewrite for all models. A failed GLM request is only retried on another model with an explicit `CLAUDE_ENMAAS_VISION_FALLBACK_MODEL`. A running proxy is never restarted under live sessions: a changed gateway/key/routes/hook code or `HOSTED_ONLY_*` knob fails the next launch with a restart instruction; `claude-enmaas-kill` stops only the identity-checked proxy. Tests: `tests/claude-enmaas{,-lifecycle,-proxy}.zsh`, `tests/codex-enmaas.zsh`.

**Hosted-only** (`claude-hosted-only`, `codex-hosted-only`, T3 launchers `claude-t3-hosted-only` / `codex-t3-hosted-only`): a cost guard, EnMaaS-hosted free models only so subagents cannot reach paid models by accident. GLM 5.3 is main; DeepSeek V4.1 Flash is the auto-mode classifier / Codex reviewer / small-fast / subagent model and the vision fallback, so no OpenAI key is involved. One local LiteLLM proxy per client flavor (Claude :4148, Codex :4147; `scripts/hosted-only-proxy.zsh`, hooks `scripts/hosted_only_hooks.py`, state `~/.local/state/hosted-only-<flavor>-<port>/`). Knobs `HOSTED_ONLY_*` (ports `HOSTED_ONLY_{CLAUDE,CODEX}_PROXY_PORT`, `HOSTED_ONLY_{GLM,DEEPSEEK}_MODEL`, `HOSTED_ONLY_{CLASSIFIER,SMALL_FAST,REVIEW}_MODEL`, ...). EnMaaS 429s are rewritten so T3 can auto-resume (see the hooks docstring); on the OpenAI chat route (`/v1/chat/completions`, OpenCode) a monthly quota becomes HTTP 402 `insufficient_quota` with no `retry-after` (OpenCode retries every 429 and would sleep ~9 days), per-minute limits stay 429 + `retry-after`. The reset time comes from what upstream sends when it sends anything (`retry-after[-ms]`, JSON `error.reset_at`/`retry_after`, `x-ratelimit-reset-*`, `RateLimit`, Anthropic/Copilot reset headers), else an estimate (next UTC month for the monthly quota, 60 s otherwise); limit data the hooks do not understand is logged as `drift` on the `llm-usage` event and as one WARNING per signal in the proxy log (`docs/notes/enmaas-reset-forward-compat.md`). LiteLLM's own upstream retries are off (`HOSTED_ONLY_UPSTREAM_RETRIES`, default 0, so each 429 is one upstream hit); `HOSTED_ONLY_CLIENT_MAX_RETRIES` (default 3) sets `CLAUDE_CODE_MAX_RETRIES` for `claude-hosted-only` (Claude Code default 10 stalls ~10 min on 60 s per-minute waits; also bounds real 5xx retries). Changing either knob changes the proxy fingerprint: stop an idle proxy to apply it (`claude-hosted-only-kill` / `codex-hosted-only --stop-proxy`). Stop: `claude-hosted-only-kill` / `codex-hosted-only --stop-proxy`. History: an earlier "GLM hybrid" mode (GLM main, OpenAI `gpt-6-luna` reviewer) is retired; `claude-glm-hybrid`, `claude-glm-only`, `codex-glm-hybrid`, `codex-glm-only`, the `*-t3-glm-{hybrid,only}` launchers and the `GLM_HYBRID_*` env names remain as aliases of hosted-only.

### LLM usage monitor

`llm-usage` shows which providers and models your traffic really hits: requested vs served model (flags reroutes such as `sonnet->glm-5.3` or the vision fallback `glm->deepseek-v4.1-flash`), tokens, cache hit rate, latency, errors (the proxy logs the upstream status, e.g. EnMaaS 429, even when the hook rewrites it to a 503 with a reset time; events from before that are classified from the error text and marked `*`), and requests over 200k context (1M-window use). The LiteLLM proxies (hosted-only, vertex, openai) log one JSONL line per request via `scripts/litellm_usage_log.py` into `~/.local/state/llm-usage/`; without proxy data it falls back to Claude Code/Codex transcripts. Commands: `llm-usage [summary --by model,route,proxy,client,role,day,ctx]`, `routes`, `tail -f`, `top`, `errors` (grouped by status + message, flagged rate-limit / quota (budget exhausted) / server; `--spikes` lists error bursts with a sparkline), `status` (which proxies are up and logging, with 7d error counts), and `serve --open` for a browser dashboard with graphs (http://127.0.0.1:4150, loopback only; model usage over time, model share, context-size histogram, latency, routes with reroutes flagged, errors over time split 429 / 5xx / other with spike windows, per-model error rate, live request feed; light/dark, table view per chart, auto-refresh). Proxies started before the callback existed must be restarted to log: `llm-proxy-restart` (restarts every proxy currently listening; or name them: `copilot vertex openai enmaas glm-claude glm-codex`, `--list` to show state). Per-proxy: `claude-{copilot,vertex,openai,enmaas}-restart`, `claude-hosted-only-restart` (retired aliases `claude-glm-hybrid-restart`, `claude-glm-only-restart`), `codex-hosted-only-restart` (retired aliases `codex-glm-hybrid-restart`, `codex-glm-only-restart`) (stop, wait for the port, start again; sessions using that proxy are cut off). Test: `zsh tests/llm-usage.zsh`.

**Menubar monitor** (macOS): a native single-file Swift helper (`scripts/llm-usage-menubar/main.swift`, AppKit status item, no Xcode project/app bundle, needs only `swiftc` from the Command Line Tools) polls `llm-usage menubar-data` (one JSON document: per-proxy up/down, 15m/1h requests and 429/5xx/other counts, throttle, spike, in-flight, by-model/by-proxy, reroutes, Copilot) every 30s and shows `● 12` normally, `⚠ 429 3m` while a 429 reset is in the future (countdown; marked as an estimate from `retry_after`, or the next UTC month start for a quota 429 without one), `✖` when a proxy that logged this week stopped answering, `⚠ spike` on an error burst, plus ` ⏳N` requests in flight and ` ↪N` reroutes in the last 15m; a trailing `?` / greyed item means the last poll failed (menu keeps the last good data and says so). The menu has per-proxy submenus (copy port / restart command, never restarts anything), sparkline and by-model/by-proxy charts (toggle), reroutes by kind (`alias` Claude name served by GLM/DeepSeek, `vision` glm→deepseek, `fallback` router retry), a Copilot section, notifications for entering throttled / a proxy going down (toggle, once per transition), Open dashboard (starts `llm-usage serve` if needed), Open logs, Copy status / last error. In-flight counts come from `inflight-<port>-<pid>.json` files the usage callback writes (entries older than 15m or of dead pids are ignored; proxies only report after `llm-proxy-restart` loads the updated callback). copilot-api has no callback, so its numbers are derived from Claude Code/Codex transcripts (models absent from the proxy log), its in-flight is `n/a`, and the premium quota/reset date comes from copilot-api's `/usage` endpoint when reachable. Commands: `llm-usage menubar build|run|install|uninstall|status` (`build` compiles to `~/.local/share/llm-usage/llm-usage-menubar` when the source is newer; `run` starts one detached instance; `install` writes `~/Library/LaunchAgents/com.kaovilai.llm-usage-menubar.plist` and bootstraps it, `install|uninstall --dry-run` only print). The status item draws an image by default: `<model logos><provider logos>` as two avatar stacks (models: Claude, GPT, GLM, DeepSeek, Gemini, other; providers: GitHub Copilot, EnMaaS, Vertex, OpenAI, Anthropic, other), each logo's opacity following its share of traffic (floor 0.25, dominant on top, at most 4 per cluster plus a `+N` chip, a faint outline per cluster when idle), a red/amber dot on the corner for throttled / proxy down (red) or error spike (amber), and the short text (`12`, `429 3m`) after it. `menubar-data` carries the same numbers as `share` (`{window, metric, models[], providers[]}`; `--share-window 15m|1h`, `--share-metric requests|tokens`); the menu lists them under TRAFFIC SHARE and has toggles for the image, the text, the 1h window and tokens as the metric (defaults: image + text, 15m, requests). Models map from the served model name (`MODEL_VENDORS`), providers from the proxy port (`PROVIDER_PORTS`; copilot transcript calls count as GitHub Copilot); `LLM_USAGE_PROVIDER_MAP="4149=anthropic,my-proxy=key:Label"` overrides or extends it. No logo files are committed: lookup order is `~/.config/llm-usage/logos/<key>.png|pdf|svg` (or `<key>.mono.png`, tinted to the menubar text colour) > `~/.local/share/llm-usage/logos/` > an installed app's icon (Claude, ChatGPT, GitHub Copilot, Gemini) > a generated monogram in a plain brand colour. `llm-usage menubar logos` lists what each key resolved to and where to drop custom files; `llm-usage menubar logos fetch` downloads a sha256-pinned set of PNGs from a pinned commit of [lobehub/lobe-icons](https://github.com/lobehub/lobe-icons) (MIT; credit and license text in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)). The logos are trademarks of their owners, shown for personal status-bar use only. Debug without a GUI: `llm-usage-menubar --dump-menu [--data-file FILE] [--chart-png out.png] [--no-image] [--no-text]`, `llm-usage-menubar --status-png out.png [--dark] [--no-text] [--data-file FILE]` (renders the status item, @2x, light or dark), `llm-usage-menubar --list-logos`.

**Floating monitor window** (same helper, no extra process; Activity Monitor-style "CPU History"): menu items `Floating Window` (checkmark), `Window Layout` (Horizontal / Vertical / compact History), `Window Graph` (Bars = models / Lines = providers / Both), `Window Opacity` (100/80/60/40%) and `Window Click-through` (mouse passes through; the menubar menu item is the way back). It is a non-activating utility panel (`.floating` level, all Spaces, over full-screen apps, no Dock icon, movable by its background, resizable) whose frame, per-layout size, layout, graph mode, opacity, click-through and visibility persist across restarts. The graph is per-minute requests for the last hour as bars stacked by model vendor (claude/gpt/glm/deepseek/gemini colours) with 429 (amber) / 5xx (red) marks, one rate line per provider (Copilot white on dark / grey on light, EnMaaS red, Vertex pink, ...), and translucent throttle ribbons per provider spanning start (first 429) to reset: flat wash = rate limit, hatched + dotted lane = quota, dashed end edge = estimated reset, solid edge = known end (a later success of the same provider + model, or an upstream-reported `reset_source`). Beside/below it: in-flight count + oldest wait, top models and providers with share %, proxy up/down dots; a yellow `⚠ code needs updating: <hint>` row appears when the proxy logger attached `drift` notes (click copies the hint; the same row is in the menu). `menubar-data` gained `series.by_vendor`, `series_by_provider`, `throttle_spans[]` (`provider, start, end, end_estimated, kind, count, source, basis, reset_source`), `throttle_notes`, `drift[]`, and `throttled.estimated/reset_source` (upstream resets drop the `ESTIMATE` label); spans use named proxies only. Copilot (:4141, no usage log) throttles are read from Claude Code transcripts (`type:system subtype:api_error` retry entries with `error.status` 429/402/403/503 + `retryInMs`, and `isApiErrorMessage` + `apiErrorStatus`), attributed by the session's last model with the same "model absent from the proxy log" rule as the usage numbers; LiteLLM "No deployments available" 429s and bracket-tagged proxy errors are the hosted-only proxy's and never become Copilot spans; a 402 is a quota span (ending at copilot-api `/usage`'s reset when known); `/usage` premium interactions and `5Hour-`/`Weekly-Session-RateLimits` at 0 remaining also become quota spans; with no data the menu says so instead of inventing a throttle. `llm-usage menubar window show|hide|toggle` drops a command file the running helper polls once a second. Debug without a GUI: `llm-usage-menubar --window-png out.png [--dark] [--layout horizontal|vertical|history] [--size WxH] [--graph bars|lines|both] [--stale] --data-file FILE`; `llm-usage errors` ends with a "Code needs updating" block when drift notes exist. Apply a new build with `llm-usage menubar build`, then quit the helper and `llm-usage menubar run`.


## Features

- Organized aliases by category for better maintainability
- Efficient completion file caching
- Optimized utility functions
- Znap plugin manager for fast shell startup
- Comprehensive Git and GitHub workflow aliases
- Docker and container management shortcuts
- Cloud platform integrations (IBM Cloud, AWS, etc.)

## Adding New Aliases

See `zsh/aliases/README.md` for instructions on adding new aliases to the appropriate category.

## Dependencies

This dotfiles repository relies on several tools and utilities. Below is a list of all dependencies and how to install them using Homebrew:

### Core Shell Tools

```bash
# Install ZSH (may already be installed on macOS)
brew install zsh

# Install required utilities for the shell
brew install coreutils
```

### Plugin Manager & Plugins

```bash
# ZSH Snap (znap) will be automatically installed when you source the dotfiles
# The following plugins are managed by znap and will be installed automatically:
# - sindresorhus/pure (prompt)
# - zsh-users/zsh-syntax-highlighting
# - marlonrichert/zsh-autocomplete
```

### Version Control Tools

```bash
# Git and GitHub related tools
brew install git
brew install gh
brew install jq  # Used in GitHub workflow aliases

# OpenCommit for AI-powered Git commits
npm install -g opencommit
```

### Development & Container Tools

```bash
# Container tools
brew install podman
brew install docker  # or download Docker Desktop
brew install colima  # macOS container runtime alternative

# Docker buildx for multi-architecture builds
# (included with Docker Desktop or Docker CE >= 19.03)

# Code editors
brew install --cask visual-studio-code

# Local AI
brew install ollama

# YAML processing
brew install yq

# JSON processing 
brew install jq

# Go programming language
brew install go
```

### Cloud & Kubernetes Tools

```bash
# Kubernetes and related tools
brew install kubernetes-cli  # kubectl
brew install kind
brew install krew  # kubectl plugin manager

# Cloud provider CLIs
brew install awscli
brew install google-cloud-sdk
brew install velero
brew install ibmcloud-cli

# OpenShift tools (alternative installation methods provided in functions)
# OpenShift CLI
brew install openshift-cli   # Or use the provided function: install-oc

# For OpenShift development
# install-ocp-installer  # Function provided in the repo
# For cloud credential operator
# install-ccoctl        # Function provided in the repo
```

### Utility Tools

```bash
# General utilities
brew install gnu-sed
brew install socat
brew install spoof-mac
brew install lsof
brew install coreutils

# macOS specific
brew install --cask displaylink  # For external display support
```

### Browser

```bash
# Microsoft Edge
brew install --cask microsoft-edge
```

### Optional Tools

```bash
# Additional tools referenced in aliases
brew install --cask github
brew install --cask activepieces
```

## Fedora (dnf) — Brewfile Equivalents

`Brewfile` is macOS/Homebrew-only. On Fedora, install the same tool set via `dnf` (and a few curl-script/pip/go installers where Fedora has no package) instead of running `brew bundle`.

### Essential CLI

```bash
sudo dnf install -y git gh wget curl gnupg2 gpgme bash pinentry
# glab (GitLab CLI): no Fedora repo package -- download binary from
# https://gitlab.com/gitlab-org/cli/-/releases
```

### Shell and terminal tools

```bash
# coreutils/sed/grep are already GNU on Fedora -- no gsed/ggrep prefix needed,
# unlike macOS where Homebrew's GNU versions must be g-prefixed.
sudo dnf install -y ripgrep fzf tree htop procps-ng jq lynx parallel mosh
# yq: not in Fedora repos -- pip install yq, or
#   go install github.com/mikefarah/yq/v4@latest
```

### Development tools

```bash
sudo dnf install -y golang nodejs pipx pkgconf
# golangci-lint: curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $(go env GOPATH)/bin
# uv: curl -LsSf https://astral.sh/uv/install.sh | sh
# yarn: npm install -g yarn  (or: sudo dnf install yarnpkg)
# node@18 (specific version pin): use nvm instead of a dnf package
```

### Container and Kubernetes tools

```bash
# Prefer podman over docker on this repo (see CLAUDE.md) -- native on Fedora, no VM needed.
sudo dnf install -y podman kubernetes-client skopeo
# minikube: download binary -- https://minikube.sigs.k8s.io/docs/start/
# lima (Linux VMs on macOS): not needed on Linux, podman is already native
```

### Cloud CLI tools

```bash
# azure-cli: curl -sL https://aka.ms/InstallAzureCLIDeb | bash  (Debian-flavored script; on
#   Fedora, add Microsoft's yum repo per https://learn.microsoft.com/cli/azure/install-azure-cli-linux)
# openshift-cli (oc): no dnf package -- download from mirror.openshift.com,
#   or use this repo's own install-oc function
# rosa-cli, stern: no dnf package -- download binary from each project's GitHub releases
```

### Network tools

```bash
sudo dnf install -y iperf iperf3
# spoof-mac (macOS networksetup wrapper): no Linux equivalent needed --
#   use macchanger (sudo dnf install macchanger) for MAC spoofing on Linux instead
```

### Document and media tools

```bash
sudo dnf install -y ffmpeg poppler-utils ocrmypdf   # ffmpeg needs RPM Fusion enabled
```

### YAML/config tools

```bash
sudo dnf install -y yamllint
# yamlfix: pip install yamlfix
# cfssl: go install github.com/cloudflare/cfssl/cmd/cfssl@latest (and cfssljson alongside it)
```

### AI tools

```bash
# ollama: curl -fsSL https://ollama.com/install.sh | sh
# gptme: pip install gptme
# nvidia/openshell (macOS tap): no Linux equivalent tracked
```

### Misc tools

```bash
# copyparty: pipx install copyparty
# googleworkspace-cli (gws): install per its own repo instructions, no dnf package
# cliclick, switchaudio-osx (macOS automation), container (Apple's runtime, use podman instead): skip on Linux
```

### Security

```bash
# snyk: npm install -g snyk
# trivy: add Aqua Security's dnf repo (https://aquasecurity.github.io/trivy/latest/getting-started/installation/) then: sudo dnf install trivy
```

### Runtime tools

```bash
# bun: curl -fsSL https://bun.sh/install | bash
# socktainer (macOS podman-machine socket manager): not needed -- podman runs natively on Linux
```

### Cask equivalents

```bash
# ghostty: available via Fedora COPR (or check `sudo dnf install ghostty` -- shipped in Fedora repos as of recent releases)
sudo dnf install -y gstreamer1-plugins-base gstreamer1-plugins-good gstreamer1-plugins-bad-free gstreamer1-plugins-ugly-free openscad
```

### VS Code extensions

Unaffected by OS — `code --install-extension <id>` for each entry in `Brewfile`'s `vscode "..."` lines works the same on Linux, once VS Code itself is installed:
```bash
# VS Code: add Microsoft's repo (https://code.visualstudio.com/docs/setup/linux#_rhel-fedora-and-centos-based-distributions), then:
sudo dnf install -y code
```

## Installation

After installing the dependencies above, clone this repository and source the `.zshrc` file:

```bash
git clone https://github.com/USERNAME/dotfiles.git ~/git/dotfiles
echo "source ~/git/dotfiles/.zshrc" >> ~/.zshrc
```

Replace USERNAME with your GitHub username.

## Testing Changes

Before committing changes to ZSH configuration files:

```bash
# Check syntax of modified file
zsh -n ~/git/dotfiles/zsh/[modified-file].zsh

# Source and test the changes
source ~/git/dotfiles/zsh/[modified-file].zsh

# Test full shell reload
exec zsh
```

 <3
