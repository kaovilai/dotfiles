## 2024-03-24 - ZSH Glob Evaluation in Conditional Checks
**Learning:** Using unexpanded glob patterns in ZSH `[[ -n ... ]]` checks evaluates to true as a literal string. For example, `[[ -n file(#qN.mh+24) ]]` will always be true even if the file is not 24 hours old because it's evaluated as a non-empty string literal instead of a glob match.
**Action:** Always enable `setopt local_options extended_glob` and expand glob results into an array (e.g. `local -a arr=(file(#q...))`) before checking the length (`(( ${#arr} > 0 ))`) when checking file attributes with glob qualifiers.

## 2024-11-20 - Use Zsh Native Extended Globbing for File Staleness
**Learning:** Checking file age by spawning `stat` and `date` as subprocesses adds unnecessary overhead and degrades shell startup performance. In this codebase, avoiding subprocesses is a critical optimization pattern.
**Action:** Use native Zsh extended globbing (e.g., `(#qN.ms+seconds)`) coupled with `setopt local_options extended_glob` to perform file age evaluations natively within the shell, bypassing process spawning altogether.

## 2026-07-23 - Replace External Find with Native Zsh Globbing
**Learning:** Using `find` as a subprocess (e.g., `find . -type d ...`) to match directories is significantly slower than Zsh's native globbing (e.g., `local -a dirs=( $~pattern(N/) )`), especially when combined with `-exec sh -c` or piped to `while read` loops. Native globbing avoids multiple subprocess creations and simplifies loop logic.
**Action:** Use native Zsh globbing with qualifiers like `(N/)` for directory enumeration and matching instead of spawning external `find` and `sh -c` subprocesses.
