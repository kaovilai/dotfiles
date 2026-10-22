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

**Hosted-only** (`claude-hosted-only`, `codex-hosted-only`, T3 launchers `claude-t3-hosted-only` / `codex-t3-hosted-only`): EnMaaS-hosted free models only. GLM 5.3 is main; DeepSeek V4.1 Flash is the auto-mode classifier / Codex reviewer / small-fast / subagent model and the vision fallback, so no OpenAI key is involved. One local LiteLLM proxy per client flavor (Claude :4148, Codex :4147; `scripts/hosted-only-proxy.zsh`, hooks `scripts/hosted_only_hooks.py`, state `~/.local/state/hosted-only-<flavor>-<port>/`). Knobs `HOSTED_ONLY_*` (ports `HOSTED_ONLY_{CLAUDE,CODEX}_PROXY_PORT`, `HOSTED_ONLY_{GLM,DEEPSEEK}_MODEL`, `HOSTED_ONLY_{CLASSIFIER,SMALL_FAST,REVIEW}_MODEL`, ...). Stop: `claude-hosted-only-kill` / `codex-hosted-only --stop-proxy`. History: an earlier "GLM hybrid" mode (GLM main, OpenAI `gpt-6-luna` reviewer) is retired; `claude-glm-hybrid`, `claude-glm-only`, `codex-glm-hybrid`, `codex-glm-only`, the `*-t3-glm-{hybrid,only}` launchers and the `GLM_HYBRID_*` env names remain as aliases of hosted-only.

### LLM usage monitor

`llm-usage` shows which providers and models your traffic really hits: requested vs served model (flags reroutes such as `sonnet->glm-5.3` or the vision fallback `glm->deepseek-v4.1-flash`), tokens, cache hit rate, latency, errors (the proxy logs the upstream status, e.g. EnMaaS 429, even when the hook rewrites it to a 503 with a reset time; events from before that are classified from the error text and marked `*`), and requests over 200k context (1M-window use). The LiteLLM proxies (hosted-only, vertex, openai) log one JSONL line per request via `scripts/litellm_usage_log.py` into `~/.local/state/llm-usage/`; without proxy data it falls back to Claude Code/Codex transcripts. Commands: `llm-usage [summary --by model,route,proxy,client,role,day,ctx]`, `routes`, `tail -f`, `top`, `errors` (grouped by status + message, flagged rate-limit / quota (budget exhausted) / server; `--spikes` lists error bursts with a sparkline), `status` (which proxies are up and logging, with 7d error counts), and `serve --open` for a browser dashboard with graphs (http://127.0.0.1:4150, loopback only; model usage over time, model share, context-size histogram, latency, routes with reroutes flagged, errors over time split 429 / 5xx / other with spike windows, per-model error rate, live request feed; light/dark, table view per chart, auto-refresh). Proxies started before the callback existed must be restarted to log: `llm-proxy-restart` (restarts every proxy currently listening; or name them: `copilot vertex openai enmaas glm-claude glm-codex`, `--list` to show state). Per-proxy: `claude-{copilot,vertex,openai,enmaas}-restart`, `claude-hosted-only-restart` (retired aliases `claude-glm-hybrid-restart`, `claude-glm-only-restart`), `codex-hosted-only-restart` (retired aliases `codex-glm-hybrid-restart`, `codex-glm-only-restart`) (stop, wait for the port, start again; sessions using that proxy are cut off). Test: `zsh tests/llm-usage.zsh`.

**Menubar monitor** (macOS): a native single-file Swift helper (`scripts/llm-usage-menubar/main.swift`, AppKit status item, no Xcode project/app bundle, needs only `swiftc` from the Command Line Tools) polls `llm-usage menubar-data` (one JSON document: per-proxy up/down, 15m/1h requests and 429/5xx/other counts, throttle, spike, in-flight, by-model/by-proxy, reroutes, Copilot) every 30s and shows `● 12` normally, `⚠ 429 3m` while a 429 reset is in the future (countdown; marked as an estimate from `retry_after`, or the next UTC month start for a quota 429 without one), `✖` when a proxy that logged this week stopped answering, `⚠ spike` on an error burst, plus ` ⏳N` requests in flight and ` ↪N` reroutes in the last 15m; a trailing `?` / greyed item means the last poll failed (menu keeps the last good data and says so). The menu has per-proxy submenus (copy port / restart command, never restarts anything), sparkline and by-model/by-proxy charts (toggle), reroutes by kind (`alias` Claude name served by GLM/DeepSeek, `vision` glm→deepseek, `fallback` router retry), a Copilot section, notifications for entering throttled / a proxy going down (toggle, once per transition), Open dashboard (starts `llm-usage serve` if needed), Open logs, Copy status / last error. In-flight counts come from `inflight-<port>-<pid>.json` files the usage callback writes (entries older than 15m or of dead pids are ignored; proxies only report after `llm-proxy-restart` loads the updated callback). copilot-api has no callback, so its numbers are derived from Claude Code/Codex transcripts (models absent from the proxy log), its in-flight is `n/a`, and the premium quota/reset date comes from copilot-api's `/usage` endpoint when reachable. Commands: `llm-usage menubar build|run|install|uninstall|status` (`build` compiles to `~/.local/share/llm-usage/llm-usage-menubar` when the source is newer; `run` starts one detached instance; `install` writes `~/Library/LaunchAgents/com.kaovilai.llm-usage-menubar.plist` and bootstraps it, `install|uninstall --dry-run` only print). Debug without a GUI: `llm-usage-menubar --dump-menu [--data-file FILE] [--chart-png out.png]`.

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
