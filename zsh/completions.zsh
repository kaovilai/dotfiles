#compdef kubectl
compdef _kubectl kubectl

# Cache settings
export ZSH_COMPLETION_CACHE_DIR="$HOME/.zsh-completion-cache"
[[ -d $ZSH_COMPLETION_CACHE_DIR ]] || mkdir -p "$ZSH_COMPLETION_CACHE_DIR"

# Google Cloud SDK configuration - consolidated
if [ -f '/Users/tiger/google-cloud-sdk/path.zsh.inc' ]; then 
  source '/Users/tiger/google-cloud-sdk/path.zsh.inc'
fi
if [ -f '/Users/tiger/google-cloud-sdk/completion.zsh.inc' ]; then 
  source '/Users/tiger/google-cloud-sdk/completion.zsh.inc'
fi

# Function to check if completion file cache is expired
completion_cache_expired() {
  local file="$1"
  local max_age="${2:-604800}"  # Default: 7 days in seconds (configurable)

  if [[ ! -f "$file" ]]; then
    return 0  # Cache expired (file doesn't exist)
  fi

  # Get file modification time
  local file_time=$(stat -f %m "$file")
  local current_time=$(date +%s)
  local file_age=$((current_time - file_time))

  if [[ $file_age -gt $max_age ]]; then
    return 0  # Cache expired
  else
    return 1  # Cache still valid
  fi
}

# Function to cache command completion output
cache_command_completion() {
  local cmd="$1"
  local completion_args="$2"
  local cache_file="$ZSH_COMPLETION_CACHE_DIR/_${cmd}"
  local max_age="${3:-604800}"  # Default: 7 days, configurable in seconds
  
  # Skip in VS Code terminals to avoid slowdowns during editing
  if [[ "$TERM_PROGRAM" == "vscode" ]]; then
    if [[ -f "$cache_file" ]]; then
      source "$cache_file"
      return
    else
      # In VS Code, generate but don't cache if file doesn't exist
      eval "$cmd $completion_args" > /dev/null 2>&1
      return
    fi
  fi
  
  # Check if we need to regenerate the cache
  if completion_cache_expired "$cache_file" "$max_age"; then
    # Generate completion in background to avoid shell startup delays
    (eval "$cmd $completion_args" > "${cache_file}.tmp" 2>/dev/null &&
     mv "${cache_file}.tmp" "$cache_file" ||
     rm -f "${cache_file}.tmp") &
  fi
  
  # Use cached file if it exists
  [[ -f "$cache_file" ]] && source "$cache_file"
}

# Cache openshift-install completion separately since it's already stored as a file
if [ "$(command -v openshift-install)" ]; then
  znap eval openshift-install-completion "cat /Users/tiger/git/dotfiles/openshift-install-completion-zsh.txt"
  compdef _openshift-install openshift-install
fi

# Use znap eval for command completions
if [ "$(command -v oc)" ]; then
  znap eval oc-completion "oc completion zsh"
  compdef _oc oc
fi

if [ "$(command -v gh)" ]; then
  znap eval gh-completion "gh completion -s zsh"
  compdef _gh gh
fi

# Docker completion - use centralized cache location
if [ "$(command -v docker)" ]; then
  local docker_completion_file="$ZSH_COMPLETION_CACHE_DIR/_docker"
  if [[ "$TERM_PROGRAM" != "vscode" ]]; then
    if completion_cache_expired "$docker_completion_file" 2592000; then  # 30 days for stable tools
      # Download completion file in the background
      (curl -sLm 10 https://raw.githubusercontent.com/docker/docker-ce/master/components/cli/contrib/completion/zsh/_docker > "${docker_completion_file}.tmp" && 
      mv "${docker_completion_file}.tmp" "$docker_completion_file" || 
      (rm -f "${docker_completion_file}.tmp"; echo "Failed to download docker completion")) &
    fi
  fi
  
  # Source existing completion file (even if it's being updated)
  if [[ -f "$docker_completion_file" ]]; then
    source "$docker_completion_file"
    compdef _docker docker
  fi
fi

# Podman completion - use centralized cache location
if [ -n "$(command -v podman)" ]; then
  local podman_completion_file="$ZSH_COMPLETION_CACHE_DIR/_podman"
  if [[ "$TERM_PROGRAM" != "vscode" ]]; then
    if completion_cache_expired "$podman_completion_file" 2592000; then  # 30 days for stable tools
      # Download completion file in the background
      (curl -sLm 10 https://raw.githubusercontent.com/containers/podman/main/completions/zsh/_podman > "${podman_completion_file}.tmp" && 
      mv "${podman_completion_file}.tmp" "$podman_completion_file" || 
      (rm -f "${podman_completion_file}.tmp"; echo "Failed to download podman completion")) &
    fi
  fi
  
  # Source existing completion file (even if it's being updated)
  if [[ -f "$podman_completion_file" ]]; then
    source "$podman_completion_file"
    compdef _podman podman
  fi
fi

# AWS uses its own completer mechanism
if [ "$(command -v aws_completer)" ]; then
  complete -C aws_completer aws
fi

# Use znap eval for command completions that change frequently
if [ "$(command -v rosa)" ]; then
  znap eval rosa-completion "rosa completion zsh"
  compdef _rosa rosa
fi

# if [ "$(command -v crc)" ]; then
#   znap eval crc-completion "crc completion zsh"
#   compdef _crc crc
# fi

if [ "$(command -v ccoctl)" ]; then
  znap eval ccoctl-completion "ccoctl completion zsh"
  compdef _ccoctl ccoctl
fi

# if [ "$(command -v glab)" ]; then
#   znap eval glab-completion "glab completion -s zsh"
#   compdef _glab glab
# fi

if [ "$(command -v velero)" ]; then
  znap eval velero-completion "velero completion zsh"
  compdef _velero velero
fi

# if [ "$(command -v colima)" ]; then
#   znap eval colima-completion "colima completion zsh"
#   compdef _colima colima
# fi

# if [ "$(command -v kubebuilder)" ]; then
#   znap eval kubebuilder-completion "kubebuilder completion zsh"
#   compdef _kubebuilder kubebuilder
# fi

if [ "$(command -v yq)" ]; then
  znap eval yq-completion "yq completion zsh"
  compdef _yq yq
fi

# kind completion zsh
if [ "$(command -v kind)" ]; then
  znap eval kind-completion "kind completion zsh"
  compdef _kind kind
fi

# IBM Cloud completion
if [[ -f /usr/local/ibmcloud/autocomplete/zsh_autocomplete ]]; then
  znap source /usr/local/ibmcloud/autocomplete/zsh_autocomplete
fi

# Cache pipenv completion
znap eval pipenv-completion "_PIPENV_COMPLETE=zsh_source pipenv"

# for cline
[[ "$TERM_PROGRAM" == "vscode" ]] && . "$(code --locate-shell-integration-path zsh)"

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
