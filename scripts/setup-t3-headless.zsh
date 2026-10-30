#!/usr/bin/env zsh
# Set up a Fedora machine or a WSL2 distro (Fedora or Ubuntu) as a headless T3 Code host
# on GitHub Copilot: no EnMaaS, Vertex or ~/secrets.zsh. Safe to rerun; every
# step skips what is already done.
#
#   sudo dnf install -y zsh git          # or: sudo apt install -y zsh git
#   git clone https://github.com/kaovilai/dotfiles ~/git/dotfiles
#   zsh ~/git/dotfiles/scripts/setup-t3-headless.zsh [--dry-run] [--no-power] [--no-tailscale] [--enmaas]
#
# Steps: distro packages (Node >= 20.11 via NodeSource on Ubuntu), your Claude
# config (~/.claude -> a clone of the private kaovilai/.claude repo in
# ~/.config/claude, as on the Mac; gh login first), Claude Code, the plugins
# settings.json enables,
# bun, ~/.zshrc -> this repo and zsh as login shell, the copilot-api checkout
# and its GitHub device login, the claude-t3-copilot launcher, t3 with a
# claude_copilot provider instance, lingering + `t3 service install`,
# Tailscale (tailscaled, you as its operator, login), the hourly fleet-sync
# timer. On a
# laptop (battery, not WSL) also: ignore the lid on AC, no idle suspend on AC
# at the login screen or in your session, sshd. Under WSL: systemd in
# /etc/wsl.conf. Ends with verify-t3-headless and prints what stays manual:
# shared Wi-Fi, TPM disk unlock, the Windows boot task, `t3 pair`.
# Background: docs/LAPTOP_MIGRATION.md, "Copilot-only Linux host".
emulate -L zsh
setopt pipe_fail
autoload -Uz is-at-least

typeset root="${0:A:h:h}" dry=0 power=1 tailscale=1 enmaas=0 arg
for arg in "$@"; do
    case $arg in
        --dry-run) dry=1 ;;
        --no-power) power=0 ;;
        --no-tailscale) tailscale=0 ;;
        --enmaas) enmaas=1 ;;
        -h|--help) sed -n '2,18p' "${0:A}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) print -ru2 -- "setup-t3-headless: unknown option $arg (--dry-run, --no-power, --no-tailscale, --enmaas)"; exit 2 ;;
    esac
done

source "$root/zsh/functions/migrate-laptop.zsh"   # progress/success/warning/error + t3 launcher functions

[[ "$OSTYPE" == linux* ]] || { error "Linux only (Fedora, or a WSL2 distro)"; exit 1; }
(( EUID )) || { error "Run as your normal user, not root: the T3 service is a per-user systemd unit"; exit 1; }

