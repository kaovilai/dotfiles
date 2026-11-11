#!/usr/bin/env zsh
# Knob parity: every HOSTED_ONLY_* knob the Go proxy reads must be forwarded
# by BOTH the hosted-only launcher (_hosted_only_go_env) and the EnMaaS
# controller (_claude_enmaas_hook_env), so an improvement to the hosted-only
# route always reaches EnMaaS (2026-11-11: the timeout knobs shipped to
# hosted-only and silently missed EnMaaS). Also checks the reverse: a knob
# forwarded that config.go no longer reads is stale.
#
# The Go binary is one program for every flavor; config.go is its knob reader.

emulate -L zsh
typeset repo="${0:A:h:h}"
source "$repo/zsh/functions/claude/load.zsh" || { print -u2 'FAIL - load.zsh'; exit 1 }
export ENMAAS_API_KEY=parity-test-key

fail() { print -ru2 -- "FAIL - $*"; exit 1; }

# Knobs config.go reads through the knob() families (HOSTED_ONLY_<NAME>).
typeset -a go_knobs
local scan
scan="$(grep -oE '(int|bool|float)?[Kk]nob\("[A-Z0-9_]+"' "$repo/scripts/hosted-only-go/config.go" | sed -E 's/.*\("([A-Z0-9_]+)"$/\1/')"
scan="$scan
$(grep -ohE 'os\.Getenv\("HOSTED_ONLY_[A-Z0-9_]+"\)' "$repo"/scripts/hosted-only-go/*.go | sed -E 's/.*HOSTED_ONLY_([A-Z0-9_]+)"\)/\1/')"
go_knobs=(${(u)${(f)scan}})
(( ${#go_knobs} > 5 )) || fail "config.go knob scan found only ${#go_knobs} knobs"
(( ${#go_knobs} > 0 ))

# Knobs with a per-flavor home, deliberately NOT in the shared list. Every
# entry needs its reason inline.
typeset -A per_flavor=(
    ENMAAS_BASE_URL   'per-flavor gateway root (enmaas: discovery; hosted-only: knob)'
    PROXY_TOKEN       'per-flavor local token'
    GLM_MODEL         'hosted pair / enmaas route table'
    DEEPSEEK_MODEL    'hosted pair / enmaas route table'
    ALIAS_MODELS      'hosted-only alias deployment'
    OUTAGE_STATE      'per-runtime streak file path'
    DIALECT_SUFFIX    'hosted-only merged #openai table only'
    UPSTREAM_KEY       'route-table flavors (mlx/openai) set it inline; hosted-only/enmaas use ENMAAS_API_KEY'
    FORCE_RESTART      'one-shot request, read by the lifecycle subcommands only'
    FLAVOR             'serve subcommand flag default, never a proxy knob'
    CONFIG             'serve subcommand flag default (route table path), never a proxy knob'
)

# --- hosted-only forwarded keys -------------------------------------------
_hosted_only_proxy_vars claude >/dev/null || fail '_hosted_only_proxy_vars'
_hosted_only_go_env
typeset -A hosted_keys
local kv
for kv in "${_hop_go_env[@]}"; do hosted_keys[${kv%%=*}]=1; done

# --- enmaas exported keys --------------------------------------------------
# hook_env exports; the test is its own process, so the leak is contained.
typeset -a ho_before
ho_before=(${(k)parameters[(I)HOSTED_ONLY_*]})
_claude_enmaas_hook_env >/dev/null || fail '_claude_enmaas_hook_env'
typeset -a enmaas_keys_raw
enmaas_keys_raw=(${(k)parameters[(I)HOSTED_ONLY_*]})
typeset -A enmaas_keys
local newly=1 k found
for k in $enmaas_keys_raw; do
    found=0
    for kv in $ho_before; do [[ "$k" == "$kv" ]] && found=1; done
    (( ! found )) && enmaas_keys[$k]=1
done
# the aliases hook_env maps from ENMAAS_* count as forwarded
(( ${#enmaas_keys} > 5 )) || fail "enmaas exports only ${#enmaas_keys} HOSTED_ONLY_ knobs"

# --- forward direction: config.go knob -> both launchers -------------------
for kv in $go_knobs; do
    if [[ -n "${per_flavor[$kv]:-}" ]]; then continue; fi
    [[ -n "${hosted_keys[HOSTED_ONLY_$kv]:-}" ]] || fail "hosted-only does not forward HOSTED_ONLY_$kv (config.go reads it)"
    [[ -n "${enmaas_keys[HOSTED_ONLY_$kv]:-}" ]] || fail "enmaas (_claude_enmaas_hook_env) does not export HOSTED_ONLY_$kv (config.go reads it) — add it to _hosted_only_go_shared_env"
done

# --- reverse: forwarded knob must be read ----------------------------------
typeset -A read_names
for kv in $go_knobs; do read_names[HOSTED_ONLY_$kv]=1; done
local extra=(PROXY_TOKEN ENMAAS_BASE_URL GLM_MODEL DEEPSEEK_MODEL ALIAS_MODELS OUTAGE_STATE DIALECT_SUFFIX UPSTREAM_KEY FORCE_RESTART FLAVOR CONFIG)
for kv in $extra; do read_names[HOSTED_ONLY_$kv]=1; done
for kv in ${(k)hosted_keys}; do
    [[ "$kv" == HOSTED_ONLY_* ]] || continue
    [[ -n "${read_names[$kv]:-}" ]] || fail "hosted-only forwards $kv but config.go does not read it (stale entry)"
done
for kv in ${(k)enmaas_keys}; do
    [[ -n "${read_names[$kv]:-}" ]] || fail "enmaas exports $kv but config.go does not read it (stale entry)"
done

# --- the shared list itself is what enmaas exports -------------------------
typeset -A shared_keys
_hosted_only_go_shared_env
for kv in "${_hog_shared[@]}"; do shared_keys[${kv%%=*}]=1; done
for kv in ${(k)shared_keys}; do
    [[ -n "${enmaas_keys[$kv]:-}" ]] || fail "shared knob $kv is not exported by _claude_enmaas_hook_env"
done

print 'ok - Go proxy knobs reach the hosted-only launcher and the EnMaaS controller alike'
