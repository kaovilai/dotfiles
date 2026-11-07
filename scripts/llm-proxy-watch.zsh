#!/usr/bin/env zsh
# Detached watcher for one local LLM proxy (Go binary, bun, or LiteLLM per
# flavor) that was behind the current dotfiles
# code while it was serving a request (started by llm-proxy-sync, which
# scripts/fleet-sync.zsh runs). Waits for the first idle moment, then restarts
# the proxy so the change lands without anyone coming back to it. The loop is
# llm-proxy-watch in zsh/functions/claude/proxies.zsh; this file only gives it a
# clean environment, because it runs with nobody logged in (nohup, or a
# transient systemd user unit when fleet-sync runs from its timer).
#
#   zsh scripts/llm-proxy-watch.zsh <vertex|openai|enmaas|glm-codex|glm-claude>
#
# Log: ${XDG_STATE_HOME:-~/.local/state}/llm-proxy-sync/watch-<name>.log
# Stop it: kill the pid in watch-<name>.pid (or `systemctl --user stop
# llm-proxy-watch-<name>`). LLM_PROXY_WATCH_TIMEOUT (seconds, default 43200)
# bounds how long it waits.
emulate -L zsh
typeset root="${0:A:h:h}"
# Inherited PATH stays first (the caller may pin tool locations); the usual
# install dirs follow for bare environments (systemd units set a minimal PATH).
path=($path /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.bun/bin")
source "$root/zsh/functions/claude/load.zsh" || exit 1
# The hosted-only fingerprint includes the gateway key, so the staleness check
# needs it; same credential file the launchers read.
if [[ -z "${ENMAAS_API_KEY-}" ]]; then
    typeset credentials="${CLAUDE_PROVIDER_CREDENTIALS_FILE:-$HOME/secrets.zsh}"
    [[ -r "$credentials" ]] && source "$credentials" >/dev/null 2>&1
fi
llm-proxy-watch "$@"
