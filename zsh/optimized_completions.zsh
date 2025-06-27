#!/usr/bin/env zsh
# optimized_completions.zsh - Optimized version of completions.zsh
# This file uses lazy loading to dramatically speed up shell startup

# Load the lazy completions framework
source ~/git/dotfiles/zsh/lazy_completions.zsh

# Create completion cache directory
mkdir -p ~/.zsh_completion_cache

# Essential completions that should be loaded immediately
autoload -Uz compinit
compinit -C

# Google Cloud SDK - load only if files exist, but don't lazy load as these are paths
if [ -f '/Users/tiger/google-cloud-sdk/path.zsh.inc' ]; then 
  source '/Users/tiger/google-cloud-sdk/path.zsh.inc'
fi
if [ -f '/Users/tiger/google-cloud-sdk/completion.zsh.inc' ]; then 
  source '/Users/tiger/google-cloud-sdk/completion.zsh.inc'
fi

# Docker completion - use improved caching mechanism
if [ "$(command -v docker)" ]; then
  local docker_completion_file=~/.zsh_completion_cache/_docker
  completion_cache docker "https://raw.githubusercontent.com/docker/docker-ce/master/components/cli/contrib/completion/zsh/_docker" 604800 "$docker_completion_file"
fi

# Podman completion - use improved caching mechanism
if [ -n "$(command -v podman)" ]; then
  local podman_completion_file=~/.zsh_completion_cache/_podman
  completion_cache podman "https://raw.githubusercontent.com/containers/podman/main/completions/zsh/_podman" 604800 "$podman_completion_file"
fi

# Lazy load all other completions

# OpenShift CLI completion
if [ "$(command -v oc)" ]; then
  lazy_completion_source oc "oc completion zsh"
fi

# GitHub CLI completion
if [ "$(command -v gh)" ]; then
  lazy_completion_source gh "gh completion -s zsh"
fi

# AWS CLI completion
if [ "$(command -v aws_completer)" ]; then
  lazy_completion aws "complete -C aws_completer aws"
fi

# Red Hat OpenShift Service on AWS
if [ "$(command -v rosa)" ]; then
  lazy_completion_source rosa "rosa completion zsh"
fi

# Code Ready Containers
if [ "$(command -v crc)" ]; then
  lazy_completion_source crc "crc completion zsh"
fi

# OpenShift Cloud Credential Operator utility
if [ "$(command -v ccoctl)" ]; then
  lazy_completion_source ccoctl "ccoctl completion zsh"
fi

# Velero CLI completion
if [ "$(command -v velero)" ]; then
  lazy_completion_source velero "velero completion zsh"
fi

# Colima completion
if [ "$(command -v colima)" ]; then
  lazy_completion_source colima "colima completion zsh"
fi

# Kubebuilder completion
if [ "$(command -v kubebuilder)" ]; then
  lazy_completion_source kubebuilder "kubebuilder completion zsh"
fi

# yq completion
if [ "$(command -v yq)" ]; then
  lazy_completion_source yq "yq completion zsh"
fi

# kind completion
if [ "$(command -v kind)" ]; then
  lazy_completion_source kind "kind completion zsh"
fi

# openshift-install completion - special case since it uses a file
if [ "$(command -v openshift-install)" ]; then
  openshift_install_completion_file=~/.zsh_completion_cache/_openshift-install
  if [[ ! -f "$openshift_install_completion_file" ]]; then
    cp /Users/tiger/git/dotfiles/openshift-install-completion-zsh.txt "$openshift_install_completion_file"
  fi
  source "$openshift_install_completion_file"
  compdef _openshift-install openshift-install
fi

# IBM Cloud - can't easily be lazy-loaded because it's a direct source
if [ -f "/usr/local/ibmcloud/autocomplete/zsh_autocomplete" ]; then
  source /usr/local/ibmcloud/autocomplete/zsh_autocomplete
fi

# pipenv completion - special handling as it uses eval
if [ "$(command -v pipenv)" ]; then
  # We create a wrapper function that loads completion on first use
  function pipenv() {
    # Remove this function
    unfunction pipenv
    
    # Load completion
    echo "Loading completion for pipenv..."
    eval "$(_PIPENV_COMPLETE=zsh_source pipenv)"
    
    # Execute the command
    command pipenv "$@"
  }
fi

# VSCode shell integration - only load if in VSCode
if [[ "$TERM_PROGRAM" == "vscode" && "$(command -v code)" ]]; then
  code_shell_path="$(code --locate-shell-integration-path zsh 2>/dev/null)"
  if [[ -n "$code_shell_path" ]]; then
    source "$code_shell_path"
  fi
fi
