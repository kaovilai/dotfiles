#!/usr/bin/env zsh
pattern="velero*"
# setup dummy dirs
mkdir -p velero-1 velero-2 other-dir

echo "Testing find:"
time (
    if [[ -z "$(find . -type d -maxdepth 1 -name "$pattern" -print -quit)" ]]; then
        echo "No match"
    else
        find . -type d -maxdepth 1 -name "$pattern" | while read -r dir; do
            :
        done
    fi
)

echo "Testing zsh glob:"
time (
    local -a dirs
    dirs=( $~pattern(N/) )
    if (( ${#dirs} == 0 )); then
        echo "No match"
    else
        for dir in "${dirs[@]}"; do
            :
        done
    fi
)
