## 2024-07-03 - [Fix `extended_glob` evaluation inside conditional check]
**Learning:** In ZSH, extended globbing operators like `(#q...)` evaluate incorrectly (usually as non-empty strings, equating to literal `true`) when placed directly inside string checking operations like `[[ -n ... ]]` without prior expansion.
**Action:** When using ZSH glob qualifiers inside conditional checks, enable `setopt local_options extended_glob` and expand the result into an array first to verify its length accurately.
