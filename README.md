# Dotfiles

A ZSH-first development environment that follows you across machines — and across LLM providers.

One repo covers four things that usually live in five places:

- **A fast, lazy-loading ZSH setup** — aliases, functions, completions, and a startup path that keeps heavy work out of your way.
- **Multi-provider Claude Code / Codex routing** — `claude-mode` swaps the `claude` command between Anthropic, Vertex, EnMaaS, Copilot, OpenAI, local MLX/Ollama, and a cost-guarded "hosted-only" mode, each with its own loopback proxy and lifecycle management.
- **An LLM telemetry stack** — `llm-usage` reads every local proxy's request log (plus Claude/Codex transcripts) and answers "which model actually served my traffic, at what cost, and what is throttled right now" — in the terminal, a browser dashboard, and a native macOS menubar monitor, across your whole fleet of machines.
- **OpenShift / OADP / Velero cluster automation** — repeatable create/connect/destroy flows for AWS, GCP (WIF), Azure (STS), and ROSA clusters with Velero backup setup, version-matched `oc` binaries, and offline-testable installer logic.

Everything here is ZSH (not Bash), kebab-case for public commands, and covered by [27 offline test suites](tests/) that run without a cluster, a proxy, or a GUI.

## Highlights

### 1. One `claude` command, any provider

`claude-mode <provider>` persists your choice; `claude` then dispatches to it. Persistent modes are `copilot`, `enmaas`, `hosted-only`, `vertex`, `vertex-native-adc`, `ollama`, and the `openshell-*` launchers — the other providers below (`openai`, `mlx`, `offline`) have direct `claude-<provider>` wrappers but are not `claude-mode` choices. Proxy-backed providers get `claude-<provider>`, `claude-<provider>-kill`, and `claude-<provider>-restart` (ollama is kill-only); the sandboxed `openshell` provider instead exposes `openshell-<backend>` launchers. `codex` dispatches via `codex-mode`, which supports `native` and `enmaas` only — for the hosted-only cost guard run `codex-hosted-only` directly. Each provider is one self-documenting file under `zsh/functions/claude/providers/`:

| Provider | What it does |
|---|---|
| `copilot` | GitHub Copilot via the copilot-api gateway |
| `vertex` | Google Vertex AI (ADC auth, tier-ranked model probing) |
| `enmaas` | Every EnMaaS model — Claude via Messages, GPT/Gemini via Responses/Chat, GLM/DeepSeek via the Anthropic dialect — behind one shared Go proxy (:4146) with vLLM/`rits/` workarounds baked in |
| `hosted-only` | **Cost guard**: EnMaaS free-tier models only, so subagents can never reach a paid model. GLM 5.3 main, DeepSeek V4.1 Flash as classifier/reviewer/vision fallback. Retired `glm-hybrid`/`glm-only` names still alias here |
| `mlx` / `ollama` | Fully local inference on Apple Silicon / any box, with model resolution and resource checks |
| `openai` | Direct OpenAI, with a route-writing proxy |
| `openshell` | Claude Code inside an NVIDIA OpenShell sandbox |
| `offline` | Local inference: `claude-mlx` on Apple Silicon, `claude-ollama` elsewhere. Local, not a network-isolation guarantee (MLX startup can fetch uncached deps/models — warm it up before disconnecting) |

<details>
<summary><b>EnMaaS provider — details</b></summary>

