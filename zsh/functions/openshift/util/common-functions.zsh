# Common utility functions for OpenShift cluster creation
#
# This file contains shared utility functions used across all OpenShift cluster
# creation scripts (AWS, Azure, GCP, ROSA).
#
# Functions provided:
#   - prompt-release-stream: Interactive release stream selection (dev-preview/stable)
#   - get-release-image: Get release image URL for specific stream and architecture
#   - validate-env-vars: Validate required environment variables are set
#   - preflight-check-aws-permissions: Dry-run check AWS create/delete IAM perms
#   - preflight-check-gcp-permissions: Check GCP account has an admin-equivalent role
#   - get-openshift-install: Find or install openshift-install binary
#   - handle-registry-login: Login to container registries (podman)
#   - update-pull-secret-with-podman: Update pull-secret.txt with registry credentials
#   - create-install-config-header: Generate standard install-config.yaml header
#   - add-credentials-to-install-config: Add pull secret and SSH key to install-config
#   - generate-unique-cluster-name: Generate unique cluster name to avoid conflicts
#   - cleanup-on-failure: Clean up resources when cluster creation fails

# Function to prompt for release version selection
# Usage: stream=$(prompt-release-stream)
# Description: Shows all available OCP versions in fzf for selection.
#   Sets OCP_RELEASE_VERSION with the selected version.
# Returns: "dev-preview" or "stable" to stdout (for backward compat)
prompt-release-stream() {
    # Step 1: Discover available ranges dynamically from release controller
    local ranges
    ranges=$(curl -sm 10 \
        'https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestreams/accepted' \
        2>/dev/null \
    | jq -r 'keys[] | select(test("^[0-9]+\\.[0-9]"))' \
    | grep -oE '^[0-9]+\.[0-9]+' | sort -Vru)

    if [[ -z "$ranges" ]]; then
        echo "WARN: Could not fetch version ranges, falling back to latest" >&2
        unset OCP_RELEASE_VERSION
        echo "dev-preview"
        return 0
    fi

    # Step 2: Pick major.minor range (instant, no extra fetch)
    local chosen_range
    if command -v fzf >/dev/null 2>&1; then
        chosen_range=$(echo "$ranges" | fzf --height 30% --reverse \
            --header "Select version range" \
            --prompt "Range> ")
    else
        echo "Available ranges:" >&2
        echo "$ranges" | cat -n >&2
        echo -n "Enter range (e.g. 4.17): " >&2
        read -r chosen_range </dev/tty
    fi

    if [[ -z "$chosen_range" ]]; then
        echo "No range selected, using latest dev-preview" >&2
        unset OCP_RELEASE_VERSION
        echo "dev-preview"
        return 0
    fi

    # Step 3: Fetch versions for chosen range only (single API call)
    echo "Fetching ${chosen_range}.x versions..." >&2
    local versions
    versions=$(curl -sm 15 \
        "https://quay.io/api/v1/repository/openshift-release-dev/ocp-release/tag/?limit=100&onlyActiveTags=true&filter_tag_name=like:${chosen_range}.%-x86_64" \
        2>/dev/null \
    | jq -r '
        [.tags[].name
        | select(test("-multi") | not)
        | rtrimstr("-x86_64")]
        | unique | sort_by(split("[.-]"; null) | map(tonumber? // 99)) | reverse
        | .[] as $v
        | if ($v | test("ec\\.|rc\\.")) then "[dev-preview] \($v)"
          else "[stable-\($v | split(".")[0:2] | join("."))] \($v)"
          end
    ' 2>/dev/null)

    if [[ -z "$versions" ]]; then
        echo "WARN: No versions found for ${chosen_range}, falling back to latest" >&2
        unset OCP_RELEASE_VERSION
        echo "dev-preview"
        return 0
    fi

    # Step 4: Pick specific version
    local selected
    if command -v fzf >/dev/null 2>&1; then
        selected=$(echo "$versions" | fzf --height 40% --reverse \
            --header "Select ${chosen_range}.x version" \
            --prompt "Version> ")
    else
        echo "" >&2
        echo "$versions" | cat -n >&2
        echo -n "Enter line number or version: " >&2
        read -r selected </dev/tty
        if [[ "$selected" =~ ^[0-9]+$ ]]; then
            selected=$(echo "$versions" | sed -n "${selected}p")
        elif [[ -n "$selected" && "$selected" != *[[:space:]]* ]]; then
            # The prompt offers "line number or version"; map a bare typed
            # version back onto its "[tag] version" line so the stream tag and
            # the version are both parsed correctly below. No match falls
            # through to the existing "No version selected" handling. Guarded
            # on single-token input so a pasted whole list line
            # ("[stable-4.19] 4.19.1") keeps parsing exactly as it does today.
            selected=$(echo "$versions" | awk -v v="$selected" '$2 == v { print; exit }')
        fi
    fi

    if [[ -z "$selected" ]]; then
        echo "No version selected, using latest dev-preview" >&2
        unset OCP_RELEASE_VERSION
        echo "dev-preview"
        return 0
    fi

    local version; version=$(echo "$selected" | awk '{print $2}')
    local stream_tag; stream_tag=$(echo "$selected" | awk '{print $1}' | tr -d '[]')

    echo "INFO: Selected version $version ($stream_tag)" >&2

    if [[ "$stream_tag" == "dev-preview" ]]; then
        echo "dev-preview $version"
    else
        echo "stable $version"
    fi
}

# Function to prompt for an OCP minor version to use with the raw nightly
# release stream (stream=nightly in get-release-image). Reuses the same
# accepted-ranges discovery as prompt-release-stream's step 1, since nightly
# streams are per-minor-version only (no patch/z-stream selection -- "latest"
# is already the newest accepted payload for that minor).
# Usage: minor=$(prompt-nightly-minor-version)
# Returns: minor version (e.g. "4.22") to stdout
prompt-nightly-minor-version() {
    local ranges
    ranges=$(curl -sm 10 \
        'https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestreams/accepted' \
        2>/dev/null \
    | jq -r 'keys[] | select(test("^[0-9]+\\.[0-9]"))' \
    | grep -oE '^[0-9]+\.[0-9]+' | sort -Vru)

    if [[ -z "$ranges" ]]; then
        echo "ERROR: Could not fetch version ranges for nightly stream selection" >&2
        return 1
    fi

    local chosen_range
    if command -v fzf >/dev/null 2>&1; then
        chosen_range=$(echo "$ranges" | fzf --height 30% --reverse \
            --header "Select minor version for nightly stream" \
            --prompt "Nightly> ")
    else
        echo "Available minor versions:" >&2
        echo "$ranges" | cat -n >&2
        echo -n "Enter minor version (e.g. 4.22): " >&2
        read -r chosen_range </dev/tty
    fi

    if [[ -z "$chosen_range" ]]; then
        echo "ERROR: No minor version selected for nightly stream" >&2
        return 1
    fi
    echo "$chosen_range"
}

# Function to get release image based on stream and architecture
# Usage: image=$(get-release-image "stable" "amd64")
#        image=$(get-release-image "dev-preview" "arm64")
#        image=$(get-release-image "stable" "multi")
#        image=$(OCP_NIGHTLY_MINOR=4.22 get-release-image "nightly" "arm64")
# Description: Gets the appropriate release image URL for the given stream and architecture
# Parameters:
#   $1 - stream: "stable", "dev-preview", or "nightly" (requires OCP_NIGHTLY_MINOR, e.g. "4.22")
#   $2 - architecture: "amd64", "arm64", or "multi" (multi-arch)
# Returns: Release image URL to stdout, exits with 1 on error
get-release-image() {
    local stream=$1
    local architecture=$2

    # If a specific version was selected, construct pullSpec directly
    if [[ -n "$OCP_RELEASE_VERSION" ]]; then
        local quay_arch
        case "$architecture" in
            "amd64"|"x86_64") quay_arch="x86_64" ;;
            "arm64"|"aarch64") quay_arch="aarch64" ;;
            "multi") quay_arch="multi" ;;
            *)
                echo "ERROR: Unknown architecture: $architecture" >&2
                return 1
                ;;
        esac
        echo "quay.io/openshift-release-dev/ocp-release:${OCP_RELEASE_VERSION}-${quay_arch}"
        return 0
    fi

    if [[ "$stream" == "nightly" ]]; then
        if [[ -z "$OCP_NIGHTLY_MINOR" ]]; then
            echo "ERROR: stream=nightly requires OCP_NIGHTLY_MINOR to be set (e.g. 4.22)" >&2
            return 1
        fi
        case "$architecture" in
            "amd64"|"x86_64")
                get-ocp-release-image-nightly-amd64 "$OCP_NIGHTLY_MINOR"
                ;;
            "arm64"|"aarch64")
                get-ocp-release-image-nightly-arm64 "$OCP_NIGHTLY_MINOR"
                ;;
            "multi")
                get-ocp-release-image-nightly-multi "$OCP_NIGHTLY_MINOR"
                ;;
            *)
                echo "ERROR: Unknown architecture: $architecture" >&2
                return 1
                ;;
        esac
    elif [[ "$stream" == "stable" ]]; then
        case "$architecture" in
            "amd64"|"x86_64")
                get-ocp-release-image-stable-amd64
                ;;
            "arm64"|"aarch64")
                get-ocp-release-image-stable-arm64
                ;;
            "multi")
                get-ocp-release-image-stable-multi
                ;;
            *)
                echo "ERROR: Unknown architecture: $architecture" >&2
                return 1
                ;;
        esac
    else
        case "$architecture" in
            "amd64"|"x86_64")
                get-ocp-release-image-amd64
                ;;
            "arm64"|"aarch64")
                get-ocp-release-image-arm64
                ;;
            "multi")
                get-ocp-release-image-multi
                ;;
            *)
                echo "ERROR: Unknown architecture: $architecture" >&2
                return 1
                ;;
        esac
    fi
}

