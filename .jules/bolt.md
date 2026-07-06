## 2026-07-06 - Optimize Homebrew package checks in migrate-laptop.zsh
**Learning:** N+1 `brew list` subprocess calls are a massive performance bottleneck. Running `brew list <pkg>` sequentially creates enormous overhead, blocking script execution.
**Action:** Always pre-fetch Homebrew package lists into a Zsh array `local -a installed_packages=($(brew list))` and perform instantaneous in-memory array membership checks using `if (( ${installed_packages[(Ie)$tool]} )); then` instead of running `brew list <pkg>` in a loop.
