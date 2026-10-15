#!/bin/zsh
emulate -LR zsh
setopt err_exit pipe_fail

local repo="${0:A:h:h}"
local tmp
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export XDG_CONFIG_HOME="$tmp/config"
export CLAUDE_PROVIDER_CREDENTIALS_FILE="$tmp/secrets.zsh"
export ENMAAS_API_KEY="test-enmass-key"
export CODEX_NATIVE_BINARY="$tmp/bin/codex"
export PATH="$tmp/bin:$PATH"

mkdir -p "$tmp/bin" "$tmp/config"
cat > "$tmp/bin/codex" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$CODEX_MODE_TEST_LOG"
printf '%s\n' 'codex-stub'
EOF
chmod +x "$tmp/bin/codex"
rehash

source "$repo/zsh/functions/codex.zsh"

fail() { print -ru2 -- "FAIL: $*"; exit 1; }

codex-mode enmass >/dev/null
[[ "$(<"$_codex_mode_file")" == enmass ]] || fail "enmass mode was not persisted"

export CODEX_MODE_TEST_LOG="$tmp/version.log"
codex --version >/dev/null
[[ "$(<"$tmp/version.log")" == --version ]] || fail "version bypass changed arguments"

CODEX_MODE_TEST_LOG="$tmp/enmass.log"
codex hello >/dev/null
grep -q 'model_provider=enmaas' "$tmp/enmass.log" || fail "enmass mode did not set provider"
grep -q 'model=rits/zai-org/glm-5-3' "$tmp/enmass.log" || fail "enmass mode did not set model"
grep -q -- 'hello' "$tmp/enmass.log" || fail "enmass mode dropped caller arguments"

codex-mode native >/dev/null
[[ "$(<"$_codex_mode_file")" == native ]] || fail "native mode was not persisted"
CODEX_MODE_TEST_LOG="$tmp/native.log"
codex hello >/dev/null
[[ "$(<"$tmp/native.log")" == hello ]] || fail "native mode changed caller arguments"

print -r -- 'ok codex-mode'
