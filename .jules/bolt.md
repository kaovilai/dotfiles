## 2024-05-18 - Avoid spawning stat/date in ZSH
**Learning:** To check file age in ZSH scripts efficiently, use native Zsh extended globbing qualifiers (e.g., `(#qN.ms+seconds)`) instead of spawning external `stat` and `date` subprocesses.
**Action:** Replace `mtime=$(stat ...) && now=$(date +%s) && (( now - mtime > 86400 ))` with `local -a old_stamp=("$stamp"(#qN.ms+86400)); if (( ${#old_stamp} == 0 )); then ...`.
