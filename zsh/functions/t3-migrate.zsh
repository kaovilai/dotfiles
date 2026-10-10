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

: ${T3CODE_HOME:=$HOME/.t3}
: ${T3_APPSUPPORT_DIR:=$HOME/Library/Application Support}

# Subdirectories of $T3CODE_HOME that hold state worth migrating
typeset -ga _T3_STATE_DIRS=(userdata dev)

# Electron profile dirs under $T3_APPSUPPORT_DIR
typeset -ga _T3_ELECTRON_DIRS=(t3code-v2 t3code)

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
