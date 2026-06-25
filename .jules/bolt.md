## 2025-01-15 - [ZSH File Age Checking]
**Learning:** Checking file age with external processes (`stat` and `date`) inside frequently called functions (like `cache-file-expired`) adds noticeable overhead (~7ms per call vs ~0.05ms) by spawning subshells.
**Action:** Use native ZSH extended globbing file age qualifiers (`(#qN.ms+seconds)`) to natively check file expiration without subprocess overhead.