# Extract (or reuse a cached) openshift-install binary matching an exact
# release image pullspec. Needed for stream=nightly / raw nightly payloads:
# get-openshift-install() only knows about the latest cached EC/stable
# binaries, and installer/Terraform logic is version-specific, so pairing a
# mismatched binary with a nightly payload risks subtle install failures.
# Caches the extracted binary as /usr/local/bin/openshift-install-<version>
# (same naming convention as the EC/stable binaries) so repeat runs against
# the same nightly build skip re-extraction.
# Usage: binary=$(get-openshift-install-for-release-image "registry.ci.openshift.org/ocp/release:4.22.0-0.nightly-...")
get-openshift-install-for-release-image() {
    local release_image=$1
    if [[ -z "$release_image" ]]; then
        echo "ERROR: get-openshift-install-for-release-image requires a release image pullspec" >&2
        return 1
    fi

    echo "INFO: Resolving version for release image $release_image..." >&2
    local version
    version=$(oc adm release info "$release_image" --registry-config ~/pull-secret.txt -o jsonpath='{.metadata.version}' 2>/dev/null)
    if [[ -z "$version" ]]; then
        echo "ERROR: Failed to resolve version from release image $release_image" >&2
        return 1
    fi

    # /opt/homebrew/bin (not /usr/local/bin) -- user-writable on Apple Silicon
    # Homebrew installs, so this can run without sudo. Both are on PATH, so
    # get-openshift-install()'s `command -v openshift-install-<version>`
    # lookup finds binaries in either location.
    local binary_path="/opt/homebrew/bin/openshift-install-${version}"
    if [[ -x "$binary_path" ]] && "$binary_path" version &>/dev/null; then
        echo "INFO: Using cached openshift-install binary for $version" >&2
        echo "$binary_path"
        return 0
    fi

    # --registry-config ~/pull-secret.txt is required, not optional: component
    # images live under quay.io/openshift-release-dev/ocp-v*-art-dev, a private
    # namespace gated on the openshift-release-dev+ service account token in
    # the real pull-secret.txt (not personal quay.io credentials in podman/
    # docker auth files). See kubevirt-datamover-controller project memory
    # "oadp-install-pullsecret-bug" for the same failure mode elsewhere.
    echo "INFO: Extracting openshift-install binary for $version from $release_image (this may take a minute)..." >&2
    local tmp_extract_dir
    tmp_extract_dir=$(mktemp -d)
    if ! oc adm release extract --command=openshift-install --to="$tmp_extract_dir" --registry-config ~/pull-secret.txt "$release_image" &>/dev/null; then
        echo "ERROR: Failed to extract openshift-install from $release_image" >&2
        rm -rf "$tmp_extract_dir"
        return 1
    fi

    if ! mv "$tmp_extract_dir/openshift-install" "$binary_path"; then
        echo "ERROR: Failed to install extracted binary to $binary_path" >&2
        rm -rf "$tmp_extract_dir"
        return 1
    fi
    chmod +x "$binary_path"
    rm -rf "$tmp_extract_dir"

    echo "INFO: Extracted openshift-install to $binary_path" >&2
    echo "$binary_path"
}