typeset wsl=0 laptop=0 pm systemd=0
[[ -n "${WSL_DISTRO_NAME-}" || -e /proc/sys/fs/binfmt_misc/WSLInterop ]] && wsl=1
typeset -a bats=("${T3_POWER_SUPPLY_DIR:-/sys/class/power_supply}"/BAT*(N))
(( ! wsl && ${#bats} )) && laptop=1
[[ -d /run/systemd/system ]] && systemd=1
if (( $+commands[dnf] )); then pm=dnf
elif (( $+commands[apt-get] )); then pm=apt
else error "Neither dnf nor apt-get found"; exit 1
fi
typeset -a manual=()   # follow-ups printed at the end

# _run <cmd...>: run it, or under --dry-run just show it.
_run() {
    print -ru2 -- "+ ${(j: :)${(q-)@}}"
    (( dry )) || "$@"
}

# _write_root <path>: stdin -> root-owned file, only when the content differs.
# Returns 2 when it already had that content.
_write_root() {
    local content
    content=$(cat)
    [[ -r "$1" && "$(<"$1")" == "$content" ]] && { success "$1 already set"; return 2; }
    print -ru2 -- "+ write $1:"; print -ru2 -- "$content" | sed 's/^/    /' >&2
    (( dry )) && return 0
    sudo mkdir -p "${1:h}" && print -r -- "$content" | sudo tee "$1" >/dev/null
}

progress "Host: $pm$( (( wsl )) && print -n ", WSL ($WSL_DISTRO_NAME)")$( (( laptop )) && print -n ", laptop")$( (( systemd )) || print -n ", no systemd")"

# --- packages ---------------------------------------------------------------
progress "Distro packages"
if [[ $pm == dnf ]]; then
    # EnMaaS: its LiteLLM proxies run under uv, and its lifecycle code calls lsof
    # shasum (perl-Digest-SHA) and ps (procps-ng), not all in a minimal Fedora.
    _run sudo dnf install -y zsh git gh jq curl python3 unzip iproute nodejs npm libatomic \
        $( (( enmaas )) && print -- lsof uv perl-Digest-SHA procps-ng) || exit 1
else
    _run sudo apt-get update -qq || exit 1
    _run sudo apt-get install -y zsh git gh jq curl python3 unzip iproute2 libatomic1 ca-certificates \
        $( (( enmaas )) && print -- lsof perl procps) || exit 1
    if (( enmaas )) && ! (( $+commands[uv] )) && [[ ! -x ~/.local/bin/uv ]]; then
        # Not packaged for Ubuntu 24.04; astral's installer puts it in ~/.local/bin.
        if (( dry )); then print -ru2 -- "+ curl -LsSf https://astral.sh/uv/install.sh | sh"
        else curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 INSTALLER_NO_MODIFY_PATH=1 sh >/dev/null || exit 1; fi
    fi
    typeset node_v
    node_v=$(node -p 'process.versions.node' 2>/dev/null)
    if [[ -z "$node_v" ]] || ! is-at-least 20.11 "$node_v"; then
        # apt's nodejs is older than t3 accepts (Ubuntu 24.04 ships 18)
        progress "Node ${node_v:-missing} < 20.11: installing Node 22 from NodeSource"
        if (( dry )); then
            print -ru2 -- "+ curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash -"
        else
            curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash - >/dev/null || exit 1
        fi
        _run sudo apt-get install -y nodejs || exit 1
    fi
fi

# --- Claude config (~/.claude) ---------------------------------------------
# Skills, hooks, settings.json, CLAUDE.md, agents: the private
# ${CLAUDE_CONFIG_REPO:-kaovilai/.claude} repo, cloned to ~/.config/claude with
# ~/.claude linked to it, as on the Mac. Before Claude Code first runs, so its
# own default ~/.claude never exists; one that does is moved aside, not merged.
# MCP servers live in ~/.claude.json, which is not in the repo.
typeset claude_repo="${CLAUDE_CONFIG_REPO:-kaovilai/.claude}" claude_dir="$HOME/.config/claude"
if [[ -L ~/.claude && ${${:-$HOME/.claude}:A} == ${claude_dir:A} && -d "$claude_dir/.git" ]]; then
    success "~/.claude links to the $claude_repo clone"
else
    if [[ ! -d "$claude_dir/.git" ]]; then
        if (( ! dry )) && ! gh auth status -h github.com >/dev/null 2>&1; then
            if [[ -t 0 ]]; then
                progress "GitHub login for gh (needed to clone the private $claude_repo)"
                # --insecure-storage: the token goes to ~/.config/gh/hosts.yml
                # (mode 600), not the desktop keyring, which is locked while
                # nobody is logged in -- when fleet-sync's timer fetches this
                # private repo.
                gh auth login -h github.com -p https -w --insecure-storage && gh auth setup-git \
                    || warning "gh login did not finish; rerun this script"
            fi
        fi
        if (( dry )) || gh auth status -h github.com >/dev/null 2>&1; then
            _run gh repo clone "$claude_repo" "$claude_dir" || warning "Could not clone $claude_repo"
        else
            manual+=("Claude config: gh auth login -h github.com -p https -w --insecure-storage && gh auth setup-git, then rerun this script")
        fi
    fi
    if (( dry )) || [[ -d "$claude_dir/.git" ]]; then
        [[ -e ~/.claude && ! -L ~/.claude ]] && _run mv ~/.claude ~/.claude.pre-dotfiles.$(date +%Y%m%d%H%M%S)
        _run ln -sfn "$claude_dir" ~/.claude
    fi
fi

# --- Claude Code, bun -------------------------------------------------------
# On PATH first: .zshrc adds both later, and Claude's installer otherwise
# suggests editing ~/.bashrc.
path=(~/.local/bin ~/.bun/bin $path)
if [[ -x ~/.local/bin/claude ]]; then
    success "Claude Code installed"
else
    progress "Installing Claude Code"
    (( dry )) && print -ru2 -- "+ curl -fsSL https://claude.ai/install.sh | bash" \
        || { curl -fsSL https://claude.ai/install.sh | bash || exit 1; }
fi
if [[ -x ~/.bun/bin/bun ]]; then
    success "bun installed"
else
    progress "Installing bun"
    # SHELL=/bin/sh: the installer appends PATH lines to the rc file of $SHELL,
    # and ~/.zshrc is (or becomes) this repo's .zshrc, which already has them.
    (( dry )) && print -ru2 -- "+ curl -fsSL https://bun.sh/install | SHELL=/bin/sh bash" \
        || { curl -fsSL https://bun.sh/install | SHELL=/bin/sh bash >/dev/null || exit 1; }
fi

# --- Claude plugins ---------------------------------------------------------
progress "Claude plugins from settings.json"
sync-claude-plugins $( (( dry )) && print -- --dry-run)
# User-scope MCP servers live in ~/.claude.json, outside the config repo.
if (( ! $(jq '.mcpServers // {} | length' ~/.claude.json 2>/dev/null || print 0) )); then
    manual+=("MCP servers: none configured here (they live in ~/.claude.json, not the config repo); list them on the Mac with: claude mcp list, re-add with claude mcp add")
fi

# --- shell ------------------------------------------------------------------
[[ ${${:-$HOME/git/dotfiles}:A} == "$root" ]] \
    || warning "This checkout is $root, but .zshrc sources ~/git/dotfiles; clone it there"
if [[ -L ~/.zshrc && ${${:-$HOME/.zshrc}:A} == "$root/.zshrc" ]]; then
    success "~/.zshrc links to this repo"
else
    [[ -e ~/.zshrc && ! -L ~/.zshrc ]] && _run mv ~/.zshrc ~/.zshrc.pre-dotfiles.$(date +%Y%m%d%H%M%S)
    _run ln -sfn "$root/.zshrc" ~/.zshrc
fi
typeset zsh_bin=${commands[zsh]}
if [[ "$(getent passwd "$USER" | cut -d: -f7)" == (/usr|)/bin/zsh ]]; then
    success "Login shell is zsh"
else
    _run sudo usermod -s "$zsh_bin" "$USER" || warning "Could not change the login shell"
fi

# --- copilot-api ------------------------------------------------------------
typeset capi="${COPILOT_API_DIR:-$HOME/git/copilot-api}" capi_home="${COPILOT_API_HOME:-$HOME/.local/share/copilot-api}"
if [[ -d "$capi/.git" ]]; then
    success "copilot-api checkout at $capi"
else
    _run git clone -b dev https://github.com/kaovilai/copilot-api "$capi" || exit 1
fi
if [[ -d "$capi/node_modules" ]]; then
    success "copilot-api dependencies installed"
else
    _run bun install --cwd "$capi" --frozen-lockfile --silent || exit 1
fi
if [[ -s "$capi_home/github_token" ]]; then
    success "copilot-api has a GitHub login"
elif [[ -t 0 ]] && (( ! dry )); then
    progress "copilot-api GitHub device login (open the URL, enter the code)"
    bun run --cwd "$capi" ./src/main.ts auth || warning "GitHub login did not finish; rerun this script"
else
    warning "No copilot-api GitHub login yet"
    manual+=("GitHub login for copilot-api: bun run --cwd $capi ./src/main.ts auth")
fi

# --- EnMaaS (--enmaas) ------------------------------------------------------
# Red Hat's EnMaaS gateway is public; the API key (from Atlas key management,
# which needs the VPN) is what grants access. The launchers read it from
# ~/secrets.zsh. Backends: enmaas (all EnMaaS models) and hosted-only (the
# hosted GLM/DeepSeek models), each for Claude Code and for Codex.
typeset secrets="${CLAUDE_PROVIDER_CREDENTIALS_FILE:-$HOME/secrets.zsh}"
typeset -i enmaas_key=0
if (( enmaas )); then
    progress "EnMaaS"
    if zsh -fc 'source "$1" >/dev/null 2>&1; [[ -n "${ENMAAS_API_KEY-}" && -n "${ENMAAS_API_BASE_URL-}" ]]' _ "$secrets"; then
        success "EnMaaS key in $secrets"; enmaas_key=1
    elif [[ -t 0 ]] && (( ! dry )); then
        typeset key
        read -rs "key?EnMaaS API key (input hidden, empty to skip): " && print
        if [[ -n "$key" ]]; then
            ( umask 077; [[ -e "$secrets" ]] || : > "$secrets"; chmod 600 "$secrets"
              print -r -- "export ENMAAS_API_BASE_URL=${ENMAAS_API_BASE_URL:-https://api.enmaas.devshift.net}" >> "$secrets"
              print -r -- "export ENMAAS_API_KEY=${(qq)key}" >> "$secrets" ) && { success "Saved to $secrets (mode 600)"; enmaas_key=1; }
        fi
        unset key
    fi
    (( enmaas_key )) || manual+=("EnMaaS key: put export ENMAAS_API_BASE_URL=https://api.enmaas.devshift.net and export ENMAAS_API_KEY=... in $secrets (mode 600), then rerun with --enmaas")
    if [[ -x ~/.local/bin/codex ]]; then
        success "Codex CLI installed ($(~/.local/bin/codex --version 2>/dev/null))"
    else
        _run npm i -g --prefix ~/.local @openai/codex || warning "Could not install the Codex CLI"
    fi
    # Download the pinned LiteLLM once now: on a cold uv cache the first proxy
    # boot spends its whole startup timeout downloading ~110 packages and fails.
    typeset lv fv
    lv=$(grep -o 'CLAUDE_OPENAI_PROXY_LITELLM_VERSION:-[0-9.]*' "$root/zsh/functions/claude/providers/enmaas.zsh" | head -1 | cut -d- -f2)
    fv=$(grep -o 'CLAUDE_OPENAI_PROXY_FASTAPI_VERSION:-[0-9.]*' "$root/zsh/functions/claude/providers/enmaas.zsh" | head -1 | cut -d- -f2)
    if [[ -n "$lv" && -n "$fv" ]]; then
        _run uv tool run --with "fastapi==$fv" --from "litellm[proxy]==$lv" litellm --version >/dev/null \
            || warning "Could not pre-download LiteLLM $lv; the first EnMaaS start may time out once"
    fi
fi

# --- launchers --------------------------------------------------------------
typeset -a claude_backends=(copilot) codex_backends=()
(( enmaas )) && { claude_backends+=(enmaas hosted-only); codex_backends=(enmaas hosted-only); }
progress "Launchers: claude-t3-{${(j:,:)claude_backends}}$( (( ${#codex_backends} )) && print -n " codex-t3-{${(j:,:)codex_backends}}")"
if (( dry )); then
    print -ru2 -- "+ link-claude-t3-launchers $claude_backends"
    (( ${#codex_backends} )) && print -ru2 -- "+ link-codex-t3-launchers $codex_backends"
else
    link-claude-t3-launchers $claude_backends || exit 1
    if (( ${#codex_backends} )); then link-codex-t3-launchers $codex_backends || exit 1; fi
fi

# --- t3 ---------------------------------------------------------------------
if [[ -x ~/.local/bin/t3 ]]; then
    success "t3 installed ($(~/.local/bin/t3 --version 2>/dev/null || print -n 'does not start'))"
else
    _run npm i -g --prefix ~/.local t3@latest || exit 1
fi
# Provider instances exported from the Mac (t3/provider-instances.json), for
# the launchers linked above; then a plain claude_copilot if none came along.
import-t3-providers $( (( dry )) && print -- --dry-run)
typeset settings="${T3CODE_HOME:-$HOME/.t3}/userdata/settings.json"
if [[ -r "$settings" ]] && jq -e '.providerInstances | any(.config.binaryPath? // "" | endswith("/claude-t3-copilot"))' "$settings" >/dev/null 2>&1; then
    success "T3 provider instance claude_copilot present"
else
    progress "Adding T3 provider instance claude_copilot to $settings"
    if (( ! dry )); then
        typeset instance
        instance=$(jq -nc --arg bin "$HOME/.local/bin/claude-t3-copilot" \
            '{driver: "claudeAgent", displayName: "Claude · Copilot", enabled: true, environment: [],
              config: {binaryPath: $bin, customModels: []}}') || exit 1
        mkdir -p "${settings:h}" || exit 1
        { [[ -r "$settings" ]] && cat "$settings" || print '{}'; } |
            jq --argjson i "$instance" '.providerInstances.claude_copilot = $i' > "$settings.tmp" &&
            mv "$settings.tmp" "$settings" || { error "Could not update $settings"; exit 1; }
    fi
fi

# --- WSL: systemd -----------------------------------------------------------
if (( wsl )) && ! grep -qsE '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true' /etc/wsl.conf; then
    if grep -qs '^\[boot\]' /etc/wsl.conf; then
        warning "/etc/wsl.conf has a [boot] section without systemd=true; add it there"
    else
        progress "Enabling systemd in /etc/wsl.conf"
        if (( dry )); then print -ru2 -- "+ append [boot] systemd=true to /etc/wsl.conf"
        else printf '\n[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null; fi
    fi
    manual+=("From Windows PowerShell: wsl --shutdown, then reopen the distro and rerun this script")
fi

# --- background service -----------------------------------------------------
if (( systemd )); then
    if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" == yes ]]; then
        success "Lingering enabled"
    else
        _run sudo loginctl enable-linger "$USER" || warning "Could not enable lingering"
    fi
    if systemctl --user is-active --quiet t3code.service 2>/dev/null; then
        success "t3code.service active"
    else
        _run ~/.local/bin/t3 service install || warning "t3 service install failed"
    fi
else
    warning "systemd is not running; skipping the T3 background service"
fi

# --- Tailscale --------------------------------------------------------------
# Optional path to the phone besides T3 Connect: `t3 pair --tailscale` publishes
# the server with Tailscale Serve. On Linux only root or tailscaled's operator
# may change serve config, and t3 runs it as you, hence --operator.
typeset ts_up=0
if (( tailscale )); then
    if (( $+commands[tailscale] )); then
        success "Tailscale installed"
    else
        progress "Installing Tailscale"
        if (( dry )); then
            print -ru2 -- "+ curl -fsSL https://tailscale.com/install.sh | sh"
        else
            # The installer ends by enabling tailscaled, which fails while
            # systemd is off (a first WSL run); the package itself is in.
            curl -fsSL https://tailscale.com/install.sh | sh
            rehash
            (( $+commands[tailscale] )) || { error "Tailscale install failed"; exit 1; }
        fi
    fi
    if (( ! systemd )); then
        warning "systemd is not running; tailscaled not started (rerun once it is)"
    else
        if systemctl is-active --quiet tailscaled 2>/dev/null && [[ "$(systemctl is-enabled tailscaled 2>/dev/null)" == enabled ]]; then
            success "tailscaled running"
        else
            _run sudo systemctl enable --now tailscaled || warning "Could not start tailscaled"
        fi
        if (( ! dry )) && [[ "$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty')" != Running ]]; then
            if [[ -t 0 ]]; then
                progress "Tailscale login (open the URL it prints)"
                sudo tailscale up || warning "Tailscale login did not finish; rerun this script"
            else
                manual+=("Connect Tailscale: sudo tailscale up   (then rerun this script to finish)")
            fi
        fi
        if (( ! dry )) && [[ "$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty')" == Running ]]; then
            ts_up=1
            _run sudo tailscale set --operator="$USER" || warning "Could not make $USER the Tailscale operator"
            success "Tailscale connected as $(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')"
        fi
    fi
fi

# --- EnMaaS check ------------------------------------------------------------
# --prepare starts each backend's local proxy and fetches its model catalog
# with the key, without sending a prompt: proof the key and network work.
if (( enmaas && enmaas_key && ! dry )); then
    typeset b out
    for b in enmaas hosted-only; do
        if out=$(cd ~ && timeout 300 ~/.local/bin/claude-t3-$b --prepare 2>&1); then
            success "claude-t3-$b ready"
        else
            warning "claude-t3-$b --prepare failed: ${${(f)out}[-1]}"
        fi
    done
fi

# --- fleet-sync timer --------------------------------------------------------
# Hourly fast-forward of the dotfiles, Claude config and copilot-api checkouts.
if (( systemd )); then
    if systemctl --user is-enabled --quiet fleet-sync.timer 2>/dev/null; then
        success "fleet-sync.timer enabled"
    else
        _run zsh "$root/scripts/fleet-sync.zsh" --install-timer || warning "Could not install fleet-sync.timer"
    fi
fi

# --- laptop power -----------------------------------------------------------
if (( laptop && power )); then
    progress "Laptop: stay up with the lid closed on AC"
    _write_root /etc/systemd/logind.conf.d/90-t3-lid.conf <<'EOF'
[Login]
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
    (( $? == 0 )) && manual+=("Reboot once so logind applies the lid setting")
    if [[ -d /etc/dconf/profile ]] && (( $+commands[dconf] )); then
        _write_root /etc/dconf/db/gdm.d/95-t3-no-suspend <<'EOF'
[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
EOF
        _run sudo dconf update
    else
        warning "No dconf (GNOME not installed?); skipping the login-screen idle setting"
    fi
    if (( $+commands[gsettings] )); then
        if [[ -n "${DBUS_SESSION_BUS_ADDRESS-}" ]]; then
            _run gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type nothing
        elif (( $+commands[dbus-run-session] )); then
            # No session bus over SSH; dconf writes through one.
            _run dbus-run-session -- gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type nothing
        fi
    fi
    if (( systemd )) && systemctl list-unit-files sshd.service >/dev/null 2>&1; then
        [[ "$(systemctl is-enabled sshd 2>/dev/null)" == enabled ]] && success "sshd enabled" \
            || _run sudo systemctl enable --now sshd
    else
        manual+=("Install and enable an SSH server for maintenance: sudo $pm install openssh-server && sudo systemctl enable --now sshd")
    fi
    if (( $+commands[nmcli] )); then
        typeset name type
        while IFS=: read -r name type; do
            [[ "$type" == 802-11-wireless ]] || continue
            [[ -z "$(nmcli -g connection.permissions connection show "$name" 2>/dev/null)" \
                && "$(nmcli -g 802-11-wireless-security.psk-flags connection show "$name" 2>/dev/null)" == (0|) ]] && continue
            manual+=("Wi-Fi up before login: sudo nmcli connection modify '$name' connection.permissions '' 802-11-wireless-security.psk-flags 0 802-11-wireless-security.psk '<password>'")
        done < <(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null)
    fi
    if lsblk -rno TYPE 2>/dev/null | grep -qx crypt && ! grep -qs tpm2-device /etc/crypttab; then
        manual+=("Encrypted disk: TPM2 unlock so reboots don't wait for the passphrase (docs/LAPTOP_MIGRATION.md, Lid-closed Fedora laptop)")
    fi
fi

if (( wsl )); then
    manual+=("Windows side, so WSL runs at boot with nobody signed in: scheduled task + powercfg in docs/LAPTOP_MIGRATION.md (Headless host, WSL2). Distro name: ${WSL_DISTRO_NAME:-<distro>}")
fi
if (( ts_up )); then
    manual+=("Pair your phone over the tailnet: t3 pair --tailscale   (the phone needs Tailscale too; plain t3 pair goes through T3 Connect)")
else
    manual+=("Pair your phone: t3 pair")
fi

# --- result -----------------------------------------------------------------
if (( dry )); then
    progress "Dry run: nothing changed"
else
    progress "Checking"
    verify-t3-headless
fi
if (( ${#manual} )); then
    print
    progress "Left for you:"
    typeset m
    for m in $manual; do print -r -- "  - $m"; done
fi
