## $(date +%Y-%m-%d) - [Optimize N+1 subprocess calls in loops]
**Learning:** Found a performance bottleneck in shell scripts querying `brew list` inside loops, causing N+1 subprocess overhead which is very slow. Homebrew is notoriously slow to boot.
**Action:** Always fetch the results of package managers like `brew list` once into a ZSH array before loops (`local -a items=($(cmd))`), and use fast in-memory array exact-match index search: `if (( ${items[(Ie)$element]} )); then` instead.
