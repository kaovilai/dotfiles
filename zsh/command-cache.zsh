#!/bin/zsh
# command-cache.zsh - Unified caching infrastructure for commands and completions

# Configurable TTL constants (seconds)
export CACHE_TTL_DEFAULT=3600       # 1 hour - command output cache
export CACHE_TTL_COMPLETION=604800  # 7 days - completion generation
export CACHE_TTL_STABLE=2592000     # 30 days - stable tool completions (docker, podman)

# Cache directories
export ZSH_COMMAND_CACHE_DIR="$HOME/.zsh-command-cache"
export ZSH_COMPLETION_CACHE_DIR="$HOME/.zsh-completion-cache"
[[ -d $ZSH_COMMAND_CACHE_DIR ]] || mkdir -p "$ZSH_COMMAND_CACHE_DIR"
[[ -d $ZSH_COMPLETION_CACHE_DIR ]] || mkdir -p "$ZSH_COMPLETION_CACHE_DIR"

# Unified function to check if a cache file is expired
# Usage: cache_file_expired <file> [max_age_seconds]
cache_file_expired() {
  local file="$1"
  local max_age="${2:-$CACHE_TTL_DEFAULT}"

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

# Backward-compatible aliases
command_cache_expired() { cache_file_expired "$@"; }
completion_cache_expired() { cache_file_expired "${1}" "${2:-$CACHE_TTL_COMPLETION}"; }

# Function to execute a command with caching
# Usage: cached_exec [cache_time_seconds] [cache_key] command_to_run
cached_exec() {
  # Check if first argument is a number (cache time)
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    local cache_time="$1"
    shift
  else
    local cache_time=3600  # Default: 1 hour
  fi

  # Check if second argument doesn't start with a dash (cache key)
  if [[ "$1" && "$1" != -* ]]; then
    local cache_key="$1"
    shift
  else
    # Generate cache key from command
    local cache_key=$(echo "$*" | md5)
  fi

  local cache_file="$ZSH_COMMAND_CACHE_DIR/${cache_key}"
  
  # Skip caching in VS Code terminals to avoid disk writes during editing
  if [[ "$TERM_PROGRAM" == "vscode" && -f "$cache_file" ]]; then
    cat "$cache_file"
    return $?
  fi

  # Check if cache is valid
  if ! command_cache_expired "$cache_file" "$cache_time"; then
    cat "$cache_file"
    return $?
  fi

  # Run command and cache output
  mkdir -p "$(dirname "$cache_file")"
  "$@" | tee "${cache_file}.tmp"
  local exit_code=${PIPESTATUS[0]}
  
  if [[ $exit_code -eq 0 ]]; then
    mv "${cache_file}.tmp" "$cache_file"
  else
    rm -f "${cache_file}.tmp"
    # If command failed but cache exists, use cached version
    if [[ -f "$cache_file" ]]; then
      echo "Warning: Command failed, using cached version" >&2
      cat "$cache_file"
      return $?
    fi
  fi
  
  return $exit_code
}

# Alias for more readable usage
alias cache='cached_exec'

# Function to view cache status
command_cache_status() {
  echo "Command cache directory: $ZSH_COMMAND_CACHE_DIR"
  echo "Cache files:"
  
  if [[ -d "$ZSH_COMMAND_CACHE_DIR" ]]; then
    for file in $ZSH_COMMAND_CACHE_DIR/*; do
      if [[ -f "$file" ]]; then
        local modified=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$file")
        local size=$(du -h "$file" | cut -f1)
        local name=$(basename "$file")
        echo "  $name ($size) - Last updated: $modified"
      fi
    done
  else
    echo "  No cache directory found"
  fi
}

# Function to clear command cache
command_cache_clear() {
  echo "Clearing command cache..."
  rm -rf "$ZSH_COMMAND_CACHE_DIR"/*
  mkdir -p "$ZSH_COMMAND_CACHE_DIR"
  echo "Command cache cleared"
}

# -- Command existence caching (in-memory) --
# Avoids repeated PATH lookups during shell initialization

typeset -gA _command_cache

# Check if a command exists (cached in-memory)
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

# Example usage:
# cache 3600 kubectl-get-pods kubectl get pods  # Cache for 1 hour with explicit key
# cache 86400 "ls -la"                          # Cache for 1 day with command as key
# cache ls -la                                  # Cache for default time (1h)