# Preflight-check that a release image's referenced component image(s) have
# a published Sigstore signature, to fail fast before starting a ~45min
# cluster bootstrap that will otherwise hang forever pulling an unsigned one.
#
# Root cause this catches: standalone 4.21+ clusters ship an 'openshift'
# ClusterImagePolicy requiring Sigstore signatures on quay.io/openshift-
# release-dev/ocp-v*-art-dev images. A freshly-cut EC/dev-preview build can
# get promoted to quay before its signature finishes propagating -- when
# that happens, every master's machine-config-daemon-pull.service hits "A
# signature was required, but no signature exists" pulling the RHCOS
# (rhel-coreos) image during firstboot, and retries forever with no
# backoff-induced failure state, so bootstrap just times out.
#
# mode=fast (default) only checks the rhel-coreos image -- the earliest one
# pulled (blocks 100% of masters at firstboot, before anything else in the
# payload gets pulled), and the exact one confirmed missing a signature in
# practice. mode=full checks every image referenced by the release payload
# (~150-200, checked in parallel) for extra confidence.
#
# NOTE: must use `skopeo inspect --raw`, not plain `skopeo inspect` --
# non-raw inspect populates RepoTags by paginating the *entire* tag list of
# the repo, and ocp-v*-art-dev repos are shared ART repos with tens of
# thousands of tags spanning every OCP version ever built. That hangs for
# minutes per image; --raw fetches only the requested manifest.
#
# Usage: check-release-signatures "$RELEASE_IMAGE" [fast|full]
# Returns: 0 if the checked image(s) are signed, 1 if any are missing a
#   signature (prints the unsigned image ref(s) to stderr), 2 if the check
#   itself couldn't run (missing tool, oc adm release info failure, no
#   image refs found) -- callers should warn and proceed, not hard-block,
#   on a 2 since that's a broken preflight, not a confirmed problem.
check-release-signatures() {
    local release_image=$1
    local mode=${2:-fast}

    if [[ -z "$release_image" ]]; then
        echo "ERROR: check-release-signatures requires a release image pullspec" >&2
        return 2
    fi

    if ! command -v skopeo >/dev/null 2>&1; then
        echo "WARN: skopeo not found, skipping signature preflight check" >&2
        return 2
    fi

    echo "INFO: Checking Sigstore signature availability for $release_image (mode=$mode)..." >&2

    local refs_json
    refs_json=$(oc adm release info --registry-config ~/pull-secret.txt -o json "$release_image" 2>/dev/null)
    if [[ -z "$refs_json" ]]; then
        echo "WARN: Could not fetch release image references, skipping signature preflight check" >&2
        return 2
    fi

    local image_refs
    if [[ "$mode" == "full" ]]; then
        image_refs=$(echo "$refs_json" | jq -r '.references.spec.tags[].from.name' | sort -u)
    else
        image_refs=$(echo "$refs_json" | jq -r '.references.spec.tags[] | select(.name=="rhel-coreos") | .from.name')
    fi

    if [[ -z "$image_refs" ]]; then
        echo "WARN: No image references found (mode=$mode), skipping signature preflight check" >&2
        return 2
    fi

    local unsigned
    # NOTE: -n1 (each ref passed as $1, not substituted via -I{}) is required, not
    # cosmetic -- BSD/macOS xargs' -I replacement mode has a small internal command-
    # buffer limit unrelated to ARG_MAX, and hits "command line cannot be assembled,
    # too long" once the templated script text has more than a couple lines in it
    # (confirmed live: identical script raising the error under -I{}, passing under
    # -n1). This silently causes NO images to be checked at all -- a bare `|| echo` on
    # a xargs whose command never ran won't emit anything either -- so this is a false
    # "all signed" pass, not a visible failure. Since we can't tell fast from full mode
    # by argument count alone, use the safe -n1 form unconditionally.
    unsigned=$(echo "$image_refs" | xargs -P 20 -n1 zsh -c '
        ref=$1
        repo=${ref%@*}
        digest=${ref#*@sha256:}
        skopeo inspect --raw --retry-times 1 --authfile ~/pull-secret.txt "docker://${repo}:sha256-${digest}.sig" >/dev/null 2>&1 || echo "$ref"
    ' _)

    if [[ -n "$unsigned" ]]; then
        echo "ERROR: Missing Sigstore signature for the following image(s):" >&2
        echo "$unsigned" >&2
        return 1
    fi

    echo "INFO: Signature check passed (mode=$mode)" >&2
    return 0
}

# Wraps check-release-signatures() with what to do about a confirmed-missing
# signature: offer the same OPENSHIFT_INSTALL_EXPERIMENTAL_DISABLE_IMAGE_POLICY=true
# bypass the --nightly path already uses unconditionally (see the nightly
# handling in the calling scripts), instead of only aborting. EC images are
# supposed to be signed, so this bypass is only offered once a missing
# signature is actually confirmed -- not applied unconditionally like nightly.
#
# No-op (returns 0 immediately) unless $stream matches *dev-preview* --
# nightly already disables the policy unconditionally, and stable/GA images
# are verified-signed as part of release promotion, so there's nothing to
# check for those callers.
#
# Usage: enforce-release-signature-check "$RELEASE_IMAGE" "$stream" "$verify_all" "$allow_unsigned"
#   verify_all: "true" to check every payload image (mode=full), else just rhel-coreos
#   allow_unsigned: "true" to auto-bypass on a confirmed-missing signature without prompting
# Returns: 0 to proceed (exporting the bypass var if one was needed), 1 to abort
enforce-release-signature-check() {
    local release_image=$1
    local stream=$2
    local verify_all=$3
    local allow_unsigned=$4

    [[ "$stream" == *dev-preview* ]] || return 0

    local check_mode="fast"
    [[ "$verify_all" == "true" ]] && check_mode="full"

    check-release-signatures "$release_image" "$check_mode"
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        return 0
    elif [[ $rc -eq 2 ]]; then
        echo "WARN: Signature preflight check could not run -- proceeding without it" >&2
        return 0
    fi

    echo "" >&2
    echo "WARN: This build's signature may not have finished propagating yet (publishing lag)," >&2
    echo "      or another problem. Options: retry later, fall back to --nightly=X.Y, or bypass" >&2
    echo "      with --allow-unsigned (disables ClusterImagePolicy enforcement, same as --nightly)." >&2

    if [[ "$allow_unsigned" != "true" ]]; then
        local reply
        echo -n "Disable ClusterImagePolicy and continue anyway? [y/N] " >&2
        { read -r reply </dev/tty; } 2>/dev/null
        [[ "$reply" =~ ^[Yy]$ ]] && allow_unsigned=true
    fi

    if [[ "$allow_unsigned" == "true" ]]; then
        echo "INFO: Disabling ClusterImagePolicy enforcement (same as --nightly) and continuing" >&2
        export OPENSHIFT_INSTALL_EXPERIMENTAL_DISABLE_IMAGE_POLICY=true
        return 0
    fi

    echo "ERROR: Aborting -- missing signature not bypassed" >&2
    return 1
}

# Function to validate environment variables
# Usage: validate-env-vars "aws" AWS_REGION AWS_PROFILE
#        validate-env-vars "azure" AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID
# Description: Validates that all required environment variables are set
# Parameters:
#   $1 - provider: Cloud provider name (for error messages only)
#   $@ - variable names to validate
# Returns: 0 if all variables are set, 1 if any are missing
# Example:
#   validate-env-vars "azure" AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID || return 1
validate-env-vars() {
    local provider=$1
    shift
    local required_vars=("$@")
    
    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${(P)var}" ]]; then
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        echo "ERROR: The following required environment variables are not set:"
        for var in "${missing_vars[@]}"; do
            echo "  - $var"
        done
        echo ""
        echo "Please set these variables before running this function."
        return 1
    fi
    
    return 0
}

# Preflight-check that the current AWS identity can both create and delete
# the resource kinds openshift-install needs (EC2 instances/VPC, IAM roles,
# Route53 records, ELB/NLB) -- catching an under-scoped IAM policy before
# spending 40+ minutes on a bootstrap that will fail partway through, or
# worse, leaving orphaned infra because delete permissions were missing.
# Uses IAM's policy simulator (a dry-run evaluation -- creates nothing) so
# this is safe to run unconditionally. Only works for IAM *user* ARNs (the
# simulator needs the user/role ARN, not an STS assumed-role session ARN);
# skips with a WARN for assumed-role sessions since simulate-principal-policy
# can't resolve those directly.
# Usage: preflight-check-aws-permissions
# Returns: 0 if the identity is a user and simulation ran (regardless of
#          individual action results -- denials are printed but non-fatal,
#          since a scoped-down-but-sufficient policy is common and false
#          positives from the simulator are possible with SCPs/permission
#          boundaries it can't see); 0 (with a WARN) if skipped entirely.
preflight-check-aws-permissions() {
    local caller_arn
    caller_arn=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)
    if [[ -z "$caller_arn" ]]; then
        echo "WARN: preflight: could not determine AWS caller identity, skipping permission check" >&2
        return 0
    fi

    if [[ "$caller_arn" != *":user/"* ]]; then
        echo "WARN: preflight: AWS identity is not an IAM user ($caller_arn) -- IAM policy simulator" >&2
        echo "      can't evaluate assumed-role sessions directly, skipping permission preflight" >&2
        return 0
    fi

    echo "INFO: preflight: checking AWS permissions for $caller_arn..."
    local -a actions=(
        ec2:RunInstances ec2:TerminateInstances
        ec2:CreateVpc ec2:DeleteVpc
        ec2:CreateNatGateway ec2:DeleteNatGateway
        iam:CreateRole iam:DeleteRole
        iam:CreateInstanceProfile iam:DeleteInstanceProfile
        route53:ChangeResourceRecordSets
        elasticloadbalancing:CreateLoadBalancer elasticloadbalancing:DeleteLoadBalancer
    )
    local result
    result=$(aws iam simulate-principal-policy \
        --policy-source-arn "$caller_arn" \
        --action-names "${actions[@]}" \
        --query 'EvaluationResults[?EvalDecision!=`allowed`].[EvalActionName,EvalDecision]' \
        --output text 2>/dev/null)

    if [[ -n "$result" ]]; then
        echo "WARN: preflight: the following actions are NOT allowed for $caller_arn:" >&2
        echo "$result" | while IFS=$'\t' read -r action decision; do
            echo "  - $action: $decision" >&2
        done
        echo "WARN: preflight: cluster create/destroy may fail partway through -- continuing anyway" >&2
        echo "      (the simulator can't see SCPs/permission boundaries, so this may be a false positive)" >&2
    else
        echo "INFO: preflight: all checked create/delete actions allowed"
    fi
    return 0
}

# Preflight-check that the active gcloud account has sufficient IAM
# permissions on GCP_PROJECT_ID to both create and delete the resource kinds
# openshift-install/ccoctl need (Compute instances/networks, IAM service
# accounts, workload identity pools). Cheaper and less precise than AWS's
# policy-simulator check (GCP has no equivalent dry-run API for arbitrary
# permission lists without enumerating every testable permission), so this
# just checks for a broad admin-equivalent role (owner/editor) and warns
# rather than fails otherwise -- a narrower custom role could still be
# sufficient and this check can't prove a negative.
# Usage: preflight-check-gcp-permissions
# Returns: always 0 (warns, never fails -- see rationale above)
preflight-check-gcp-permissions() {
    local account
    account=$(gcloud config get-value account 2>/dev/null)
    if [[ -z "$account" || -z "$GCP_PROJECT_ID" ]]; then
        echo "WARN: preflight: could not determine gcloud account or GCP_PROJECT_ID, skipping permission check" >&2
        return 0
    fi

    echo "INFO: preflight: checking GCP permissions for $account on $GCP_PROJECT_ID..."
    local roles
    roles=$(gcloud projects get-iam-policy "$GCP_PROJECT_ID" \
        --flatten="bindings[].members" \
        --filter="bindings.members:$account" \
        --format="value(bindings.role)" 2>/dev/null)

    if echo "$roles" | grep -qE '^roles/(owner|editor)$'; then
        echo "INFO: preflight: $account has $(echo "$roles" | grep -E '^roles/(owner|editor)$' | head -1) on $GCP_PROJECT_ID (create+delete on all resource types)"
    else
        echo "WARN: preflight: $account has no roles/owner or roles/editor binding on $GCP_PROJECT_ID." >&2
        echo "      Current roles: ${roles:-<none found>}" >&2
        echo "      A narrower custom role may still be sufficient -- continuing anyway, but cluster" >&2
        echo "      create or delete (ccoctl gcp create-all/delete, compute/IAM resources) may fail" >&2
        echo "      partway through if a specific permission is actually missing." >&2
    fi
    return 0
}

# Internal helper to download openshift-install binary
_download-openshift-install() {
    local version=$1
    local arch=$2

    echo "Installing openshift-install ${version} for $arch architecture..." >&2

    local os=""
    case "$(uname -s)" in
        "Darwin") os="mac" ;;
        "Linux") os="linux" ;;
        *)
            echo "ERROR: Unsupported OS: $(uname -s)" >&2
            return 1
            ;;
    esac

    local url="https://mirror.openshift.com/pub/openshift-v4/clients/ocp-dev-preview/${version}/openshift-install-${os}-${arch}.tar.gz"
    local temp_dir; temp_dir=$(mktemp -d)

    echo "Downloading from: $url" >&2
    if curl -sL "$url" -o "${temp_dir}/openshift-install.tar.gz"; then
        tar -xzf "${temp_dir}/openshift-install.tar.gz" -C "${temp_dir}"
        if sudo mv "${temp_dir}/openshift-install" "/usr/local/bin/openshift-install-${version}"; then
            sudo chmod +x "/usr/local/bin/openshift-install-${version}"
            echo "Successfully installed openshift-install-${version}" >&2
            rm -rf "${temp_dir}"
            echo "openshift-install-${version}"
            return 0
        else
            echo "ERROR: Failed to install openshift-install to /usr/local/bin" >&2
            rm -rf "${temp_dir}"
            return 1
        fi
    else
        echo "ERROR: Failed to download openshift-install" >&2
        rm -rf "${temp_dir}"
        return 1
    fi
}

