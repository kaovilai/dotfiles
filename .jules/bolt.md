## 2024-05-19 - N+1 Subprocess Bottleneck in Package Manager Loops
**Learning:** Found a common pattern where `brew list "$tool"` is called inside a loop, causing massive slowdowns because Homebrew is slow to initialize.
**Action:** Use native Zsh parameter expansion to cache the output of `brew list -1` into an array, and perform fast in-memory array membership checks using exact-match index search `if (( ${installed_packages[(Ie)$tool]} )); then` instead.
