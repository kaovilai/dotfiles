# Shared by delete-ocp-aws / delete-ocp-gcp-wif / delete-ocp-azure-sts.
#
# Picking the destroy binary used to be a guess (latest EC) and a failed
# destroy still removed the install dir. Incidents: 2026-09-21 (missing guessed
# binary, destroy error swallowed, dir removed -> 6 EC2 + VPC orphaned) and
# 2026-10-23 (4.22.19 logs no "Running:" line, so the AWS log lookup found
# nothing, guessed a missing 4.23 EC binary and refused; cm then retried the
# identical command and gave up).

# Marker cm greps for in a delete run's log: retrying cannot help, a human
# must supply a binary (`cm destroy <id> --installer PATH`).
DESTROY_INSTALLER_MISSING_MARKER="DESTROY_INSTALLER_MISSING"

# resolve-destroy-installer <install_dir> [override]
# Prints the openshift-install to destroy <install_dir> with (nothing when the
# dir has no metadata.json: there is nothing for the installer to destroy).
# Order:
#   1. override (caller's $OPENSHIFT_INSTALL env)
#   2. "Running: <path>" from the dir's .openshift_install.log (only some builds log it)
#   3. openshift-install-<ver> on PATH, <ver> from "OpenShift Installer <ver>" (every build logs it, line 1)
#   4. newest runnable openshift-install-* on PATH with the same X.Y and >= <ver>
#      (destroy is metadata.json/tag driven; same minor knows the same resource types)
#   5. no version in the log at all: latest EC, as before
# Returns 1 with the marker on stderr when nothing safe is found -- never a
# different minor or an older build, which may not know newer resource types.
resolve-destroy-installer() {
    local dir=$1 override=$2 log="$1/.openshift_install.log" bin="" ver="" c cv best="" bestv=""
    [[ -f "$dir/metadata.json" ]] || return 0
    if [[ -n "$override" ]]; then
        if ! command -v "$override" >/dev/null 2>&1; then
            echo "ERROR: $DESTROY_INSTALLER_MISSING_MARKER: OPENSHIFT_INSTALL '$override' not found/executable." >&2
            return 1
        fi
        print -r -- "$override"; return 0
    fi
    if [[ -f "$log" ]]; then
        bin=$(grep -m1 -oE 'Running: [^ ]*openshift-install[^ ]*' "$log" 2>/dev/null | awk '{print $2}')
        if [[ -n "$bin" ]] && command -v "$bin" >/dev/null 2>&1; then
            print -r -- "$bin"; return 0
        fi
        ver=$(grep -m1 -oE 'OpenShift Installer [^" ]+' "$log" 2>/dev/null | awk '{print $3}')
    fi
    if [[ -n "$ver" ]]; then
        if command -v "openshift-install-$ver" >/dev/null 2>&1; then
            print -r -- "openshift-install-$ver"; return 0
        fi
        autoload -Uz is-at-least
        local minor; minor=$(print -r -- "$ver" | cut -d. -f1-2)  # 4.22.19 -> 4.22
        for c in ${^path}/openshift-install-${minor}.*(N*); do
            cv=${c:t}; cv=${cv#openshift-install-}
            is-at-least "$ver" "$cv" || continue
            [[ -n "$bestv" ]] && is-at-least "$cv" "$bestv" && continue
            "$c" version >/dev/null 2>&1 || continue
            best=$c; bestv=$cv
        done
        if [[ -n "$best" ]]; then
            echo "WARNING: openshift-install-$ver not found; destroying with same-minor $best" >&2
            print -r -- "$best"; return 0
        fi
        echo "ERROR: $DESTROY_INSTALLER_MISSING_MARKER: cluster in $dir was installed by openshift-install $ver; no openshift-install-$ver or newer ${minor}.x on PATH." >&2
        echo "Set OPENSHIFT_INSTALL=/path/to/openshift-install (same $minor minor, or extract: oc adm release extract --command=openshift-install <release-image>) and retry." >&2
        return 1
    fi
    local EC_VERSION; EC_VERSION=$(get-ocp-latest-ec-version)
    bin="openshift-install-${EC_VERSION}"
    echo "WARNING: no installer version in $log -- guessing latest EC ($bin)." >&2
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "ERROR: $DESTROY_INSTALLER_MISSING_MARKER: guessed '$bin' not found/executable. Set OPENSHIFT_INSTALL=/path/to/matching/binary and retry." >&2
        return 1
    fi
    print -r -- "$bin"
}

# destroy-ocp-install-dir <installer> <install_dir>
# Runs destroy cluster + bootstrap. Returns 1 if `destroy cluster` failed, so
# callers keep the dir (and its metadata.json) for a retry instead of
# removing the only handle on live infra. No metadata.json = nothing the
# installer can destroy: returns 0 so partial dirs from early failures still
# get cleaned up. Bootstrap destroy failing is normal after a full install.
destroy-ocp-install-dir() {
    local inst=$1 dir=$2
    if [[ ! -f "$dir/metadata.json" ]]; then
        echo "no metadata.json in $dir: nothing for openshift-install to destroy"
        return 0
    fi
    if ! "$inst" destroy cluster --dir "$dir"; then
        echo "ERROR: '$inst destroy cluster' failed; keeping $dir so a retry can still find the infra." >&2
        return 1
    fi
    "$inst" destroy bootstrap --dir "$dir" || echo "no existing bootstrap"
}