# Function to get openshift-install binary
# Usage: OPENSHIFT_INSTALL=$(get-openshift-install)
# Description: Finds an appropriate openshift-install binary or offers to install one
#              Checks for versioned binaries (e.g., openshift-install-4.17.0) first,
#              then falls back to generic 'openshift-install' command.
#              If not found, offers to download and install the latest EC version.
# Returns: Path to openshift-install binary to stdout
# Environment:
#   OPENSHIFT_INSTALL - If set, uses this path instead of searching
# Example:
#   local installer=$(get-openshift-install)
#   [[ -z "$installer" ]] && return 1
#   $installer version
get-openshift-install() {
    local ec_version; ec_version=$(get-ocp-latest-ec-version)
    local stable_version; stable_version=$(get-ocp-latest-stable-version)

    # Detect host architecture
    local host_arch=""
    case "$(uname -m)" in
        "x86_64"|"amd64")
            host_arch="amd64"
            ;;
        "arm64"|"aarch64")
            host_arch="arm64"
            ;;
        *)
            echo "ERROR: Unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac

    # Check if user has set a specific version
    if [[ -n "$OPENSHIFT_INSTALL" ]]; then
        echo "$OPENSHIFT_INSTALL"
        return
    fi

    # Check if binary is executable on this host
    # Note: "release architecture" in openshift-install version output is the
    # TARGET cluster architecture, not the binary's CPU architecture.
    local check_binary_arch() {
        local binary=$1
        if $binary version &>/dev/null; then
            return 0  # Binary runs successfully
        fi
        return 2  # Binary not executable (wrong CPU arch, missing deps, etc.)
    }

    # Try EC version first, then stable, then generic
    for binary in "openshift-install-${ec_version}" "openshift-install-${stable_version}" "openshift-install"; do
        if command -v "$binary" &> /dev/null && check_binary_arch "$binary"; then
            echo "$binary"
            return 0
        fi
    done

    # No suitable binary found, offer to install
    if true; then
        echo "ERROR: No openshift-install binary found" >&2
        echo "" >&2
        echo "Would you like to install openshift-install version ${ec_version}? (y/n)" >&2
        local install_choice
        read -r install_choice
        
        if [[ "$install_choice" == "y" || "$install_choice" == "Y" ]]; then
            _download-openshift-install "$ec_version" "$host_arch"
            return $?
        else
            echo "Please install openshift-install or set OPENSHIFT_INSTALL variable" >&2
            return 1
        fi
    fi
}

