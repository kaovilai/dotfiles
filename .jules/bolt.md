## 2024-06-28 - Native Zsh globs for file age checks
**Learning:** Checking file age via `stat` and `date` spawns slow subprocesses. Native Zsh extended globbing (e.g., `(#qNms+86400)`) provides the exact same boolean behavior with a >100x performance improvement (from ~9ms to ~0.06ms per check).
**Action:** Next time I need to filter or check files by age in a Zsh script, I'll use the native glob syntax `(#qNms+SECONDS)` instead of shelling out to `stat` or `find`.
