#!/usr/bin/env zsh

# T3 Code migration functions
# Moves T3 Code threads, projects, settings, and pairing data to a new laptop.
#
# What is migrated:
#   $T3CODE_HOME/userdata  settings, keybindings, themes, providers, secrets/,
#                          clerk-tokens.json, attachments, browser-artifacts, and
#                          the state*.sqlite databases (threads, projects,
#                          auth_pairing_links, auth_sessions)
#   $T3CODE_HOME/dev       dev-build state (same layout, smaller)
#   ~/Library/Application Support/t3code{,-v2}
#                          Electron UI storage (Local Storage, IndexedDB)
#
# Skipped (rebuilt by the app): logs, server-browser, usage caches, bin, tools,
# caches, scratch, and worktrees (recreate those from their branches).
#
# Electron cookies are encrypted with the "t3code Safe Storage" keychain item,
# which is not migrated, so expect to sign in again and re-pair devices that
# fail to reconnect.
#
# The SQLite databases are copied with `sqlite3 .backup`, which takes a
# consistent snapshot even while T3 Code is running. Row counts of every table
# are recorded in the manifest and compared on import, so a missing thread
# shows up as a count mismatch.
#
# Not in the archive or in git: the ~/.local/bin/claude-t3-<backend> launchers
# that T3 Code's Claude provider instances run. link-claude-t3-launchers
# recreates them and verify-claude-t3-launchers checks them.

: ${T3CODE_HOME:=$HOME/.t3}
: ${T3_APPSUPPORT_DIR:=$HOME/Library/Application Support}
: ${T3_CLAUDE_LAUNCHER_DIR:=$HOME/.local/bin}

# Subdirectories of $T3CODE_HOME that hold state worth migrating
typeset -ga _T3_STATE_DIRS=(userdata dev)

# Electron profile dirs under $T3_APPSUPPORT_DIR
typeset -ga _T3_ELECTRON_DIRS=(t3code-v2 t3code)

# Dotfiles checkout this file lives in (zsh/functions/t3-migrate.zsh)
typeset -g _T3_DOTFILES_ROOT=${${(%):-%x}:A:h:h:h}

# Each claude-t3-<backend> launcher is a symlink to scripts/claude-provider.zsh,
# which takes its backend from the link name. Keep this list in sync with the
# backends that script accepts. glm-hybrid / glm-only are retired names of
# hosted-only, still linked because T3 settings.json may reference them.
typeset -ga _T3_CLAUDE_BACKENDS=(copilot vertex openai enmaas hosted-only glm-hybrid glm-only)

# Each codex-t3-<backend> launcher is a symlink to scripts/codex-provider.zsh,
# same link-name dispatch. Keep this list in sync with the backends that
# script accepts.
typeset -ga _T3_CODEX_BACKENDS=(enmaas hosted-only glm-hybrid glm-only)

# Pre-rename launcher names (enmass -> enmaas). Linked, not verified: exported
# T3 settings.json files still point at claude-t3-enmass / codex-t3-enmass.
typeset -ga _T3_LEGACY_BACKENDS=(enmass)

_t3_userdata_excludes=(
    --exclude='logs/'
    --exclude='server-browser/'
    --exclude='usage-scan-cache.json'
    --exclude='usage-model-rates.json'
    --exclude='*.sqlite'
    --exclude='*.sqlite-wal'
    --exclude='*.sqlite-shm'
)

_t3_electron_excludes=(
    --exclude='Cache/'
    --exclude='Code Cache/'
    --exclude='GPUCache/'
    --exclude='GPUPersistentCache/'
    --exclude='DawnGraphiteCache/'
    --exclude='DawnWebGPUCache/'
    --exclude='GraphiteDawnCache/'
)

# Print "<table> <rowcount>" for every table in a SQLite database
_t3_table_counts() {
    local db="$1" table
    for table in $(sqlite3 -readonly "$db" "select name from sqlite_master where type='table' order by name"); do
        echo "$table $(sqlite3 -readonly "$db" "select count(*) from \"$table\"")"
    done
}

_t3_app_running() {
    pgrep -f 'T3 Code.*\.app/Contents/MacOS/T3 Code' >/dev/null 2>&1
}

# Set T3_MIGRATE_PASSPHRASE to skip openssl's interactive passphrase prompt
_t3_openssl_pass_args() {
    reply=()
    [[ -n "$T3_MIGRATE_PASSPHRASE" ]] && reply=(-pass env:T3_MIGRATE_PASSPHRASE)
}