# Function to handle registry login
# Usage: handle-registry-login "registry.ci.openshift.org"
#        handle-registry-login "quay.io"
# Description: Ensures user is logged into the specified container registry using podman
#              For registry.ci.openshift.org, opens browser for OAuth login
# Parameters:
#   $1 - registry: Registry hostname to login to
# Example:
#   handle-registry-login "registry.ci.openshift.org"
handle-registry-login() {
    local registry=$1
    
    echo "INFO: Checking if podman is logged into $registry"
    if ! podman login --get-login "$registry" &>/dev/null; then
        if [[ "$registry" == "registry.ci.openshift.org" ]]; then
            echo "Opening browser for registry.ci.openshift.org login..."
            open "https://oauth-openshift.apps.ci.l2s4.p1.openshiftapps.com/oauth/authorize?client_id=openshift-browser-client&redirect_uri=https%3A%2F%2Foauth-openshift.apps.ci.l2s4.p1.openshiftapps.com%2Foauth%2Ftoken%2Fdisplay&response_type=code"
            echo "Login URL opened in browser. Please copy the login command from the browser and paste it below:"
            local login_command
            read -r login_command

            # Securely parse the command into an array to avoid arbitrary code execution via eval
            local -a cmd_args
            cmd_args=("${(@Q)${(z)login_command}}")

            if [[ "${cmd_args[1]}" != "podman" && "${cmd_args[1]}" != "oc" && "${cmd_args[1]}" != "docker" ]] || [[ "${cmd_args[2]}" != "login" ]]; then
                echo "ERROR: Only 'podman login', 'oc login', or 'docker login' commands are accepted"
                return 1
            fi
            echo "Executing login command..."
            "${cmd_args[@]}"
        else
            echo "Please login to $registry:"
            podman login "$registry"
        fi
    else
        echo "Already logged into $registry"
    fi
}

