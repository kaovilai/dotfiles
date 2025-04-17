# Shell Initialization Optimization

This directory contains Zsh configuration files optimized for fast startup and efficient operation.

## Parallelization Strategy

Shell initialization has been optimized using the following strategies:

### 1. Split Initialization into Phases

- **Essential Phase (Foreground)**: Critical components that affect immediate shell usability
- **Non-Essential Phase (Background)**: Components that can be loaded after the prompt is ready

### 2. Background Processing

Several techniques are used for background initialization:
- Background jobs using `&` or `&!` (disowned jobs) for non-blocking operations
- Nested background jobs for multi-phase loading with prioritization
- Low priority background jobs using `nice` when available

### 3. Async File Processing

- Plugin initialization is split into immediate and deferred loading
- Completion generation happens asynchronously
- Cache updates occur in background processes

## Key Files

- **`.zshrc`**: Orchestrates the loading sequence, separating essential and non-essential operations
- **`znap.zsh`**: Manages plugin loading with prioritization and async initialization
- **`completions.zsh`**: Implements multi-phase completion loading with priority-based scheduling
- **`command-cache.zsh`**: Provides caching infrastructure for expensive command outputs

## Implementation Details

### Background Job Management

The shell uses `&!` to disown background jobs, preventing them from being terminated when the shell exits. This is used for operations that should continue even if the terminal is closed.

### Tiered Loading

1. **Critical UI components** (prompt, syntax highlighting) load in the foreground
2. **Essential utilities** (basic aliases, path setup) load in the foreground
3. **Primary functionality** (git, command-line tools) loads in first background phase
4. **Secondary functionality** (completions, documentation helpers) loads in second background phase

### Completion System

The completion system has been optimized for maximum efficiency:

1. **Immediate**: Only the most critical completions load in the foreground (VS Code integration, AWS completer, Docker)
2. **Lazy-loaded**: Most completions use `znap function` for truly on-demand loading:
   - Each completion is defined as a function that only executes when the command is called or completion is attempted
   - No wasted resources on completions for commands that aren't used in a session
   - Completions only initialize once when needed, then stay available for the session

Using `znap function` instead of `znap eval` ensures completions are only loaded when actually needed, further reducing initialization overhead.
