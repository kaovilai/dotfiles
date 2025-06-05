
# Cache settings
export ZSH_COMPLETION_CACHE_DIR="$HOME/.zsh-completion-cache"
[[ -d $ZSH_COMPLETION_CACHE_DIR ]] || mkdir -p "$ZSH_COMPLETION_CACHE_DIR"

# Function to check if completion file cache is expired
completion_cache_expired() {
  local file="$1"
  local max_age="${2:-604800}"  # Default: 7 days in seconds (configurable)

  if [[ ! -f "$file" ]]; then
    return 0  # Cache expired (file doesn't exist)
  fi

  # Get file modification time (cache stat result to avoid duplicate calls)
  local file_stat=$(stat -f "%m %Sm" -t "%Y-%m-%d %H:%M:%S" "$file" 2>/dev/null) || return 0
  local file_time=${file_stat%% *}
  local current_time=$(date +%s)
  local file_age=$((current_time - file_time))

  if [[ $file_age -gt $max_age ]]; then
    return 0  # Cache expired
  else
    return 1  # Cache still valid
  fi
}

# -- PHASE 1: Essential completions (foreground) --

# VS Code shell integration (if we're running in VS Code)
[[ "$TERM_PROGRAM" == "vscode" ]] && . "$(code --locate-shell-integration-path zsh)"

# Source command cache helper
source ~/git/dotfiles/zsh/cached-commands.zsh

# AWS uses its own completer mechanism (critical for AWS workflows)
if has_command aws_completer; then
  complete -C aws_completer aws
fi

# Docker completion - use centralized cache location (most commonly used)
if has_command docker; then
  local docker_completion_file="$ZSH_COMPLETION_CACHE_DIR/_docker"
  if [[ -f "$docker_completion_file" ]]; then
    cat "$docker_completion_file" > "${fpath[1]}/_docker" &!
  fi
  
  # Update check and download in the background
  if [[ "$TERM_PROGRAM" != "vscode" ]]; then
    if completion_cache_expired "$docker_completion_file" 2592000; then  # 30 days for stable tools
      (curl -sLm 10 https://raw.githubusercontent.com/docker/docker-ce/master/components/cli/contrib/completion/zsh/_docker > "${docker_completion_file}.tmp" && 
      mv "${docker_completion_file}.tmp" "$docker_completion_file" || 
      rm -f "${docker_completion_file}.tmp") &!
    fi
  fi
fi

# -- PHASE 2: Direct completion generation --
# Each completion is generated and written to fpath directly

# OpenShift Install - uses cached file to avoid generating completion on every shell start
if has_command openshift-install; then
  cat ~/git/dotfiles/openshift-install-completion-zsh.txt > "${fpath[1]}/_openshift-install" &!
fi

# GitHub CLI completion - cache for stable tools
if has_command gh; then
  local gh_completion_cache="$ZSH_COMPLETION_CACHE_DIR/_gh_generated"
  if completion_cache_expired "$gh_completion_cache" 604800; then  # 7 days
    gh completion -s zsh > "$gh_completion_cache" 2>/dev/null
  fi
  [[ -f "$gh_completion_cache" ]] && cat "$gh_completion_cache" > "${fpath[1]}/_gh" &!
fi

# Kubernetes CLI - cache for stable tools
if has_command kubectl; then
  local kubectl_completion_cache="$ZSH_COMPLETION_CACHE_DIR/_kubectl_generated"
  if completion_cache_expired "$kubectl_completion_cache" 604800; then  # 7 days
    kubectl completion zsh > "$kubectl_completion_cache" 2>/dev/null
  fi
  [[ -f "$kubectl_completion_cache" ]] && cat "$kubectl_completion_cache" > "${fpath[1]}/_kubectl" &!
fi