# Function to update pull secret with podman credentials
# Usage: update-pull-secret-with-podman "registry.ci.openshift.org"
# Description: Updates ~/pull-secret.txt with credentials from podman auth file
#              for the specified registry. Skips quay.io as it's already included.
# Parameters:
#   $1 - registry: Registry hostname to add credentials for
# Prerequisites:
#   - Must be logged into the registry via podman
#   - ~/pull-secret.txt must exist
# Example:
#   handle-registry-login "$registry"
#   update-pull-secret-with-podman "$registry"
update-pull-secret-with-podman() {
    local registry=$1
    
    if [[ "$registry" == "quay.io" ]]; then
        echo "INFO: Skipping pull secret update for quay.io (already included)"
        return 0
    fi
    
    if ! podman login --get-login "$registry" &>/dev/null; then
        echo "WARN: Not logged into $registry, skipping pull secret update"
        return 0
    fi
    
    echo "INFO: Updating pull-secret.txt with credentials for $registry"
    
    # Get podman auth file location
    local podman_auth_file="${XDG_RUNTIME_DIR}/containers/auth.json"
    if [[ ! -f "$podman_auth_file" ]]; then
        podman_auth_file="$HOME/.config/containers/auth.json"
    fi
    
    if [[ ! -f "$podman_auth_file" ]]; then
        echo "WARN: Podman auth file not found"
        return 1
    fi
    
    # Extract auth for the specific registry
    # Note: declare local first, then assign so jq's exit status is preserved.
    local registry_auth
    registry_auth=$(jq -r --arg reg "$registry" '.auths[$reg] // empty' "$podman_auth_file") || {
        echo "WARN: Failed to parse podman auth file for $registry" >&2
        return 1
    }
    
    if [[ -z "$registry_auth" ]]; then
        echo "WARN: No auth found for $registry in podman auth file"
        return 1
    fi
    
    # Read current pull secret
    local pull_secret
    pull_secret=$(cat ~/pull-secret.txt) || {
        echo "WARN: Failed to read ~/pull-secret.txt" >&2
        return 1
    }
    
    # Update pull secret with the registry auth
    local updated_pull_secret
    updated_pull_secret=$(echo "$pull_secret" | jq --arg reg "$registry" --argjson auth "$registry_auth" '.auths[$reg] = $auth') || {
        echo "WARN: Failed to update pull secret JSON for $registry" >&2
        return 1
    }
    
    # Write back to pull-secret.txt
    echo "$updated_pull_secret" > ~/pull-secret.txt
    echo "INFO: Updated ~/pull-secret.txt with credentials for $registry"
    
    return 0
}

# Function to create standard install-config.yaml header
# Usage: create-install-config-header > install-config.yaml
# Description: Outputs the standard OpenShift install-config.yaml header
# Returns: YAML header to stdout
create-install-config-header() {
    echo "additionalTrustBundlePolicy: Proxyonly
apiVersion: v1"
}

# Function to add pull secret and SSH key to install-config
# Usage: add-credentials-to-install-config >> install-config.yaml
# Description: Outputs pull secret and SSH key sections for install-config.yaml
# Prerequisites:
#   - ~/pull-secret.txt must exist
#   - ~/.ssh/id_rsa.pub must exist
# Returns: YAML credentials section to stdout
add-credentials-to-install-config() {
    echo "pullSecret: '$(cat ~/pull-secret.txt)'
sshKey: |
  $(cat ~/.ssh/id_rsa.pub)"
}

# Check whether a cluster install directory belongs to a LIVE, reachable
# cluster (API server responds), as opposed to a stale/failed/leftover
# attempt directory that's safe to archive+destroy+reuse.
#
# Usage: is-cluster-live "$OCP_CREATE_DIR"
#
# Added 2026-08-31 after a real incident: a second same-day AWS
# cluster-create invocation's pre-create cleanup silently destroyed a
# DIFFERENT, still-converging, actively-needed cluster because it happened
# to land on the same directory (see generate-unique-cluster-name's old
# collision-check bug below). Never assume a directory is stale just
# because it exists -- check.
is-cluster-live() {
    local cluster_dir=$1
    local kubeconfig="$cluster_dir/auth/kubeconfig"
    [[ -f "$kubeconfig" ]] || return 1
    KUBECONFIG="$kubeconfig" timeout 10 oc get clusterversion version >/dev/null 2>&1
}

