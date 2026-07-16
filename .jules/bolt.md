## 2024-03-24 - ZSH Glob Evaluation in Conditional Checks
**Learning:** Using unexpanded glob patterns in ZSH `[[ -n ... ]]` checks evaluates to true as a literal string. For example, `[[ -n file(#qN.mh+24) ]]` will always be true even if the file is not 24 hours old because it's evaluated as a non-empty string literal instead of a glob match.
**Action:** Always enable `setopt local_options extended_glob` and expand glob results into an array (e.g. `local -a arr=(file(#q...))`) before checking the length (`(( ${#arr} > 0 ))`) when checking file attributes with glob qualifiers.
## 2024-07-16 - Replace stat/date subprocesses with ZSH extended globbing for file age checks
**Learning:** Spawning external `stat` and `date` subprocesses inside frequently executed functions (like cache checking) takes significant time (~10ms per check), leading to measurable slowdowns during shell initialization.
**Action:** Use ZSH's native extended glob qualifiers (`(#qN.ms+seconds)`) for checking file age. This evaluates entirely in memory and is over 100x faster than forking subprocesses. Remember to use an array assignment to safely check the glob match.