`claude-enmaas`, `claude-t3-enmaas`, `codex-t3-enmaas`: every EnMaaS model, no tier pinning: Claude via Messages, GPT/Gemini via Responses/Chat (per the discovered catalogs), GLM 5.3 and DeepSeek V4.1 Flash via the Anthropic dialect. One shared loopback proxy (default :4146, `CLAUDE_ENMAAS_PROXY_PORT`; runtime `$XDG_STATE_HOME/claude-enmaas-proxy-<uid>-<port>/`) serves Claude Code (`/v1/messages`) and Codex (`/v1/responses`, `/v1/chat/completions`); `codex-t3-enmaas` wires Codex to it with `-c` overrides that replace T3's direct-to-gateway launchArgs (everything else, e.g. `review_model`, `approvals_reviewer`, stays) and a generated model catalog (`$XDG_STATE_HOME/codex-enmaas/models.json`); Codex only gets the proxy's local token. `CODEX_ENMAAS_DIRECT=1` restores the old direct route. The proxy is a stdlib-only Go binary that reads the generated `config.json` as its route table and does everything the old LiteLLM hooks did: vLLM workarounds for `rits/` models (grammar strip for `apply_patch`, empty developer item filter, thinking-off default, hosted `web_search` dropped, GLM image requests to DeepSeek), Codex `additional_tools` flattening, the 429 reset rewrite for all models, and Messages ↔ Chat/Responses translation so Claude Code works with the GPT/Gemini models too (the rewrite answers `/v1/messages` as a real 429 + `retry-after`, and the launcher sets `CLAUDE_CODE_RETRY_WATCHDOG=1` so Claude Code sleeps through resets up to 6 h in-process; see `docs/notes/claude-code-429-503-handling.md`); see `docs/notes/hosted-only-go-proxy.md`. `CLAUDE_ENMAAS_VISION_FALLBACK_MODEL=<id>` only routes that model through the proxy. A running proxy is never restarted under live sessions: a changed gateway/key/routes/code fails the next launch with a restart instruction; `claude-enmaas-kill` stops only the identity-checked proxy. Tests: `tests/claude-enmaas{,-lifecycle,-proxy,-go-swap}.zsh`, `tests/codex-enmaas.zsh`.
</details>

<details>
<summary><b>Hosted-only provider — details</b></summary>

`claude-hosted-only`, `codex-hosted-only`, T3 launchers `claude-t3-hosted-only` / `codex-t3-hosted-only`: a cost guard, EnMaaS-hosted free models only so subagents cannot reach paid models by accident. GLM 5.3 is main; DeepSeek V4.1 Flash is the auto-mode classifier / Codex reviewer / small-fast / subagent model and the vision fallback, so no OpenAI key is involved. One shared local proxy (`127.0.0.1:4148`) serves both `claude-hosted-only` and `codex-hosted-only` (state `~/.local/state/hosted-only-*/`; `HOSTED_ONLY_CODEX_PROXY_PORT` splits a second proxy off with the same merged config for testing). The proxy is a stdlib-only Go binary (built from `scripts/hosted-only-go`: ~10 MB, no uv or Python, millisecond boot, zero-refuse restarts) — the retired LiteLLM impl is gone, and the old `HOSTED_ONLY_PROXY_IMPL`/`LLM_PROXY_IMPL=litellm` knobs now error loudly instead of silently selecting it. Parity limits in `docs/notes/hosted-only-go-proxy.md`. Knobs `HOSTED_ONLY_*` (ports, models, classifier/reviewer picks). EnMaaS 429s are rewritten so T3 can auto-resume; on `/v1/messages` the rewrite answers a real 429 + `retry-after` and the launchers set `CLAUDE_CODE_RETRY_WATCHDOG=1`, so Claude Code sleeps through any reset up to 6 h in-process instead of failing the turn (a month-end quota still fails fast via `x-should-retry:false` for T3 to snooze on; T3 classifies `api_error_status===429` and reads the reset from the `(reset after ...)` suffix — details and binary evidence in `docs/notes/claude-code-429-503-handling.md`). On the OpenAI chat route a monthly quota becomes HTTP 402 `insufficient_quota` (OpenCode would otherwise sleep ~9 days), per-minute limits stay 429 + `retry-after`. The reset time comes from what upstream sends when it sends anything, else an estimate (next UTC month for the monthly quota, 60 s otherwise); limit data the proxy doesn't understand is logged as `drift` on the `llm-usage` event (`docs/notes/enmaas-reset-forward-compat.md`). `HOSTED_ONLY_CLIENT_MAX_RETRIES` (default 3) bounds Claude Code's retries of real 5xx errors. Stop: `claude-hosted-only-kill` / `codex-hosted-only --stop-proxy`. Retired names (`claude-glm-{hybrid,only}`, `codex-glm-{hybrid,only}`, the `*-t3-glm-*` launchers, `GLM_HYBRID_*` env names) remain as aliases of hosted-only.
</details>

Non-interactive launchers (for apps like T3 Code) live in `scripts/claude-provider.zsh` / `scripts/codex-provider.zsh`.

### 2. `llm-usage` — LLM telemetry that answers real questions