# Function to generate unique cluster name and directory
# Usage: result=$(generate-unique-cluster-name "tkaovila-20250114-sts" "/path/to/dir")
#        cluster_name=$(echo "$result" | grep "cluster_name:" | cut -d: -f2)
#        cluster_dir=$(echo "$result" | grep "cluster_dir:" | cut -d: -f2)
# Description: Generates unique cluster name by appending suffix if conflicts exist.
#              A directory containing a LIVE cluster (API server reachable) is ALWAYS
#              skipped past, regardless of PROCEED_WITH_EXISTING_CLUSTERS -- this
#              function must never hand back a directory to the caller's pre-create
#              cleanup that a live cluster is still using. A directory that merely
#              *exists* but is not live only gets suffixed when
#              PROCEED_WITH_EXISTING_CLUSTERS=true (old default-reuse behavior for
#              stale/failed attempts is unchanged).
# Parameters:
#   $1 - base_name: Base cluster name
#   $2 - base_dir: Base directory path
# Returns: Two lines to stdout: "cluster_name:NAME" and "cluster_dir:DIR"
# Environment:
#   PROCEED_WITH_EXISTING_CLUSTERS - If "true", appends -1, -2, etc. to avoid
#     conflicting with any existing (even non-live) directory.
# Example:
#   local unique=$(generate-unique-cluster-name "$CLUSTER_NAME" "$OCP_CREATE_DIR")
#   [[ -z "$unique" ]] && return 1
#
# HISTORY: previously checked collisions via `find "$OCP_MANIFESTS_DIR" -name
# "*${base_name}*"`, matching against the cluster NAME (e.g.
# "tkaovila-260831-amd64"). That pattern never matches AWS's actual directory
# naming convention ("260831-aws-amd64" -- no "tkaovila-" prefix, "aws-"
# inserted mid-string), so the collision check silently never fired on AWS,
# and a live cluster sharing that day+arch got destroyed by a second
# invocation (confirmed live 2026-08-31). Fixed to check the candidate
# DIRECTORY's existence directly instead of a name-pattern guess.
generate-unique-cluster-name() {
    local base_name=$1
    local base_dir=$2
    local suffix=""
    local suffix_num=1
    local candidate_dir="$base_dir"
    local candidate_name="$base_name"

    while [[ -d "$candidate_dir" ]]; do
        if is-cluster-live "$candidate_dir"; then
            echo "Found LIVE cluster at $candidate_dir (API server reachable) -- never auto-reusing/destroying a live cluster's directory, picking a new name/dir" >&2
        elif [[ "$PROCEED_WITH_EXISTING_CLUSTERS" != "true" ]]; then
            # Existing but not live, and caller hasn't opted into
            # auto-suffixing: keep prior default behavior of returning this
            # name/dir as-is (the caller's own pre-create cleanup will
            # archive+destroy+reuse it, same as always).
            break
        fi

        suffix="-${suffix_num}"
        candidate_name="${base_name}${suffix}"
        candidate_dir="${base_dir}${suffix}"
        echo "Found existing cluster dir, trying: $candidate_name" >&2

        ((suffix_num++))
        # Safety check to avoid infinite loop
        if [[ $suffix_num -gt 10 ]]; then
            echo "ERROR: Cannot find a unique cluster name after 10 attempts" >&2
            return 1
        fi
    done

    echo "cluster_name:${candidate_name}"
    echo "cluster_dir:${candidate_dir}"
    return 0
}

# Function to cleanup cluster resources on failure
# Usage: cleanup-on-failure "$OCP_CREATE_DIR" "$CLUSTER_NAME" "azure"
# Description: Attempts to gather bootstrap logs and provides cleanup guidance
#              when cluster creation fails
# Parameters:
#   $1 - cluster_dir: Path to cluster installation directory
#   $2 - cluster_name: Name of the cluster
#   $3 - provider: Cloud provider ("aws", "gcp", "azure")
# Returns: Always returns 1 (failure status)
# Example:
#   if ! $OPENSHIFT_INSTALL create cluster --dir $dir; then
#       cleanup-on-failure "$dir" "$name" "aws"
#       return 1
#   fi
# Get a version-matched oc binary from a release image
# Extracts oc to /tmp/oc-<cache-key>/oc if not cached, returns the path
# Falls back to system oc if extraction fails
# Usage: local OC_BIN=$(get-release-oc "$RELEASE_IMAGE")
get-release-oc() {
    local release_image=$1
    [[ -z "$release_image" ]] && { echo "oc"; return; }

    # Cache key: use whatever hex identifier is in the image ref (the sha256
    # digest for a digest-pinned image, or a build-ID-ish hex string for a
    # tag), NOT a regex-extracted semver. Nightly images
    # (quay.io/.../ocp-release-nightly@sha256:<digest>, no version substring
    # anywhere in the string at all) used to make the old semver regex match
    # nothing, silently falling back to plain system `oc` for the ENTIRE
    # nightly code path -- meaning the "version-matched oc" behavior this
    # function promises was never actually happening for --nightly installs.
    # A digest/hex-based key works for both digest and tag references and
    # doesn't depend on parsing any particular naming convention.
    local cache_key; cache_key=$(echo "$release_image" | grep -oE '[0-9a-f]{12,64}' | tail -1)
    if [[ -z "$cache_key" ]]; then
        cache_key=$(echo "$release_image" | (md5 -q 2>/dev/null || md5sum | cut -d' ' -f1))
    fi

    local oc_dir="/tmp/oc-${cache_key}"
    if [[ -x "$oc_dir/oc" ]]; then
        echo "$oc_dir/oc"
        return
    fi

    echo "INFO: Extracting oc matching release image $release_image..." >&2
    mkdir -p "$oc_dir"
    oc adm release extract --command=oc --to "$oc_dir" \
        --registry-config ~/pull-secret.txt "$release_image" 2>/dev/null
    if [[ -x "$oc_dir/oc" ]]; then
        echo "INFO: Cached oc at $oc_dir/oc" >&2
        echo "$oc_dir/oc"
    else
        echo "WARNING: Failed to extract oc from release, using system oc" >&2
        echo "oc"
    fi
}

