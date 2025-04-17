#compdef kubectl
compdef _kubectl kubectl

# Google Cloud SDK configuration - consolidated
if [ -f '/Users/tiger/google-cloud-sdk/path.zsh.inc' ]; then 
  source '/Users/tiger/google-cloud-sdk/path.zsh.inc'
fi
if [ -f '/Users/tiger/google-cloud-sdk/completion.zsh.inc' ]; then 
  source '/Users/tiger/google-cloud-sdk/completion.zsh.inc'
fi

if [ "$(command -v oc)" ]; then
  source <(oc completion zsh)
  compdef _oc oc
fi

if [ "$(command -v gh)" ]; then
  source <(gh completion -s zsh)
  compdef _gh gh
fi
# Function to check if completion file cache is older than 7 days
completion_cache_expired() {
  local file="$1"
  local max_age=604800  # 7 days in seconds

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

# Docker completion
if [ "$(command -v docker)" ]; then
  local docker_completion_file=~/_docker
  if [[ "$TERM_PROGRAM" != "vscode" ]]; then
    if completion_cache_expired "$docker_completion_file"; then
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

# Podman completion
if [ -n "$(command -v podman)" ]; then
  local podman_completion_file=~/_podman
  if [[ "$TERM_PROGRAM" != "vscode" ]]; then
    if completion_cache_expired "$podman_completion_file"; then
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

if [ "$(command -v aws_completer)" ]; then
  complete -C aws_completer aws
fi

if [ "$(command -v rosa)" ]; then
  source <(rosa completion zsh)
  compdef _rosa rosa
fi

# if [ "$(command -v crc)" ]; then
#   source <(crc completion zsh)
#   compdef _crc crc
# fi

if [ "$(command -v ccoctl)" ]; then
  source <(ccoctl completion zsh)
  compdef _ccoctl ccoctl
fi

# if [ "$(command -v glab)" ]; then
#   source <(glab completion -s zsh)
#   compdef _glab glab
# fi

if [ "$(command -v velero)" ]; then
  source <(velero completion zsh)
  compdef _velero velero
fi

# if [ "$(command -v colima)" ]; then
#   source <(colima completion zsh)
#   compdef _colima colima
# fi

# if [ "$(command -v kubebuilder)" ]; then
#   source <(kubebuilder completion zsh)
#   compdef _kubebuilder kubebuilder
# fi

if [ "$(command -v yq)" ]; then
  source <(yq completion zsh)
  compdef _yq yq
fi

# kind completion zsh
if [ "$(command -v kind)" ]; then
  source <(kind completion zsh)
  compdef _kind kind
fi

# openshift-installer zshcompletion
if [ "$(command -v openshift-install)" ]; then
  source <(cat /Users/tiger/git/dotfiles/openshift-install-completion-zsh.txt)
  compdef _openshift-install openshift-install
fi

source /usr/local/ibmcloud/autocomplete/zsh_autocomplete

eval "$(_PIPENV_COMPLETE=zsh_source pipenv)"

# for cline
[[ "$TERM_PROGRAM" == "vscode" ]] && . "$(code --locate-shell-integration-path zsh)"
