## 2024-06-23 - ZSH Native File Age Checks
**Learning:** Checking file age in ZSH using external processes (`stat` and `date`) is a significant performance bottleneck due to fork/exec overhead.
**Action:** Use native ZSH extended globbing qualifiers `(#qN.ms+seconds)` combined with `setopt local_options extended_glob` to perform file age checks entirely in-memory.
