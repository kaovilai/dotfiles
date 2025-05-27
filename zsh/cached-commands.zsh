# Cache command existence checks to avoid repeated PATH lookups
# This is sourced early in shell initialization

typeset -gA _command_cache

# Function to check if a command exists (cached)
has_command() {
    local cmd=$1
    if [[ -z "${_command_cache[$cmd]+x}" ]]; then
        if command -v "$cmd" >/dev/null 2>&1; then
            _command_cache[$cmd]=1
        else
            _command_cache[$cmd]=0
        fi
    fi
    return $(( 1 - $_command_cache[$cmd] ))
}

# Pre-cache common commands during shell startup
for cmd in docker podman kubectl oc gh aws gcloud rosa velero yq kind pipenv pyenv nvm; do
    has_command "$cmd" &
done
wait