# Export T3 Code data to an encrypted archive
export-t3-data() {
    local ts=${(%):-%D{%Y%m%d-%H%M%S}}
    local dest="${1:-$HOME/t3-code-migration-$ts.tar.gz.enc}"

    local cmd
    for cmd in sqlite3 rsync openssl; do
        command_exists $cmd || { error "$cmd not found"; return 1; }
    done
    [[ -d "$T3CODE_HOME/userdata" ]] || { error "No T3 Code data at $T3CODE_HOME/userdata"; return 1; }
    [[ -e "$dest" ]] && { error "$dest already exists"; return 1; }

    if _t3_app_running; then
        warning "T3 Code is running. Databases are snapshotted safely, but quit the app for a clean copy of UI storage."
    fi

    local staging
    staging=$(mktemp -d) || return 1
    local root="$staging/t3-migration"
    mkdir -p "$root/home" "$root/appsupport"

    local manifest="$root/MANIFEST.txt"
    {
        echo "T3 Code migration export"
        echo "created $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "host $HOST"
        echo "home $HOME"
        echo "t3code_home $T3CODE_HOME"
        if [[ -r /Applications/T3\ Code\ \(Alpha\).app/Contents/Info.plist ]]; then
            echo "app_version $(defaults read '/Applications/T3 Code (Alpha).app/Contents/Info' CFBundleShortVersionString 2>/dev/null)"
        fi
    } > "$manifest"

    local dir db rel
    for dir in $_T3_STATE_DIRS; do
        [[ -d "$T3CODE_HOME/$dir" ]] || continue
        progress "Copying $T3CODE_HOME/$dir..."
        mkdir -p "$root/home/$dir"
        rsync -a $_t3_userdata_excludes "$T3CODE_HOME/$dir/" "$root/home/$dir/" \
            || { error "rsync of $dir failed"; rm -rf "$staging"; return 1; }

        for db in "$T3CODE_HOME/$dir"/*.sqlite(N); do
            rel="$dir/${db:t}"
            progress "Snapshotting $rel..."
            sqlite3 -readonly "$db" ".backup '$root/home/$rel'" \
                || { error "sqlite backup of $rel failed"; rm -rf "$staging"; return 1; }
            # The snapshot inherits WAL mode, which can't be opened read-only
            # without its -shm file; a rollback journal keeps it self-contained
            sqlite3 "$root/home/$rel" 'pragma journal_mode=delete' >/dev/null
            _t3_table_counts "$root/home/$rel" | sed "s|^|count $rel |" >> "$manifest"
        done
    done

    for dir in $_T3_ELECTRON_DIRS; do
        [[ -d "$T3_APPSUPPORT_DIR/$dir" ]] || continue
        progress "Copying UI storage $dir..."
        rsync -a $_t3_electron_excludes "$T3_APPSUPPORT_DIR/$dir/" "$root/appsupport/$dir/" \
            || warning "rsync of $dir had errors (app running?)"
    done

    chmod -R go-rwx "$root"

    progress "Encrypting archive (choose a passphrase you will enter on the new laptop)..."
    local -a reply
    _t3_openssl_pass_args
    tar -C "$staging" -czf - t3-migration \
        | openssl enc -aes-256-cbc -pbkdf2 -salt $reply -out "$dest"
    local -a rcs=($pipestatus)
    rm -rf "$staging"
    if (( rcs[1] != 0 || rcs[2] != 0 )); then
        rm -f "$dest"
        error "Encryption failed"
        return 1
    fi
    chmod 600 "$dest"

    success "T3 Code data exported to $dest"
    echo "Contains signing keys and auth tokens: transfer it privately (AirDrop/USB)."
    echo "On the new laptop: import-t3-data $dest"
}

# Import T3 Code data from an archive made by export-t3-data
import-t3-data() {
    local archive="$1"
    [[ -f "$archive" ]] || { error "Usage: import-t3-data <archive.tar.gz.enc>"; return 1; }

    local cmd
    for cmd in sqlite3 rsync openssl; do
        command_exists $cmd || { error "$cmd not found"; return 1; }
    done
    if _t3_app_running; then
        error "Quit T3 Code before importing"
        return 1
    fi

    local staging
    staging=$(mktemp -d) || return 1
    progress "Decrypting $archive..."
    local -a reply
    _t3_openssl_pass_args
    openssl enc -d -aes-256-cbc -pbkdf2 $reply -in "$archive" \
        | tar -C "$staging" -xzf -
    if (( pipestatus[1] != 0 || pipestatus[2] != 0 )); then
        error "Decryption failed (wrong passphrase?)"
        rm -rf "$staging"
        return 1
    fi

    local root="$staging/t3-migration"
    local manifest="$root/MANIFEST.txt"
    [[ -f "$manifest" ]] || { error "Archive has no MANIFEST.txt"; rm -rf "$staging"; return 1; }

    local old_home
    old_home=$(awk '$1 == "home" {print $2}' "$manifest")
    if [[ -n "$old_home" && "$old_home" != "$HOME" ]]; then
        warning "Home changed: $old_home -> $HOME"
        warning "Threads still import, but projects pointing at $old_home paths must be re-added or the old path symlinked."
    fi

    local ts=${(%):-%D{%Y%m%d-%H%M%S}}
    local dir
    mkdir -p "$T3CODE_HOME"
    for dir in $_T3_STATE_DIRS; do
        [[ -d "$root/home/$dir" ]] || continue
        if [[ -e "$T3CODE_HOME/$dir" ]]; then
            progress "Moving existing $T3CODE_HOME/$dir to $dir.pre-import-$ts"
            mv "$T3CODE_HOME/$dir" "$T3CODE_HOME/$dir.pre-import-$ts" || { rm -rf "$staging"; return 1; }
        fi
        progress "Restoring $T3CODE_HOME/$dir..."
        rsync -a "$root/home/$dir/" "$T3CODE_HOME/$dir/" || { error "Restore of $dir failed"; rm -rf "$staging"; return 1; }
    done

    if [[ -d "$T3CODE_HOME/userdata/secrets" ]]; then
        chmod 700 "$T3CODE_HOME/userdata/secrets"
        chmod 600 "$T3CODE_HOME/userdata/secrets"/*(N)
    fi
    [[ -f "$T3CODE_HOME/userdata/clerk-tokens.json" ]] && chmod 600 "$T3CODE_HOME/userdata/clerk-tokens.json"

    mkdir -p "$T3_APPSUPPORT_DIR"
    for dir in $_T3_ELECTRON_DIRS; do
        [[ -d "$root/appsupport/$dir" ]] || continue
        if [[ -e "$T3_APPSUPPORT_DIR/$dir" ]]; then
            mv "$T3_APPSUPPORT_DIR/$dir" "$T3_APPSUPPORT_DIR/$dir.pre-import-$ts" || { rm -rf "$staging"; return 1; }
        fi
        progress "Restoring UI storage $dir..."
        rsync -a "$root/appsupport/$dir/" "$T3_APPSUPPORT_DIR/$dir/" || warning "Restore of $dir had errors"
    done

    cp "$manifest" "$T3CODE_HOME/userdata/migration-manifest.txt"
    rm -rf "$staging"

    success "T3 Code data restored"
    verify-t3-migration "$T3CODE_HOME/userdata/migration-manifest.txt"
}

# Verify T3 Code data; with a manifest, check every table's row count matches
verify-t3-migration() {
    local manifest="${1:-$T3CODE_HOME/userdata/migration-manifest.txt}"
    local failed=0

    if [[ -d /Applications/T3\ Code\ \(Alpha\).app ]] || [[ -d /Applications/T3\ Code.app ]]; then
        success "T3 Code app installed"
    else
        warning "T3 Code app not installed (brew install --cask t3-code)"
    fi

    local f
    for f in server-signing-key.bin cloud-link-ed25519-key-pair.bin; do
        if [[ -f "$T3CODE_HOME/userdata/secrets/$f" ]]; then
            success "secrets/$f present"
        else
            error "secrets/$f missing"
            failed=1
        fi
    done

    local db rel
    for db in "$T3CODE_HOME"/${^_T3_STATE_DIRS}/*.sqlite(N); do
        rel="${db#$T3CODE_HOME/}"
        if [[ "$(sqlite3 -readonly "$db" 'pragma integrity_check')" == ok ]]; then
            success "$rel integrity ok"
        else
            error "$rel integrity check failed"
            failed=1
        fi
    done

    # Reported but not counted: a missing tool doesn't mean the imported data
    # is wrong. verify-migration checks provider binaries on their own.
    _t3_check_provider_binaries warning

    if [[ -f "$manifest" ]]; then
        local _count table expected actual
        local -i checked=0 mismatched=0
        while read -r _count rel table expected; do
            [[ "$_count" == count ]] || continue
            (( checked++ ))
            actual=$(sqlite3 -readonly "$T3CODE_HOME/$rel" "select count(*) from \"$table\"" 2>/dev/null)
            if [[ "$actual" != "$expected" ]]; then
                error "$rel $table: expected $expected rows, found ${actual:-none}"
                (( mismatched++ ))
            fi
        done < "$manifest"
        if (( mismatched == 0 )); then
            success "All $checked tables match the export row counts"
        else
            failed=1
        fi
    fi

    local threads pairings
    for db in "$T3CODE_HOME"/${^_T3_STATE_DIRS}/*.sqlite(N); do
        rel="${db#$T3CODE_HOME/}"
        threads=$(sqlite3 -readonly "$db" "select count(*) from orchestration_v2_projection_threads" 2>/dev/null) \
            || threads=$(sqlite3 -readonly "$db" "select count(*) from projection_threads" 2>/dev/null)
        pairings=$(sqlite3 -readonly "$db" "select count(*) from auth_pairing_links" 2>/dev/null)
        echo "  $rel: ${threads:-0} threads, ${pairings:-0} pairing links"
    done

    return $failed
}

# Provider binaryPaths in settings.json are absolute, so a launcher that was
# never linked, or a home directory that changed, leaves that provider unable
# to start. Disabled instances never start and bare command names resolve
# through the app's PATH, so both are skipped. $1 is the reporter for missing
# binaries (error by default); the return status is 1 either way.
_t3_check_provider_binaries() {
    local report="${1:-error}"
    local settings="$T3CODE_HOME/userdata/settings.json"
    [[ -f "$settings" ]] || return 0
    if ! command_exists jq; then
        warning "jq not found; skipping provider binary checks"
        return 0
    fi

    local bins bin hint failed=0
    bins=$(jq -r '[.providerInstances[]? | select(.enabled != false) | .config.binaryPath? // empty] | unique[]' "$settings") \
        || { error "Could not read provider binaries from $settings"; return 1; }
    for bin in ${(f)bins}; do
        [[ "$bin" == /* ]] || continue
        if [[ -x "$bin" ]]; then
            success "Provider binary $bin"
            continue
        fi
        hint="install it, or fix binaryPath in settings.json"
        case "${bin:t}" in
            claude-t3-*) hint="run link-claude-t3-launchers, or fix binaryPath in settings.json if your home path changed" ;;
            codex-t3-*)  hint="run link-codex-t3-launchers, or fix binaryPath in settings.json if your home path changed" ;;
        esac
        $report "Provider binary $bin missing ($hint)"
        failed=1
    done
    return $failed
}

# _t3_check_backend_args <kind> <known...> -- <requested...>: error on any
# requested backend not in the known list.
_t3_check_backend_args() {
    local kind="$1"; shift
    local -a known=(${@[1,${@[(i)--]}-1]}) requested=(${@[${@[(i)--]}+1,-1]})
    local b bad=0
    for b in $requested; do
        (( ${known[(Ie)$b]} )) || { error "Unknown $kind-t3 backend '$b' (choose: $known)"; bad=1; }
    done
    return $bad
}

# What the launchers need at run time that neither git nor the T3 archive
# carries. Warnings only: each backend needs a different subset. Args: the
# backends being linked.
_t3_claude_launcher_prereqs() {
    local native="${CLAUDE_PROVIDER_NATIVE_BINARY:-$HOME/.local/bin/claude}"
    [[ -x "$native" ]] \
        || warning "Claude Code not found at $native (install: curl -fsSL https://claude.ai/install.sh | bash)"

    # python3 + jq: every backend. uv: the LiteLLM proxies (vertex, openai,
    # enmaas, hosted-only). bun + a copilot-api checkout: copilot.
    local -a cmds=(python3 jq)
    (( ${@[(I)copilot]} )) && cmds+=(bun)
    (( ${#${@:#copilot}} )) && cmds+=(uv)
    local cmd hint="brew bundle --file=$_T3_DOTFILES_ROOT/Brewfile"
    [[ "$OSTYPE" == darwin* ]] || hint="install it with your package manager; bun: curl -fsSL https://bun.sh/install | bash"
    for cmd in $cmds; do
        # Under WSL the appended Windows PATH can supply a /mnt/c/... program
        # of the same name, which can't serve these Linux launchers.
        if [[ "${commands[$cmd]-}" == /mnt/[a-z]/* ]]; then
            [[ $cmd == bun && -x $HOME/.bun/bin/bun ]] \
                || warning "$cmd resolves to Windows' ${commands[$cmd]}; install the Linux one inside WSL ($hint)"
        else
            command_exists $cmd || [[ $cmd == bun && -x $HOME/.bun/bin/bun ]] || warning "$cmd not found ($hint)"
        fi
    done
    local repo_dir="${COPILOT_API_DIR:-$HOME/git/copilot-api}" d
    if (( ${@[(I)copilot]} )) && [[ ! -d "$repo_dir/.git" ]]; then
        warning "copilot-api checkout missing (git clone -b dev https://github.com/kaovilai/copilot-api $repo_dir)"
    fi
    # WSL: checkouts on the Windows drive are slow, lose exec bits, and get
    # CRLF line endings from Windows git.
    local -a dirs=("$_T3_DOTFILES_ROOT")
    (( ${@[(I)copilot]} )) && dirs+=("$repo_dir")
    for d in $dirs; do
        [[ "${d:A}" == /mnt/[a-z]/* ]] && warning "$d is on the Windows drive; clone it inside the Linux filesystem (e.g. ~/git) instead"
    done

    # copilot authenticates with copilot-api's own GitHub token, not secrets.zsh.
    local credentials="${CLAUDE_PROVIDER_CREDENTIALS_FILE:-$HOME/secrets.zsh}"
    (( ${#${@:#copilot}} )) && [[ ! -r "$credentials" ]] \
        && warning "$credentials not found; the launchers read provider keys from it (see docs/LAPTOP_MIGRATION.md)"
    return 0
}

# Point each claude-t3-<backend> launcher at this checkout's
# scripts/claude-provider.zsh. Existing symlinks are repointed; anything else
# at a launcher path is left alone and reported. Backend args limit it to a
# subset, e.g. `link-claude-t3-launchers copilot` on a machine without EnMaaS
# or Vertex access; none = every backend plus the legacy names.
link-claude-t3-launchers() {
    local target="$_T3_DOTFILES_ROOT/scripts/claude-provider.zsh"
    [[ -x "$target" ]] || { error "Launcher script missing or not executable: $target"; return 1; }
    local -a backends=("$@")
    (( $# )) || backends=($_T3_CLAUDE_BACKENDS $_T3_LEGACY_BACKENDS)
    _t3_check_backend_args claude $_T3_CLAUDE_BACKENDS $_T3_LEGACY_BACKENDS -- $backends || return 1
    mkdir -p "$T3_CLAUDE_LAUNCHER_DIR" || { error "Failed to create $T3_CLAUDE_LAUNCHER_DIR"; return 1; }

    local backend link failed=0
    for backend in $backends; do
        link="$T3_CLAUDE_LAUNCHER_DIR/claude-t3-$backend"
        if [[ -L "$link" && "${link:A}" == "${target:A}" ]]; then
            success "claude-t3-$backend already linked"
        elif [[ -e "$link" && ! -L "$link" ]]; then
            error "$link exists and is not a symlink; leaving it untouched"
            failed=1
        elif ln -sfn "$target" "$link"; then
            success "Linked $link -> $target"
        else
            error "Failed to link $link"
            failed=1
        fi
    done

    _t3_claude_launcher_prereqs $backends
    return $failed
}

# Check each launcher resolves to this checkout and starts Claude Code.
# `--version` skips credentials and proxies, so this is safe to run any time.
# Backend args limit the check like link-claude-t3-launchers.
verify-claude-t3-launchers() {
    local target="$_T3_DOTFILES_ROOT/scripts/claude-provider.zsh"
    local -a backends=("$@")
    (( $# )) || backends=($_T3_CLAUDE_BACKENDS)
    _t3_check_backend_args claude $_T3_CLAUDE_BACKENDS $_T3_LEGACY_BACKENDS -- $backends || return 1
    local backend link failed=0
    for backend in $backends; do
        link="$T3_CLAUDE_LAUNCHER_DIR/claude-t3-$backend"
        if [[ ! -L "$link" || "${link:A}" != "${target:A}" ]]; then
            error "claude-t3-$backend is not linked to $target (run link-claude-t3-launchers)"
            failed=1
        elif ! "$link" --version >/dev/null 2>&1; then
            error "claude-t3-$backend --version failed (is Claude Code installed?)"
            failed=1
        else
            success "claude-t3-$backend starts Claude Code"
        fi
    done
    return $failed
}

# What the codex launchers need at run time that neither git nor the T3
# archive carries. Warnings only.
_t3_codex_launcher_prereqs() {
    local native="${CODEX_PROVIDER_NATIVE_BINARY:-$HOME/.local/bin/codex}"
    [[ -x "$native" ]] \
        || warning "Codex CLI not found at $native (install: npm i -g @openai/codex, or codex update for the standalone tree)"

    local credentials="${CLAUDE_PROVIDER_CREDENTIALS_FILE:-$HOME/secrets.zsh}"
    [[ -r "$credentials" ]] \
        || warning "$credentials not found; the launchers read provider keys from it (see docs/LAPTOP_MIGRATION.md)"
}

# Point each codex-t3-<backend> launcher at this checkout's
# scripts/codex-provider.zsh. Existing symlinks are repointed; anything else
# at a launcher path is left alone and reported. Backend args limit it to a
# subset, like link-claude-t3-launchers.
link-codex-t3-launchers() {
    local target="$_T3_DOTFILES_ROOT/scripts/codex-provider.zsh"
    [[ -x "$target" ]] || { error "Launcher script missing or not executable: $target"; return 1; }
    local -a backends=("$@")
    (( $# )) || backends=($_T3_CODEX_BACKENDS $_T3_LEGACY_BACKENDS)
    _t3_check_backend_args codex $_T3_CODEX_BACKENDS $_T3_LEGACY_BACKENDS -- $backends || return 1
    mkdir -p "$T3_CLAUDE_LAUNCHER_DIR" || { error "Failed to create $T3_CLAUDE_LAUNCHER_DIR"; return 1; }

    local backend link failed=0
    for backend in $backends; do
        link="$T3_CLAUDE_LAUNCHER_DIR/codex-t3-$backend"
        if [[ -L "$link" && "${link:A}" == "${target:A}" ]]; then
            success "codex-t3-$backend already linked"
        elif [[ -e "$link" && ! -L "$link" ]]; then
            error "$link exists and is not a symlink; leaving it untouched"
            failed=1
        elif ln -sfn "$target" "$link"; then
            success "Linked $link -> $target"
        else
            error "Failed to link $link"
            failed=1
        fi
    done

    _t3_codex_launcher_prereqs
    return $failed
}

# Check each codex launcher resolves to this checkout and starts the Codex
# CLI. `--version` skips credentials, so this is safe to run any time.
verify-codex-t3-launchers() {
    local target="$_T3_DOTFILES_ROOT/scripts/codex-provider.zsh"
    local -a backends=("$@")
    (( $# )) || backends=($_T3_CODEX_BACKENDS)
    _t3_check_backend_args codex $_T3_CODEX_BACKENDS $_T3_LEGACY_BACKENDS -- $backends || return 1
    local backend link failed=0
    for backend in $backends; do
        link="$T3_CLAUDE_LAUNCHER_DIR/codex-t3-$backend"
        if [[ ! -L "$link" || "${link:A}" != "${target:A}" ]]; then
            error "codex-t3-$backend is not linked to $target (run link-codex-t3-launchers)"
            failed=1
        elif ! "$link" --version >/dev/null 2>&1; then
            error "codex-t3-$backend --version failed (is the Codex CLI installed?)"
            failed=1
        else
            success "codex-t3-$backend starts the Codex CLI"
        fi
    done
    return $failed
}

# Check a Linux or WSL2 box serving T3 Code headless on Copilot: the T3
# background service (`t3 service install`, a systemd user unit) runs at boot
# with nobody logged in, and its Claude provider runs claude-t3-copilot.
# Inside WSL only the Linux side can be checked; the Windows side that boots
# the distro is in docs/LAPTOP_MIGRATION.md.
verify-t3-headless() {
    [[ "$OSTYPE" == linux* ]] || { error "verify-t3-headless is for Linux hosts (Fedora, or a WSL2 distro)"; return 1; }
    local failed=0 wsl=0 unit=t3code.service
    [[ -n "${WSL_DISTRO_NAME-}" ]] && wsl=1

    if [[ -d /run/systemd/system ]]; then
        success "systemd is running"
    elif (( wsl )); then
        error "systemd is not running: add [boot] systemd=true to /etc/wsl.conf, then run wsl --shutdown from Windows"
        failed=1
    else
        error "systemd is not running; t3 service needs a systemd user manager"
        failed=1
    fi

    # Without lingering the user manager, and the service, stop at logout and
    # don't start at boot.
    if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" == yes ]]; then
        success "Lingering enabled for $USER"
    else
        error "Lingering is off: sudo loginctl enable-linger $USER"
        failed=1
    fi

    if ! command_exists t3; then
        error "t3 not installed (npm i -g --prefix ~/.local t3@latest)"
        failed=1
    elif ! t3 --version >/dev/null 2>&1; then
        # The downloaded runtime links libatomic, absent from minimal installs.
        error "t3 does not start: $(t3 --version 2>&1 | head -1) (libatomic missing? Fedora: libatomic, Ubuntu: libatomic1)"
        failed=1
    elif systemctl --user is-active --quiet "$unit" 2>/dev/null; then
        success "$unit active ($(t3 --version 2>/dev/null))"
    else
        error "$unit not active (t3 service install; logs: systemctl --user status $unit)"
        failed=1
    fi

    verify-claude-t3-launchers copilot || failed=1
    # EnMaaS backends, where linked (setup-t3-headless.zsh --enmaas)
    local -a en_claude=() en_codex=() b
    for b in enmaas hosted-only; do
        [[ -L "$T3_CLAUDE_LAUNCHER_DIR/claude-t3-$b" ]] && en_claude+=($b)
        [[ -L "$T3_CLAUDE_LAUNCHER_DIR/codex-t3-$b" ]] && en_codex+=($b)
    done
    if (( ${#en_claude} + ${#en_codex} )); then
        (( ${#en_claude} )) && { verify-claude-t3-launchers $en_claude || failed=1; }
        (( ${#en_codex} )) && { verify-codex-t3-launchers $en_codex || failed=1; }
        if zsh -fc 'source "$1" >/dev/null 2>&1; [[ -n "${ENMAAS_API_KEY-}" && -n "${ENMAAS_API_BASE_URL-}" ]]' _ \
            "${CLAUDE_PROVIDER_CREDENTIALS_FILE:-$HOME/secrets.zsh}"; then
            success "EnMaaS key and base URL set"
        else
            error "EnMaaS launchers linked but ENMAAS_API_KEY / ENMAAS_API_BASE_URL missing from ${CLAUDE_PROVIDER_CREDENTIALS_FILE:-~/secrets.zsh}"
            failed=1
        fi
    fi

    # Optional: T3 Connect reaches the phone without it.
    if (( $+commands[tailscale] )); then
        local ts_state
        ts_state=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null)
        if [[ "$ts_state" == Running ]]; then
            success "Tailscale connected ($(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")'))"
        else
            warning "Tailscale installed but not connected (${ts_state:-tailscaled not running}): sudo tailscale up"
        fi
    fi
    # A laptop serving lid-closed on AC. Under WSL, Windows owns power.
    local -a bats=("${T3_POWER_SUPPLY_DIR:-/sys/class/power_supply}"/BAT*(N))
    if (( ! wsl && ${#bats} )); then
        _t3_headless_laptop_checks || failed=1
    fi
    (( wsl )) && warning "Windows side not checked: WSL must start at boot with nobody signed in (docs/LAPTOP_MIGRATION.md, Headless WSL2)"
    return $failed
}

# Laptop part of verify-t3-headless: nothing may suspend it while it serves
# with the lid closed and nobody logged in, and an unattended reboot must come
# back on the network. Errors for what suspends it, warnings for what only
# bites on a reboot. Paths are overridable for tests.
_t3_headless_laptop_checks() {
    local failed=0 gdm_dir="${T3_GDM_DCONF_DIR:-/etc/dconf/db/gdm.d}" crypttab="${T3_CRYPTTAB:-/etc/crypttab}"
    local fix="see docs/LAPTOP_MIGRATION.md, Lid-closed Fedora laptop"

    # logind's default for closing the lid on AC power is suspend.
    local lid
    lid=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager HandleLidSwitchExternalPower 2>/dev/null)
    if [[ "$lid" == 's "ignore"' ]]; then
        success "Closing the lid on AC power is ignored"
    elif [[ -z "$lid" ]]; then
        error "Could not read logind's lid setting (is systemd-logind running?); $fix"
        failed=1
    else
        error "Closing the lid on AC power suspends (logind HandleLidSwitchExternalPower=${${lid#s \"}%\"}); $fix"
        failed=1
    fi

    # With nobody logged in the GDM greeter's power settings apply, and it
    # suspends after a while idle even on AC. Masked sleep targets also cover it.
    # No files: grep must not run without file args, it would read stdin.
    local masked=0
    local -a gdm_files=("$gdm_dir"/*(N))
    [[ "$(systemctl is-enabled suspend.target 2>/dev/null)" == masked ]] && masked=1
    if (( masked )); then
        success "Suspend is masked"
    elif (( ${#gdm_files} )) && grep -qs "sleep-inactive-ac-type='nothing'" $gdm_files; then
        success "Login screen does not suspend on AC"
    else
        error "Login screen suspends after idle on AC power; $fix"
        failed=1
    fi
    if (( ! masked )) && (( $+commands[gsettings] )) \
        && [[ "$(gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 2>/dev/null)" != *nothing* ]]; then
        warning "Your GNOME session suspends after idle on AC (when logged in); $fix"
    fi

    # An encrypted root waits for the passphrase at the keyboard on every boot.
    if lsblk -rno TYPE 2>/dev/null | grep -qx crypt && ! grep -qs 'tpm2-device' "$crypttab"; then
        warning "Encrypted disk without TPM2 unlock: a reboot waits for the passphrase at the keyboard; $fix"
    fi

    # Wi-Fi saved for one user or with its password in that user's keyring
    # connects only after that user logs in.
    local name type perms flags
    if (( $+commands[nmcli] )); then
        while IFS=: read -r name type; do
            [[ "$type" == 802-11-wireless ]] || continue
            perms=$(nmcli -g connection.permissions connection show "$name" 2>/dev/null)
            flags=$(nmcli -g 802-11-wireless-security.psk-flags connection show "$name" 2>/dev/null)
            if [[ -z "$perms" && "${flags:-0}" == 0 ]]; then
                success "Wi-Fi '$name' connects at boot"
            else
                warning "Wi-Fi '$name' connects only after login; $fix"
            fi
        done < <(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null)
    fi

    [[ "$(systemctl is-enabled sshd 2>/dev/null)" == enabled ]] \
        || warning "sshd not enabled: no way in for maintenance with the lid closed (sudo systemctl enable --now sshd)"
    return $failed
}

# sync-claude-plugins [--update] [--dry-run]: make this machine's Claude
# plugins match ~/.claude/settings.json, which lists the marketplaces
# (extraKnownMarketplaces) and enabled plugins. Claude Code registers some of
# those marketplaces itself at startup but installs no plugins, and their
# caches are not in the config repo. Adds missing marketplaces (a directory
# source's Mac home becomes this home) and installs every enabled plugin not
# installed yet. --update also refreshes all marketplaces and updates each
# enabled plugin. Used by scripts/setup-t3-headless.zsh and fleet-sync.
sync-claude-plugins() {
    local update=0 dry=0 a
    for a; do
        case $a in
            --update) update=1 ;;
            --dry-run) dry=1 ;;
            *) error "sync-claude-plugins: unknown option $a (--update, --dry-run)"; return 2 ;;
        esac
    done
    local claude="${CLAUDE_PROVIDER_NATIVE_BINARY:-$HOME/.local/bin/claude}"
    local cs="$HOME/.claude/settings.json" known="$HOME/.claude/plugins/known_marketplaces.json"
    local installed="$HOME/.claude/plugins/installed_plugins.json" mname msrc pid saved
    local -i added=0 inst=0 upd=0 fail=0
    [[ -r "$cs" ]] || { warning "No $cs; skipping Claude plugins"; return 0; }
    [[ -x "$claude" ]] || { warning "Claude Code not found at $claude; skipping Claude plugins"; return 0; }

    # `claude plugin marketplace add` also records the source in settings.json,
    # which is shared through git: it would swap in this home's directory paths
    # and add entries under a marketplace's own name. The file is put back
    # afterwards; what got installed lives in the gitignored
    # known_marketplaces.json / installed_plugins.json.
    saved=$(mktemp) && cp -p "$cs" "$saved" || return 1
    {
        while IFS=$'\t' read -r mname msrc; do
            [[ "$msrc" == /Users/* ]] && msrc="$HOME/${msrc#/Users/*/}"
            # Match by source too: a marketplace registers under the name in
            # its own manifest, which can differ from settings.json's key.
            jq -e --arg n "$mname" --arg s "$msrc" \
                'has($n) or any(.[]; .source | (.repo // .url // .path) == $s)' "$known" >/dev/null 2>&1 && continue
            if [[ "$msrc" == /* && ! -d "$msrc" ]]; then
                warning "Marketplace $mname: $msrc not found; skipped"; (( fail++ )); continue
            fi
            if _t3_plugin_cli $dry "$claude" marketplace add "$msrc"; then (( added++ ))
            else warning "Could not add marketplace $mname ($msrc)"; (( fail++ )); fi
        done < <(jq -r '.extraKnownMarketplaces // {} | to_entries[] | [.key, (.value.source | .repo // .url // .path)] | @tsv' "$cs")

        (( update )) && { _t3_plugin_cli $dry "$claude" marketplace update || { warning "Marketplace update failed"; (( fail++ )); }; }

        for pid in ${(f)"$(jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' "$cs")"}; do
            if jq -e --arg i "$pid" '.plugins[$i]' "$installed" >/dev/null 2>&1; then
                (( update )) || continue
                if _t3_plugin_cli $dry "$claude" update "$pid"; then (( upd++ ))
                else warning "Could not update plugin $pid"; (( fail++ )); fi
            elif _t3_plugin_cli $dry "$claude" install "$pid"; then (( inst++ ))
            else warning "Could not install plugin $pid"; (( fail++ )); fi
        done
    } always {
        cat "$saved" > "$cs"   # cat, not mv: keeps the file and its mode in place
        rm -f "$saved"
    }
    success "Claude plugins$( (( dry )) && print -n ' (dry run, would be)'): $added marketplaces added, $inst installed$( (( update )) && print -n ", $upd updated")$( (( fail )) && print -n ", $fail problems above")"
    (( ! fail ))
}

# _t3_plugin_cli <dry> <claude> <plugin args...>: one `claude plugin` call,
# run from $HOME (no project scope), output kept off the terminal unless it
# fails.
_t3_plugin_cli() {
    local dry=$1 claude=$2 out; shift 2
    print -ru2 -- "+ claude plugin ${(j: :)${(q-)@}}"
    (( dry )) && return 0
    out=$(cd ~ && "$claude" plugin "$@" 2>&1) && return 0
    print -ru2 -- "$out" | tail -3
    return 1
}

# fleet-sync: fast-forward the dotfiles, Claude config and copilot-api
# checkouts and apply the changes (scripts/fleet-sync.zsh; --help for flags).
fleet-sync() {
    zsh "$_T3_DOTFILES_ROOT/scripts/fleet-sync.zsh" "$@"
}

# Provider instances that run this repo's launchers (binaryPath ending in
# /claude-t3-<backend> or /codex-t3-<backend>) travel between machines through
# t3/provider-instances.json, with the home directory written as @HOME@.
typeset -g _T3_PROVIDER_TEMPLATE="$_T3_DOTFILES_ROOT/t3/provider-instances.json"
typeset -g _T3_LAUNCHER_RE='/(claude|codex)-t3-[^/]+$'

# export-t3-providers: write this machine's launcher-backed T3 provider
# instances to t3/provider-instances.json. Environment entries marked
# sensitive are left out (re-enter them in T3 on the other machine).
export-t3-providers() {
    local settings="$T3CODE_HOME/userdata/settings.json" out="$_T3_PROVIDER_TEMPLATE" dropped
    [[ -r "$settings" ]] || { error "No $settings"; return 1; }
    mkdir -p "${out:h}" || return 1
    dropped=$(jq -r --arg re "$_T3_LAUNCHER_RE" '[.providerInstances // {} | to_entries[]
        | select((.value.config.binaryPath // "") | test($re)) | .key as $k
        | .value.environment[]? | select(.sensitive) | "\($k).\(.name)"] | join(", ")' "$settings") || return 1
    jq --arg home "$HOME" --arg re "$_T3_LAUNCHER_RE" '
        {providerInstances: (.providerInstances // {}
            | with_entries(select((.value.config.binaryPath // "") | test($re)))
            | map_values(.environment = [.environment[]? | select(.sensitive | not)]
                | walk(if type == "string" then split($home) | join("@HOME@") else . end)))}' \
        "$settings" > "$out.tmp" && mv "$out.tmp" "$out" || { rm -f "$out.tmp"; return 1; }
    [[ -n "$dropped" ]] && warning "Left out sensitive environment values: $dropped"
    success "Exported $(jq '.providerInstances | length' "$out") provider instances to $out"
}

# import-t3-providers [--dry-run] [id ...]: add the instances from
# t3/provider-instances.json (@HOME@ -> this home) to this machine's T3
# settings; all of them, or the given ids. Skips an instance whose launcher is
# not linked here. One already present is updated only while it still equals
# what the previous import wrote (nobody changed it here); a local edit is
# kept and reported. Record of imports:
# ${XDG_STATE_HOME:-~/.local/state}/t3-provider-imports.json.
import-t3-providers() {
    local dry=0
    [[ "${1-}" == --dry-run ]] && { dry=1; shift; }
    local settings="$T3CODE_HOME/userdata/settings.json"
    local rec="${XDG_STATE_HOME:-$HOME/.local/state}/t3-provider-imports.json"
    [[ -r "$_T3_PROVIDER_TEMPLATE" ]] || { warning "No $_T3_PROVIDER_TEMPLATE; run export-t3-providers where the providers are set up"; return 0; }
    local want cur='{}' prev='{}' id bin
    want=$(jq -c --arg home "$HOME" '.providerInstances // {}
        | walk(if type == "string" then split("@HOME@") | join($home) else . end)' "$_T3_PROVIDER_TEMPLATE") || return 1
    [[ -r "$settings" ]] && { cur=$(jq -c '.providerInstances // {}' "$settings") || return 1; }
    [[ -r "$rec" ]] && { prev=$(jq -c . "$rec" 2>/dev/null) || prev='{}'; }
    local -a apply=() added=() updated=() kept=() current=()
    for id in ${(f)"$(jq -r 'keys[]' <<<"$want")"}; do
        (( $# )) && (( ! ${@[(Ie)$id]} )) && continue
        bin=$(jq -r --arg i "$id" '.[$i].config.binaryPath // ""' <<<"$want")
        [[ "$bin" == /* && ! -x "$bin" ]] && continue   # launcher not linked on this machine
        if ! jq -e --arg i "$id" 'has($i)' <<<"$cur" >/dev/null; then
            added+=("$id"); apply+=("$id")
        elif jq -en --arg i "$id" --argjson c "$cur" --argjson w "$want" '$c[$i] == $w[$i]' >/dev/null; then
            current+=("$id")
        elif jq -en --arg i "$id" --argjson c "$cur" --argjson p "$prev" '$c[$i] == $p[$i]' >/dev/null; then
            updated+=("$id"); apply+=("$id")
        else
            kept+=("$id")
        fi
    done
    (( ${#kept} )) && warning "Changed on this machine, not updated: ${(j:, :)kept} (edit t3/provider-instances.json or the instance in T3)"
    if (( ${#apply} )) && (( ! dry )); then
        local ids
        ids=$(print -rl -- $apply | jq -Rsc 'split("\n") | map(select(length > 0))')
        mkdir -p "${settings:h}" "${rec:h}" || return 1
        { [[ -r "$settings" ]] && cat "$settings" || print '{}'; } |
            jq --argjson w "$want" --argjson ids "$ids" \
                'reduce $ids[] as $i (.; .providerInstances[$i] = $w[$i])' > "$settings.tmp" &&
            mv "$settings.tmp" "$settings" || { rm -f "$settings.tmp"; error "Could not update $settings"; return 1; }
    fi
    if (( ! dry )) && (( ${#apply} + ${#current} )); then
        local ids
        ids=$(print -rl -- $apply $current | jq -Rsc 'split("\n") | map(select(length > 0))')
        jq -n --argjson p "$prev" --argjson w "$want" --argjson ids "$ids" \
            'reduce $ids[] as $i ($p; .[$i] = $w[$i])' > "$rec.tmp" && mv "$rec.tmp" "$rec"
    fi
    success "T3 providers$( (( dry )) && print -n ' (dry run)'): ${#added} added${added:+ (${(j:, :)added})}, ${#updated} updated${updated:+ (${(j:, :)updated})}, ${#current} current"
}
