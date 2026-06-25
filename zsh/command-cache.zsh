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
# Usage: cache-file-expired <file> [max_age_seconds]
cache-file-expired() {
  local file="$1"
  local max_age="${2:-$CACHE_TTL_DEFAULT}"

  if [[ ! -f "$file" ]]; then
    return 0  # Cache expired (file doesn't exist)
  fi

  # Use ZSH native extended globbing to efficiently check if file is older than max_age
  # without spawning external `stat` and `date` subprocesses.
  setopt local_options extended_glob
  local -a expired_files
  expired_files=("$file"(#qN.ms+${max_age}))

  if (( ${#expired_files} )); then
    return 0  # Cache expired
  else
    return 1  # Cache still valid
  fi
}

# Backward-compatible aliases
cache_file_expired() { cache-file-expired "$@"; }
command-cache-expired() { cache-file-expired "$@"; }
command_cache_expired() { cache-file-expired "$@"; }
completion-cache-expired() { cache-file-expired "${1}" "${2:-$CACHE_TTL_COMPLETION}"; }
completion_cache_expired() { cache-file-expired "${1}" "${2:-$CACHE_TTL_COMPLETION}"; }

# Function to execute a command with caching
# Usage: cached-exec [cache_time_seconds] [cache_key] command_to_run
cached-exec() {
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
    local cache_key
    cache_key=$(printf '%s' "$*" | md5 2>/dev/null || printf '%s' "$*" | md5sum 2>/dev/null | awk '{print $1}')
  fi

  local cache_file="$ZSH_COMMAND_CACHE_DIR/${cache_key}"
  
  # Skip caching in VS Code terminals to avoid disk writes during editing
  if [[ "$TERM_PROGRAM" == "vscode" && -f "$cache_file" ]]; then
    cat "$cache_file"
    return $?
  fi

  # Check if cache is valid
  if ! cache-file-expired "$cache_file" "$cache_time"; then
    cat "$cache_file"
    return $?
  fi

  # Run command and cache output
  mkdir -p "${cache_file:h}" || { echo "Warning: Failed to create cache directory ${cache_file:h}" >&2; "$@"; return $?; }
  "$@" | tee "${cache_file}.tmp"
  local exit_code=${pipestatus[1]}
  
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
alias cache='cached-exec'
cached_exec() { cached-exec "$@"; }

# Function to view cache status
command-cache-status() {
  echo "Command cache directory: $ZSH_COMMAND_CACHE_DIR"
  echo "Cache files:"
  
  if [[ -d "$ZSH_COMMAND_CACHE_DIR" ]]; then
    local file
    for file in "$ZSH_COMMAND_CACHE_DIR"/*(N); do
      if [[ -f "$file" ]]; then
        local modified size
        modified=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$file" 2>/dev/null || stat -c "%y" "$file" 2>/dev/null | cut -d'.' -f1)
        size=$(du -h "$file" | cut -f1)
        local name="${file:t}"
        echo "  $name ($size) - Last updated: $modified"
      fi
    done
  else
    echo "  No cache directory found"
  fi
}

# Function to clear command cache
command-cache-clear() {
  echo "Clearing command cache..."
  rm -rf "$ZSH_COMMAND_CACHE_DIR"/*
  mkdir -p "$ZSH_COMMAND_CACHE_DIR"
  echo "Command cache cleared"
}
command_cache_status() { command-cache-status "$@"; }
command_cache_clear() { command-cache-clear "$@"; }

# -- Command existence caching (in-memory) --
# Avoids repeated PATH lookups during shell initialization

typeset -gA _command_cache

# Check if a command exists (cached in-memory)
has-command() {
    local cmd="$1"
    if [[ -z "${_command_cache[$cmd]+x}" ]]; then
        if command -v "$cmd" >/dev/null 2>&1; then
            _command_cache[$cmd]=1
        else
            _command_cache[$cmd]=0
        fi
    fi
    return $(( 1 - $_command_cache[$cmd] ))
}
has_command() { has-command "$@"; }

# has-command lazily caches results in _command_cache on first use per session

# Example usage:
# cache 3600 kubectl-get-pods kubectl get pods  # Cache for 1 hour with explicit key
# cache 86400 "ls -la"                          # Cache for 1 day with command as key
# cache ls -la                                  # Cache for default time (1h)
