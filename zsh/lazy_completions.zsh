#!/usr/bin/env zsh
# lazy_completions.zsh - Lazy load command completions only when needed

# Utility to create lazy-loaded completion function
# Usage: lazy_completion <command> <completion_generation_command>
lazy_completion() {
  local cmd=$1
  local completion_cmd=$2
  
  # Only create lazy completion function if command exists
  if [[ -z "$(command -v $cmd)" ]]; then
    return
  fi
  
  # Create a function with the same name as the command
  eval "
  function $cmd() {
    # Remove this function, so it's only run once
    unfunction $cmd
    
    # Generate and load the completion
    echo \"Loading completion for $cmd...\"
    $completion_cmd
    
    # Execute the original command with the original parameters
    command $cmd \"\$@\"
  }
  "
}

# Create wrapper for completion functions using source <()
lazy_completion_source() {
  local cmd=$1
  local source_cmd=$2
  
  # Only create if command exists
  if [[ -z "$(command -v $cmd)" ]]; then
    return
  fi
  
  # Create function that loads completion on first use
  eval "
  function $cmd() {
    # Remove this function, so it's only run once
    unfunction $cmd
    
    # Generate and load the completion
    echo \"Loading completion for $cmd...\"
    source <($source_cmd)
    
    # Execute the original command with the original parameters
    command $cmd \"\$@\"
  }
  "
}

# Create a completion file cache with expiration
completion_cache() {
  local cmd=$1        # Command name
  local url=$2        # URL to download completion from
  local expiry=$3     # Cache expiry in seconds (default: 7 days)
  local cache_file=$4 # Cache file location (default: ~/.zsh_completion_cache/cmd)
  
  # Set defaults
  expiry=${expiry:-604800}  # 7 days in seconds
  cache_file=${cache_file:-"$HOME/.zsh_completion_cache/$cmd"}
  
  # Ensure cache directory exists
  mkdir -p "$(dirname "$cache_file")"
  
  # Check if file exists and is not expired
  local should_download=0
  if [[ ! -f "$cache_file" ]]; then
    should_download=1
  else
    # Check if file is older than expiry period
    local file_age=$(($(date +%s) - $(stat -f %m "$cache_file")))
    if ((file_age > expiry)); then
      should_download=1
    fi
  fi
  
  # Download in the background if needed
  if ((should_download == 1)); then
    (curl -sL "$url" > "${cache_file}.tmp" && 
     mv "${cache_file}.tmp" "$cache_file" || 
     rm -f "${cache_file}.tmp") &!
  fi
  
  # Always source the cache file if it exists
  if [[ -f "$cache_file" ]]; then
    source "$cache_file"
  fi
}

# Configure lazy loading for specific commands

# Docker completion
if [ "$(command -v docker)" ]; then
  lazy_completion_source docker "docker completion zsh"
fi

# Podman completion
if [ "$(command -v podman)" ]; then
  lazy_completion_source podman "podman completion zsh"
fi

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

# This section was removed as it was a duplicate function definition
