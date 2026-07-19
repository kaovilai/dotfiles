## 2024-03-24 - ZSH Glob Evaluation in Conditional Checks
**Learning:** Using unexpanded glob patterns in ZSH `[[ -n ... ]]` checks evaluates to true as a literal string. For example, `[[ -n file(#qN.mh+24) ]]` will always be true even if the file is not 24 hours old because it's evaluated as a non-empty string literal instead of a glob match.
**Action:** Always enable `setopt local_options extended_glob` and expand glob results into an array (e.g. `local -a arr=(file(#q...))`) before checking the length (`(( ${#arr} > 0 ))`) when checking file attributes with glob qualifiers.

## 2024-11-20 - Use Zsh Native Extended Globbing for File Staleness
**Learning:** Checking file age by spawning `stat` and `date` as subprocesses adds unnecessary overhead and degrades shell startup performance. In this codebase, avoiding subprocesses is a critical optimization pattern.
**Action:** Use native Zsh extended globbing (e.g., `(#qN.ms+seconds)`) coupled with `setopt local_options extended_glob` to perform file age evaluations natively within the shell, bypassing process spawning altogether.

## 2024-03-24 - Znap Automatically Handles Compinit
**Learning:** The Znap plugin manager automatically handles `compinit` and comp dumps out of the box.
**Action:** Do not manually call `compinit` (e.g., in `.zshrc` or `zsh/znap.zsh`) when using Znap, as it degrades shell startup performance due to redundant execution.