# OpenShift Client - cache for stable tools
if has_command oc; then
  local oc_completion_cache="$ZSH_COMPLETION_CACHE_DIR/_oc_generated"
  if completion_cache_expired "$oc_completion_cache" 604800; then  # 7 days
    oc completion zsh > "$oc_completion_cache" 2>/dev/null
  fi
  [[ -f "$oc_completion_cache" ]] && cat "$oc_completion_cache" > "${fpath[1]}/_oc" &!
fi

# Podman completion - use centralized cache location
if [ -n "$(command -v podman)" ]; then
  local podman_completion_file="$ZSH_COMPLETION_CACHE_DIR/_podman"
  
  if [[ -f "$podman_completion_file" ]]; then
    cat "$podman_completion_file" > "${fpath[1]}/_podman" &!
  fi
  
  # Update check and download in the background
  if [[ "$TERM_PROGRAM" != "vscode" ]]; then
    if completion_cache_expired "$podman_completion_file" 2592000; then  # 30 days for stable tools
      (curl -sLm 10 https://raw.githubusercontent.com/containers/podman/main/completions/zsh/_podman > "${podman_completion_file}.tmp" && 
      mv "${podman_completion_file}.tmp" "$podman_completion_file" || 
      rm -f "${podman_completion_file}.tmp") &!
    fi
  fi
fi

# Rosa CLI
if [ "$(command -v rosa)" ]; then
  rosa completion zsh > "${fpath[1]}/_rosa" &!
fi

# CCOCTL
if [ "$(command -v ccoctl)" ]; then
  ccoctl completion zsh > "${fpath[1]}/_ccoctl" &!
fi

# Velero
if [ "$(command -v velero)" ]; then
  velero completion zsh > "${fpath[1]}/_velero" &!
fi

# YQ
if [ "$(command -v yq)" ]; then
  yq completion zsh > "${fpath[1]}/_yq" &!
fi

# Kind
if [ "$(command -v kind)" ]; then
  kind completion zsh > "${fpath[1]}/_kind" &!
fi

# Google Cloud SDK configuration - lazy load only when gcloud is needed
if [ -f '~/google-cloud-sdk/path.zsh.inc' ] && [ -f '~/google-cloud-sdk/completion.zsh.inc' ]; then
  # Create a lazy-loading wrapper for gcloud
  gcloud() {
    unfunction gcloud
    source '~/google-cloud-sdk/path.zsh.inc'
    source '~/google-cloud-sdk/completion.zsh.inc'
    gcloud "$@"
  }
fi

# Pipenv
if [ "$(command -v pipenv)" ]; then
  _PIPENV_COMPLETE=zsh_source pipenv > "${fpath[1]}/_pipenv" &!
fi

# IBM Cloud completion - if needed
if [[ -f /usr/local/ibmcloud/autocomplete/zsh_autocomplete ]]; then
  cat /usr/local/ibmcloud/autocomplete/zsh_autocomplete > "${fpath[1]}/_ibmcloud" &!
fi

# Custom code-git completion
cat << EOF > "${fpath[1]}/_code-git" &!
#compdef code-git

_code-git() {
    local -a files
    files=(\${(f)"\$(ls ~/git)"})
    _describe 'files' files
}

_code-git
EOF

# Help command to view cache status
zsh_completion_cache_status() {
  echo "ZSH completion cache directory: $ZSH_COMPLETION_CACHE_DIR"
  echo "Cache files:"
  for file in $ZSH_COMPLETION_CACHE_DIR/_*; do
    if [[ -f "$file" ]]; then
      local modified=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$file")
      local size=$(du -h "$file" | cut -f1)
      local name=$(basename "$file")
      echo "  $name ($size) - Last updated: $modified"
    fi
  done
}

# Command to clear the completion cache
zsh_completion_cache_clear() {
  echo "Clearing ZSH completion cache..."
  rm -f $ZSH_COMPLETION_CACHE_DIR/_*
  echo "Cache cleared. Restart your shell to regenerate completions."
}
