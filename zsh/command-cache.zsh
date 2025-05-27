#!/bin/zsh
# command-cache.zsh - Enhanced command output caching

# Directory for cached command outputs
export ZSH_COMMAND_CACHE_DIR="$HOME/.zsh-command-cache"
[[ -d $ZSH_COMMAND_CACHE_DIR ]] || mkdir -p "$ZSH_COMMAND_CACHE_DIR"

# Function to check if cache is expired (shared with completions.zsh)
command_cache_expired() {
  local file="$1"
  local max_age="${2:-3600}"  # Default: 1 hour in seconds (configurable)

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

# Example usage:
# cache 3600 kubectl-get-pods kubectl get pods  # Cache for 1 hour with explicit key
# cache 86400 "ls -la"                          # Cache for 1 day with command as key
# cache ls -la                                  # Cache for default time (1h)