Requested vs **served** model (so reroutes like `sonnet->glm-5.3` or the `glm->deepseek-v4.1-flash` vision fallback are visible), tokens with Anthropic cache semantics, cache hit rate, latency, errors with upstream status, requests over 200k context (1M-window use). Data is one JSONL line per request that each local proxy writes into `~/.local/state/llm-usage/` — logs stay local unless fleet sharing is enabled (then configured peers retrieve merged events over SSH; see Fleet below). Without proxy data it falls back to Claude Code / Codex transcripts.

```bash
llm-usage                      # summary; --by model,route,proxy,client,role,day,ctx
llm-usage top                  # top models / providers
llm-usage routes               # requested→served with reroute flags
llm-usage errors --spikes      # grouped by status + message, error-burst sparklines
llm-usage status               # which proxies are up and logging (7d error counts)
llm-usage tail -f              # live stream (--fleet to include peers)
llm-usage serve --open         # browser dashboard, http://127.0.0.1:4150
```

The dashboard shows model usage over time, share, context-size histogram, latency, rerouting, errors split 429/5xx/other with spike windows, and a live request feed — light/dark, table view per chart, auto-refresh.

**Fleet**: list your other machines in `~/.config/llm-usage/fleet.json` (example: `scripts/fleet.json.example`) and each machine **pulls** the others' merged events over read-only ssh (`llm-usage fleet refresh`) — nothing pushed, no ports opened, unreachable peers keep a snapshot marked stale. First pull covers 7 days, then history backfills 30d per refresh. Design: `docs/notes/fleet-usage-streaming.md`.

### 3. Native macOS menubar + floating monitor

A single-file Swift helper (`scripts/llm-usage-menubar/main.swift` — AppKit status item, no Xcode project, needs only `swiftc`) polls `llm-usage menubar-data` every 30 s:

- Status item `● 12` normally, `⚠ 429 3m` while a rate-limit reset is in the future, `✖` when a proxy that logged this week stopped answering, `⚠ spike` on an error burst, plus `⏳N` in-flight and `↪N` reroutes.
- **Avatar-stack image**: `<model logos><provider logos>` (Claude, GPT, GLM, DeepSeek, Gemini / Copilot, EnMaaS, Vertex, OpenAI, Anthropic), each logo's opacity following its traffic share. Logo lookup falls back from `~/.config/llm-usage/logos/` through installed app icons to generated monograms; `llm-usage menubar logos fetch` pulls a sha256-pinned set from [lobehub/lobe-icons](https://github.com/lobehub/lobe-icons) (license: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)).
- Menu: per-proxy submenus (copy restart command — never restarts anything for you), sparkline and share charts, reroutes by kind, Copilot section, throttle notifications, Open dashboard/logs.
- **Floating window** (Activity Monitor-style, same process): per-minute request bars stacked by model vendor with 429/5xx marks, per-provider rate lines, and translucent throttle ribbons — flat wash for rate limit, hatched for quota, dashed edge for estimated reset. Non-activating panel on all Spaces over full-screen apps; layout, opacity, click-through and frame persist.

```bash
llm-usage menubar build    # compile when source is newer
llm-usage menubar run      # start one detached instance
llm-usage menubar install  # write + bootstrap the LaunchAgent
llm-usage menubar status
llm-usage menubar window show|hide|toggle
```

Debug without a GUI: `llm-usage-menubar --dump-menu`, `--status-png out.png`, `--window-png out.png`.

### 4. `fleet-sync` — edit on one machine, the others follow

`scripts/fleet-sync.zsh` fast-forwards this machine's dotfiles, Claude config (`~/.config/claude`), and copilot-api checkouts, then applies what changed: newly enabled plugins, the shared context-mode daemon unit, T3 provider imports, `bun install` when a lockfile moved, and a rebuild+restart of the menubar helper when its Swift source moved. It never commits, merges, or discards — a repo with uncommitted or diverged work is skipped with a warning. Install an hourly systemd user timer with `--install-timer` (Linux).

The **context-mode daemon** (synced the same way) runs one shared MCP server per machine on loopback instead of one ~87 MB process per session — a `87 MB × sessions → 87 MB × machine` saving.

### 5. OpenShift / OADP / Velero automation

Full cluster lifecycles as shell commands, lazy-loaded so they cost nothing until used:

```bash
list-ocp-clusters                    # every cluster you own, all clouds
create-ocp-aws              # or: create-ocp-gcp-wif, create-ocp-azure-sts, create-rosa-sts
use-ocp-cluster [pattern]   # point KUBECONFIG at it
delete-ocp-aws              # or: delete-ocp-gcp-wif, delete-ocp-azure-sts, delete-rosa-sts
setup-velero-oadp-for-gcp-cluster   # buckets, identities, DPA — also ...-azure- / ...-rosa-cluster
```

