---
name: zsh-pitfalls
description: Detect and fix common ZSH scripting pitfalls — subshell variable loss, env var leaks, scope bugs, and ZSH-vs-Bash differences. Use when writing, reviewing, or debugging ZSH functions.
triggers:
  - zsh
  - .zsh
  - shell function
  - env var
  - subshell
  - source
---

# ZSH Pitfalls

Catch common ZSH bugs before they bite. This skill covers pitfalls specific to ZSH that differ from Bash behavior.

## 1. Subshell Variable Loss

**Bug:** `export` inside `$()` command substitution does NOT propagate to the parent shell.

```zsh
# BROKEN — variable set inside subshell, lost when $() exits
my-func() {
    export SELECTED_VERSION="$version"  # lost!
    echo "$stream"                       # only this reaches caller
}
result=$(my-func)  # SELECTED_VERSION is empty here
```

**Fix:** Return all values on stdout, parse in caller.

```zsh
# CORRECT — return multiple values via stdout
my-func() {
    echo "$stream $version"  # both values on stdout
}
local output=$(my-func)
local stream=${output%% *}
local version=${output#* }
```

**Alternative:** Call without command substitution if only side effects needed.

```zsh
# CORRECT — no subshell, exports propagate
my-func   # called directly, not inside $()
```

**Detection checklist:**
- Function called as `var=$(func)` AND function uses `export`/sets global vars → bug
- Function called as `var=$(func)` AND function reads from `/dev/tty` → OK (interactive input works)
- `>&2` output works fine inside `$()` (stderr is not captured)

## 2. Environment Variable Leaks on Failure

**Bug:** `export VAR=value` without cleanup on ALL exit paths leaks into the shell session.

```zsh
# BROKEN — VAR leaks if anything between export and unset fails
my-func() {
    export OVERRIDE="$image"
    some-command || return 1   # leaked!
    another-command || return 1  # leaked!
    unset OVERRIDE  # only reached on success
}
```

**Fix:** Unset on every exit path, or clear at function entry.

```zsh
# CORRECT — cleanup on all paths
my-func() {
    export OVERRIDE="$image"
    if ! some-command; then
        unset OVERRIDE
        return 1
    fi
    if ! another-command; then
        unset OVERRIDE
        return 1
    fi
    unset OVERRIDE
}
```

```zsh
# ALSO CORRECT — clear stale values at entry
my-func() {
    unset OVERRIDE  # clear from previous failed runs
    # ... later ...
    export OVERRIDE="$image"
    # ...
    unset OVERRIDE
}
```

**Detection checklist:**
- `export VAR` in a function → find ALL `return` statements between export and unset
- Each `return` (explicit or via `|| return 1`) must have a preceding `unset`
- Check `cleanup-on-failure` helpers — do they unset the exported vars?

## 3. Missing `local` Declarations

**Bug:** Variables without `local` leak into the parent shell scope.

```zsh
# BROKEN — REGISTRY pollutes caller's environment
my-func() {
    REGISTRY=$(echo $IMAGE | awk -F/ '{print $1}')  # global!
}
```

**Fix:** Always use `local` for function-scoped variables.

```zsh
# CORRECT
my-func() {
    local REGISTRY=$(echo $IMAGE | awk -F/ '{print $1}')
}
```

**Detection:** Grep for variable assignments in functions that lack `local`/`typeset`.

## 4. ZSH vs Bash Differences

| Feature | Bash | ZSH |
|---------|------|-----|
| Regex captures | `$BASH_REMATCH` | `$match` |
| Array indexing | 0-based | 1-based |
| Word splitting | On by default | Off by default (`SH_WORD_SPLIT` to enable) |
| Glob no-match | Error | Error (`NULL_GLOB`/`NO_MATCH` to change) |
| `echo -n` | Works | Use `printf` for portability |
| Associative arrays | `declare -A` | `typeset -A` |
| Function def | `function f()` or `f()` | Same, but `function` keyword changes scope rules |

## 5. Expensive Operations in Help Paths

**Bug:** Running expensive setup (binary downloads, API calls) before checking if user just wants `--help`.

```zsh
# BROKEN — downloads binary just to show help text
my-func() {
    local BINARY=$(get-expensive-binary)  # slow!
    if [[ $1 == "help" ]]; then
        echo "Usage: ..."
        return 0
    fi
}
```

**Fix:** Check help/early-exit flags before expensive operations.

```zsh
# CORRECT
my-func() {
    if [[ $1 == "help" ]]; then
        echo "Usage: ..."
        return 0
    fi
    local BINARY=$(get-expensive-binary)
}
```

## 6. Interactive Functions in Non-Interactive Contexts

**Bug:** Functions using `fzf`, `read`, or other interactive tools fail silently in CI/scripts.

**Fix:** Detect non-interactive mode and provide fallback or error.

```zsh
if [[ ! -t 0 ]] && [[ -z "$PRESELECTED_VALUE" ]]; then
    echo "ERROR: No value provided and stdin is not a terminal" >&2
    return 1
fi
```

## Review Checklist

When reviewing ZSH functions, check:

- [ ] Any `export` inside a function called via `$()`? → subshell loss
- [ ] Any `export` without `unset` on ALL exit paths? → env var leak
- [ ] Any variable assignment without `local` in a function? → scope leak
- [ ] Any expensive ops before `--help` / early-exit checks? → wasted work
- [ ] Using `$BASH_REMATCH` instead of `$match`? → ZSH incompatible
- [ ] Using 0-based array indexing? → ZSH is 1-based
- [ ] Using `echo -n`? → use `printf` for portability
