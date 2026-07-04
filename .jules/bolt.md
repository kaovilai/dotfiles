## 2024-07-04 - [Fix faulty glob conditional in compinit logic]
**Learning:** Using Zsh extended glob qualifiers like `(#qN.mh+24)` directly inside `[[ -n ... ]]` checks evaluates to a literal string if there is no match (when `null_glob` is not globally enabled), causing the condition to always be truthy. This mistakenly triggers slow code paths.
**Action:** Always enable `setopt local_options extended_glob` and expand the glob result into a local array, then explicitly check the array length (`${#array} -gt 0`) to correctly verify if a file matching the criteria exists.
