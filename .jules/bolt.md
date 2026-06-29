## 2024-06-29 - [Optimize brew list N+1 query]
**Learning:** Checking for package presence iteratively with `brew list "$tool"` inside loops in bash/zsh scripts creates a severe N+1 performance bottleneck due to the slow startup time of the `brew` subprocess.
**Action:** Always fetch the entire output of `brew list -1` into a shell array `local -a packages=($(brew list -1))` once and use fast, exact-match in-memory array membership checks (`if (( ${packages[(Ie)$tool]} )); then`) to verify package presence, avoiding all subsequent shell subprocess creation overhead.
