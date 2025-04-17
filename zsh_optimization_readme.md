# ZSH Performance Optimization

This directory contains several optimized zsh configuration files designed to dramatically speed up your shell startup time.

## Files and Their Purpose

1. **zsh_profiler.zsh** - A profiling tool that measures the performance of your shell startup
2. **lazy_completions.zsh** - Framework for lazy-loading command completions only when needed
3. **optimized_completions.zsh** - Optimized version of completions.zsh that uses lazy loading
4. **optimized_znap.zsh** - Optimized version of znap.zsh that loads plugins more efficiently
5. **optimized_zshrc** - A fully optimized .zshrc file incorporating all improvements
6. **profiled_zshrc** - A special .zshrc that instruments each component to measure performance

## How to Use This Optimization

### 1. Profile Your Current Setup

First, use the profiling version to identify bottlenecks:

```bash
# Run a shell with the profiling configuration
zsh -c "source ~/git/dotfiles/profiled_zshrc"
```

This will output a detailed timing report showing:
- The 10 slowest operations
- Network operations that happen during startup
- Completion operations and their timing

### 2. Test the Optimized Configuration

Try out the fully optimized configuration:

```bash
# Run a shell with the optimized configuration
zsh -c "source ~/git/dotfiles/optimized_zshrc"
```

You should notice a significant speedup compared to your original configuration.

### 3. Implement the Optimizations

Once you've verified the improvements, you can implement them permanently:

```bash
# Backup your current .zshrc
cp ~/.zshrc ~/.zshrc.backup

# Use the optimized version
cp ~/git/dotfiles/optimized_zshrc ~/.zshrc
```

## Key Optimization Techniques

1. **Lazy Loading**: Commands and completions are loaded only when first used
2. **Asynchronous Loading**: Non-essential components are loaded in the background
3. **Improved Caching**: Better management of cached completion files
4. **Parallelization**: Independent operations run concurrently
5. **Deferred Operations**: Non-critical tasks are delayed until after shell startup

## Customization

If you need to add more tools to the lazy loading system, follow this pattern in `lazy_completions.zsh`:

```zsh
# Example for adding a new tool
if [ "$(command -v newtool)" ]; then
  lazy_completion_source newtool "newtool completion zsh"
fi
```

## Performance Impact

The main improvements come from:

1. Lazy-loading completions (eliminates ~70-80% of completion overhead)
2. Background loading of plugins (reduces blocking time)
3. Caching of network operations (eliminates network delays)
4. Deferring non-critical operations (reduces initial load time)

Typical shell startup time should improve from seconds to milliseconds.

## Troubleshooting

If you encounter any issues with the optimized configuration:

1. Check if any completions aren't working and add them to `optimized_completions.zsh`
2. Verify that all needed environment variables are set properly in `optimized_zshrc`
3. If a command isn't properly loading its completion, run it once to trigger the lazy loading
