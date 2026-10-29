#!/bin/zsh
# Offline tests for export-t3-providers / import-t3-providers: a throwaway
# HOME, T3CODE_HOME and dotfiles root holding only the template.
emulate -LR zsh
setopt err_exit pipe_fail
local repo="${0:A:h:h}"
local tmp
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { print -ru2 -- "FAIL: $*"; exit 1; }

source "$repo/zsh/functions/migrate-laptop.zsh"
local mac="$tmp/mac" fed="$tmp/fedora"
mkdir -p "$mac/.t3/userdata" "$fed/.t3/userdata" "$fed/.local/bin" "$tmp/dot/t3"
_T3_PROVIDER_TEMPLATE="$tmp/dot/t3/provider-instances.json"
local out

# --- export on the "Mac" ----------------------------------------------------
HOME=$mac T3CODE_HOME=$mac/.t3
cat > "$mac/.t3/userdata/settings.json" <<EOF
{"theme": "dark", "providerInstances": {
  "claude_copilot": {"driver": "claudeAgent", "enabled": true, "environment": [{"name": "A", "value": "1", "sensitive": false}],
                     "config": {"binaryPath": "$mac/.local/bin/claude-t3-copilot", "customModels": []}},
  "claude_enmass":  {"driver": "claudeAgent", "enabled": true, "environment": [{"name": "TOKEN", "value": "s3cret", "sensitive": true}],
                     "config": {"binaryPath": "$mac/.local/bin/claude-t3-enmaas", "homePath": "$mac/x"}},
  "codex_rh":       {"driver": "codex", "environment": [{"name": "CODEX_API_KEY", "value": "k", "sensitive": true}], "config": {}},
  "cursor":         {"driver": "cursor", "config": {"binaryPath": "cursor-agent"}}
}}
EOF
out=$(export-t3-providers 2>&1) || fail "export failed: $out"
[[ "$out" == *"Left out sensitive environment values: claude_enmass.TOKEN"* ]] || fail "sensitive value not reported: $out"
[[ "$(jq -r '.providerInstances | keys | join(",")' "$_T3_PROVIDER_TEMPLATE")" == claude_copilot,claude_enmass ]] \
    || fail "wrong instances exported: $(<"$_T3_PROVIDER_TEMPLATE")"
grep -q "$mac" "$_T3_PROVIDER_TEMPLATE" && fail "home path left in template"
grep -q s3cret "$_T3_PROVIDER_TEMPLATE" && fail "sensitive value exported"
[[ "$(jq -r '.providerInstances.claude_enmass.config.homePath' "$_T3_PROVIDER_TEMPLATE")" == "@HOME@/x" ]] || fail "homePath not rewritten"

# --- import on "Fedora": only the copilot launcher is linked ----------------
HOME=$fed T3CODE_HOME=$fed/.t3 XDG_STATE_HOME=$fed/.state
print -r -- '{"theme": "light"}' > "$fed/.t3/userdata/settings.json"
print -r -- "#!/bin/sh" > "$fed/.local/bin/claude-t3-copilot" && chmod +x "$fed/.local/bin/claude-t3-copilot"
out=$(import-t3-providers --dry-run 2>&1)
[[ "$out" == *"(dry run): 1 added (claude_copilot)"* ]] || fail "dry run summary: $out"
[[ "$(jq -c . "$fed/.t3/userdata/settings.json")" == '{"theme":"light"}' ]] || fail "dry run wrote settings"
out=$(import-t3-providers 2>&1) || fail "import failed: $out"
[[ "$(jq -r '.providerInstances.claude_copilot.config.binaryPath' "$fed/.t3/userdata/settings.json")" == "$fed/.local/bin/claude-t3-copilot" ]] \
    || fail "copilot not imported with this home"
jq -e '.providerInstances.claude_enmass' "$fed/.t3/userdata/settings.json" >/dev/null && fail "unlinked enmaas imported"
[[ "$(jq -r .theme "$fed/.t3/userdata/settings.json")" == light ]] || fail "other settings lost"
out=$(import-t3-providers 2>&1)
[[ "$out" == *"0 added, 0 updated, 1 current"* ]] || fail "second import not idempotent: $out"

# Linking enmaas later brings it in
print -r -- "#!/bin/sh" > "$fed/.local/bin/claude-t3-enmaas" && chmod +x "$fed/.local/bin/claude-t3-enmaas"
out=$(import-t3-providers 2>&1)
[[ "$out" == *"1 added (claude_enmass)"* ]] || fail "newly linked instance not added: $out"
[[ "$(jq -r '.providerInstances.claude_enmass.config.homePath' "$fed/.t3/userdata/settings.json")" == "$fed/x" ]] || fail "@HOME@ not expanded"

# --- template changes: untouched instance follows, locally edited one stays -
jq '.providerInstances.claude_copilot.environment[0].value = "2" | .providerInstances.claude_enmass.enabled = false' \
    "$_T3_PROVIDER_TEMPLATE" > "$tmp/t" && mv "$tmp/t" "$_T3_PROVIDER_TEMPLATE"
jq '.providerInstances.claude_enmass.displayName = "edited here"' "$fed/.t3/userdata/settings.json" > "$tmp/s" \
    && mv "$tmp/s" "$fed/.t3/userdata/settings.json"
out=$(import-t3-providers 2>&1)
[[ "$out" == *"Changed on this machine, not updated: claude_enmass"* ]] || fail "local edit not reported: $out"
[[ "$out" == *"1 updated (claude_copilot)"* ]] || fail "untouched instance not updated: $out"
[[ "$(jq -r '.providerInstances.claude_copilot.environment[0].value' "$fed/.t3/userdata/settings.json")" == 2 ]] || fail "update not written"
[[ "$(jq -r '.providerInstances.claude_enmass.displayName' "$fed/.t3/userdata/settings.json")" == "edited here" ]] || fail "local edit overwritten"

print -r -- "ok t3-providers"
