## 2024-06-25 - Zsh string bare glob literal evaluation

**Learning:** When using ZSH glob qualifiers like `(#q...)` inside conditional checks like `[[ -n string(#q...) ]]`, Zsh evaluates this as a bare string if `extended_glob` is not explicitly enabled or if it's evaluated in a scalar context (where a string evaluating to an empty match falls back to the original glob string). This caused the script to always match `-n` as true and slow down initialization.

**Action:** Explicitly enable `setopt local_options extended_glob` in an anonymous function block and expand the string glob match into an array, e.g., `local -a array=( string(#q...) )`. Then check its length with `(( ${#array[@]} > 0 ))`. This prevents the string literal evaluation fallback and reliably evaluates the modified glob match!
