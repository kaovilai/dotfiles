# ZSH Configuration System

This directory contains the ZSH configuration files for the dotfiles repository.

## Caching System

The shell configuration includes an aggressive caching system to improve performance:

### Completion Caching

Located in `completions.zsh`, this system:
- Caches completion scripts in `~/.zsh-completion-cache/`
- Downloads remote completion files only when needed
- Uses `znap eval` to cache completion command output
- Automatically regenerates caches when they expire
- Skips intensive operations in VS Code terminals

#### Commands:
- `zsh_completion_cache_status`: Shows status of cached completions
- `zsh_completion_cache_clear`: Clears all cached completions

### Command Output Caching

Located in `command-cache.zsh`, this system:
- Caches command outputs in `~/.zsh-command-cache/`
- Uses intelligent caching with configurable timeouts
- Falls back to cached version when commands fail
- Generates cache keys automatically or accepts custom ones

#### Usage:
```zsh
# Basic usage with default timeout (1 hour)
cache ls -la

# Custom timeout (5 minutes) and default key
cache 300 ls -la

# Custom timeout (1 day) and custom key
cache 86400 daily-command-key ls -la
```

#### Commands:
- `command_cache_status`: Shows status of cached command outputs
- `command_cache_clear`: Clears all cached command outputs

### Pre-configured Cached Commands

Located in `cached-commands.zsh`, this provides:
- Ready-to-use cached versions of common commands
- Different cache durations for different types of commands
- Optimized for command-line workflows with Kubernetes, OpenShift, Git, etc.

### znap Caching

Located in `znap.zsh`, this configures:
- Extended cache TTL for znap operations
- Cached initialization of common developer tools
- Optimized plugin loading

## Usage Tips

- Use `cache` for commands that are slow but don't change output frequently
- Use the cached aliases (like `kgp` instead of `kubectl get pods`) for better performance
- Clear caches if you suspect stale information with:
  ```zsh
  zsh_completion_cache_clear
  command_cache_clear
  ```
- VS Code terminals will use cached versions when available but won't update caches

## Cache Duration Reference

- `CACHE_SHORT=300`: For frequently changing outputs (5 minutes)
- `CACHE_MEDIUM=1800`: For moderately changing outputs (30 minutes)
- `CACHE_LONG=3600`: For slowly changing outputs (1 hour)
- `CACHE_VERY_LONG=86400`: For rarely changing outputs (1 day)
