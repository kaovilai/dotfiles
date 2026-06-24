## 2024-06-19 - ZSH Globbing in Conditionals Evaluates to True
**Learning:** Zsh glob qualifiers (like `(#qN.mh+24)`) do not evaluate inside string comparison conditionals (`[[ -n ... ]]`). They are treated as literal strings, meaning `[[ -n $file(#q...) ]]` always evaluates to true.
**Action:** When using ZSH glob qualifiers for conditional checks, always expand the result into an array and verify its length, rather than checking if the resulting string is non-empty. Ensure `extended_glob` is enabled locally using `setopt local_options extended_glob`.