# Get a version-matched oc binary for an ALREADY-RUNNING cluster, by reading
# its actual ClusterVersion desired-release image (not whatever stream/flag
# was requested at create time -- the two can differ, e.g. after a partial
# upgrade, or if you're inspecting someone else's cluster). This is what to
# use for ANY interactive post-install diagnostics (oc get co/nodes/etc.)
# against a nightly/pre-GA cluster -- the system `oc` on PATH is very likely
# older than what the cluster is running (confirmed live: system oc was
# 4.21.18 while diagnosing a 5.0.0-0.nightly cluster) and can silently behave
# differently (missing fields/CRDs it doesn't know about, subtly wrong output
# for newer API versions) without necessarily erroring.
# Usage: local OC_BIN=$(get-cluster-oc "$KUBECONFIG_PATH")
get-cluster-oc() {
    local kubeconfig=$1
    [[ -z "$kubeconfig" || ! -f "$kubeconfig" ]] && { echo "oc"; return; }

    local release_image
    release_image=$(KUBECONFIG="$kubeconfig" oc get clusterversion version -o jsonpath='{.status.desired.image}' 2>/dev/null)
    [[ -z "$release_image" ]] && { echo "oc"; return; }

    get-release-oc "$release_image"
}

cleanup-on-failure() {
    local cluster_dir=$1
    local cluster_name=$2
    local provider=$3

    echo "ERROR: Cluster creation failed, cleaning up resources..."

    # Try to gather bootstrap logs first
    if [[ -d "$cluster_dir" ]]; then
        local openshift_install; openshift_install=$(get-openshift-install)
        if [[ -n "$openshift_install" ]]; then
            echo "Attempting to gather bootstrap logs..."
            $openshift_install gather bootstrap --dir "$cluster_dir" || true

            # Archive AFTER gather (which is what actually produces
            # log-bundle-*.tar.gz) and BEFORE destroy -- this function never
            # deletes cluster_dir itself, but the *next* invocation's
            # pre-create cleanup block does, so this dir is not guaranteed to
            # survive; archive now while everything gather produced is still
            # here. Never deletes anything itself -- see archive-logs.sh.
            bash ~/.claude/skills/create-ocp/scripts/archive-logs.sh "$cluster_dir" 2>/dev/null || true

            # Run destroy if metadata.json exists (installer can identify resources)
            if [[ -f "$cluster_dir/metadata.json" ]]; then
                # Back up metadata.json so pre-create destroy works even if dir is removed
                local backup_path="${OCP_MANIFESTS_DIR}/.metadata-backup-${cluster_dir:t}.json"
                cp "$cluster_dir/metadata.json" "$backup_path" 2>/dev/null && \
                    echo "INFO: Backed up metadata.json to $backup_path"
                echo "Running openshift-install destroy cluster..."
                $openshift_install destroy cluster --dir "$cluster_dir" || \
                    echo "WARNING: destroy cluster failed, may need manual cleanup"
            fi
        fi
    fi

    # Provider-specific cleanup
    case "$provider" in
        "aws"|"gcp"|"azure")
            echo "Note: You may need to manually clean up cloud resources"
            echo "Check your $provider console for any orphaned resources"
            ;;
    esac

    return 1
}

# Clean up orphaned GCP compute resources by cluster name pattern
# Deletes in dependency order: forwarding rules → target proxies → backend services → instance groups
# Skips silently if no orphaned resources found
cleanup-orphaned-gcp-resources() {
    local cluster_name=$1
    local project=$2

    [[ -z "$cluster_name" || -z "$project" ]] && return 0

    local filter="name~${cluster_name}"
    local found=false

    # Check if any orphaned compute resources exist
    local backend_services; backend_services=$(gcloud compute backend-services list --project="$project" \
        --filter="$filter" --format='value(name)' 2>/dev/null)
    local instance_groups; instance_groups=$(gcloud compute instance-groups list --project="$project" \
        --filter="$filter" --format='value(name,zone.basename())' 2>/dev/null)

    [[ -z "$backend_services" && -z "$instance_groups" ]] && return 0

    echo "INFO: Found orphaned GCP resources for $cluster_name, cleaning up..."

    # Delete in GCP dependency order
    # 1. Forwarding rules (reference target proxies)
    gcloud compute forwarding-rules list --project="$project" --filter="$filter" \
        --format='value(name,region.basename())' 2>/dev/null | while IFS=$'\t' read -r name region; do
        [[ -n "$name" ]] || continue
        echo "  Deleting forwarding rule: $name"
        if [[ -n "$region" ]]; then
            gcloud compute forwarding-rules delete "$name" --region="$region" --project="$project" --quiet 2>/dev/null || true
        else
            gcloud compute forwarding-rules delete "$name" --global --project="$project" --quiet 2>/dev/null || true
        fi
    done

    # 2. Target TCP proxies (reference backend services)
    gcloud compute target-tcp-proxies list --project="$project" --filter="$filter" \
        --format='value(name)' 2>/dev/null | while read -r name; do
        [[ -n "$name" ]] || continue
        echo "  Deleting target TCP proxy: $name"
        gcloud compute target-tcp-proxies delete "$name" --project="$project" --quiet 2>/dev/null || true
    done

    # 3. Backend services (reference instance groups)
    echo "$backend_services" | while read -r name; do
        [[ -n "$name" ]] || continue
        echo "  Deleting backend service: $name"
        gcloud compute backend-services delete "$name" --global --project="$project" --quiet 2>/dev/null || true
    done

    # 4. Instance groups (now unblocked)
    echo "$instance_groups" | while IFS=$'\t' read -r name zone; do
        [[ -n "$name" ]] || continue
        echo "  Deleting instance group: $name (zone: $zone)"
        gcloud compute instance-groups unmanaged delete "$name" --zone="$zone" --project="$project" --quiet 2>/dev/null || true
    done

    # 5. Health checks
    gcloud compute health-checks list --project="$project" --filter="$filter" \
        --format='value(name)' 2>/dev/null | while read -r name; do
        [[ -n "$name" ]] || continue
        echo "  Deleting health check: $name"
        gcloud compute health-checks delete "$name" --project="$project" --quiet 2>/dev/null || true
    done

    echo "INFO: Orphaned GCP resource cleanup complete"
}