Details that matter: every `oc adm release extract` goes through a **version-matched `oc`** extracted from the release image (`get-release-oc`) to dodge stale-filter bugs (OCPBUGS-77845); preflight checks cover cloud permissions and instance-type capacity; cluster naming is date-tagged (`20250131-aws-arm64`) under `$OCP_MANIFESTS_DIR`; and the installer-resolution logic is offline-tested (`tests/openshift-destroy-installer.zsh`).

### 6. A dotfiles repo that tests itself

27 offline test suites (`tests/`) stub out `node`, `claude`, `systemctl`, `curl` and more to verify real behavior: provider lifecycle and proxy routing, mode completion, model pickers, fleet-sync decisions, the context-mode daemon sync, T3 launchers, and `zsh -n` over the whole `.zshrc`. The shell itself is performance-tuned: lazy-loaded function groups, backgrounded non-essential init, and completion caching.

## Function catalog

### Claude / Codex providers & proxies
`claude-mode`, `codex-mode`, `claude-<provider>{,-kill,-restart}` for copilot / vertex / enmaas / hosted-only / mlx / openai (ollama: kill only; openshell: `openshell-<backend>` launchers), `claude-{offline,enmaas}`, `codex-enmaas`, `codex-hosted-only`, `openshell-claude-{ls,clean,image-build}`, `llm-proxy-restart`, `llm-proxy-sync`, `llm-proxy-watch`, `llm-usage` (summary / top / routes / errors / status / tail / serve / fleet / menubar)

### Git & GitHub
`cherrypick-pr`, `cherrypick-pr-to-branch`, `new-changelog`, `go-mod-upgrade`, `pr-me-wt` (runs `pr-me worktree`), `code-git-exclude`, `git-exclude-claude`, OpenCommit signoff wrappers (`oco-signoff`, `oco-signoff-push-force`, …), and ~110 aliases across `zsh/aliases/git.zsh` + `github.zsh` covering fetch/push/PR-create/PR-checkout flows

### Containers & registries
`podman-build-multiarch` (amd64+arm64 via QEMU), `container-registry-inherit`, `check-qemu-stuck` / `kill-stuck-qemu`, `docker-auth` / `podman-auth`, `ghcr_tag`/`ocregistry_tag` helpers, ~30 docker/podman aliases

### OpenShift / cloud
cluster lifecycle (above), `get-release-oc`, `get-openshift-install-for-release-image`, `install-{oc,ccoctl,opm}`, `check-for-existing-clusters`, `save-cluster-login`, `get-api-ca`, `get-oc-router-ca` + `rm-router-ca`, `trust-*` variants, `watch-all-pod-{logs,errors}-in-namespace`, `start-gcp-bootstrap-bugfix-helper`, `start-aws-metal-health-watcher`, `cleanup-orphaned-gcp-resources`, IBM Cloud VPC/COS helpers

### Velero / OADP
`setup-velero-oadp-for-{gcp,azure,rosa}-cluster`, `create-velero-{bsl,bucket,container,identity,dpa}-for-*`, `validate-velero-role-assignments-*`, `cleanup-velero-rosa-resources`, `velero-makecontainer*`, `velero/oadp-set-reviewers`, `velero-review-all`

### Laptop migration & machine setup
`migrate-to-new-laptop` (guided, with `docs/LAPTOP_MIGRATION.md`), `export/import-wifi-credentials`, `list-wifi-networks`, `brewfile-cleanup`, `update-brewfile`, `verify-migration`, `randomize-mac-ifconfig`

### Networking & misc
`set-dns-servers` / `clear-dns-servers`, `wifi-standard`, `generate-self-signed-cert`, `trust-certificate-in-system`, `symlink-to-sd` / `unsymlink-from-sd` / `relink-from-sd`, `aa-inflight-wifi`, `listening-ports`, `sync-claude-plugins`, `fleet-sync`, `export-t3-data` / `import-t3-data`, `install-t3code-from-source`, Hermes session management (`restart-hermes-full`, `kill-hermes-session`, …)

## Scripts (`scripts/`)

| Script | Purpose |
|---|---|
| `claude-provider.zsh` / `codex-provider.zsh` | Non-interactive provider launchers for apps (T3 Code) |
| `claude-provider-go`, `hosted-only-go` | The stdlib-only Go proxies behind the providers |
| `hosted-only-proxy.zsh`, `claude-copilot-paperclip.zsh` | Proxy lifecycle helpers |
| `litellm_usage_log.py` | LiteLLM callback that writes the `llm-usage` JSONL |
| `llm-usage` | The telemetry CLI (stdlib Python, no state beyond the logs) |
| `llm-usage-menubar/main.swift` | The native macOS menubar + floating monitor |
| `llm-usage-dashboard.html` | Browser dashboard |
| `mlx-idle-watch.zsh` | Unloads MLX server when idle |
| `fleet-sync.zsh` | Multi-machine dotfiles/config sync (+ systemd timer) |
| `context-mode-daemon-sync.zsh` | Shared context-mode MCP daemon unit/registration |
| `setup-t3-headless.zsh` | Headless T3 Code laptop setup |
| `spectre-x360/`, `wsl-keepalive.ps1` | Hardware/WSL specific helpers |

Design notes for the proxies and telemetry live in `docs/notes/` (429/503 handling per client, Go-proxy parity, fleet streaming, reset forward-compat, …).

## Installation

**macOS**: install dependencies, then symlink so every edit is instantly live:

```bash
brew bundle --file=~/git/dotfiles/Brewfile   # after cloning below
ln -sf ~/git/dotfiles/.zshrc ~/.zshrc
```

**Linux (Fedora)**: see the [dnf equivalents](#fedora-dnf--brewfile-equivalents) section below; everything else is identical.

Clone and go:

```bash
git clone git@github.com:kaovilai/dotfiles.git ~/git/dotfiles
# Back up any existing ~/.zshrc first — ln -sf replaces it. Alternatively keep
# your current file and add: echo "source ~/git/dotfiles/.zshrc" >> ~/.zshrc
ln -sf ~/git/dotfiles/.zshrc ~/.zshrc
exec zsh
```

`.zshrc` self-bootstraps: if the repo is missing it clones itself, znap installs the prompt/plugins on first run, and secrets stay out of the repo in `~/secrets.zsh` (permission-checked to 600). New machine? `source ~/git/dotfiles/zsh/functions/migrate-laptop.zsh && migrate-to-new-laptop` walks the full setup (checklist: `docs/LAPTOP_MIGRATION.md`).

### Fedora (dnf) — Brewfile equivalents

<details>
<summary>Full dnf install list</summary>

`Brewfile` is macOS/Homebrew-only. On Fedora, install the same tool set via `dnf` (and a few curl-script/pip/go installers where Fedora has no package).

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
</details>

## Testing changes

```bash
zsh -n ~/git/dotfiles/zsh/[modified-file].zsh   # syntax check
source ~/git/dotfiles/zsh/[modified-file].zsh   # source and exercise it
exec zsh                                        # full reload
zsh tests/<suite>.zsh                           # run the matching offline suite
time zsh -i -c exit                             # keep startup fast
```

No formal framework — each test suite is a self-contained zsh script that stubs external commands and asserts behavior. When adding a feature that has a testable core (sync decisions, route generation, installer resolution), add a suite; the existing 27 are the pattern.

## Structure

```
.zshrc                  # entry point — symlink ~/.zshrc here; self-bootstrapping
Brewfile                # macOS dependencies
zsh/
  alias.zsh             # loads all alias categories
  aliases/              # git, github, docker, go, velero, ibmcloud, code, misc
  functions/
    claude/             # provider framework: load.zsh, mode.zsh, providers/*.zsh, openshell/
    openshift/          # cluster lifecycle, lazy-loaded
    s3/                 # S3 tooling, lazy-loaded
    git-utils.zsh, podman-utils.zsh, dns.zsh, wifi.zsh, ...  # lazy-loaded groups
  znap.zsh              # plugin manager (pure prompt, syntax highlighting, autocomplete)
  completions/          # custom completions (llm-usage, tailscale)
scripts/                # llm-usage, proxies, fleet-sync, menubar monitor, ...
docs/                   # setup guides + docs/notes/ design notes
tests/                  # 27 offline test suites
```

See `zsh/aliases/README.md` for adding aliases; conventions (ZSH not Bash, kebab-case public names, `znap` never prefixed on function definitions) are in `CLAUDE.md`.

 <3
