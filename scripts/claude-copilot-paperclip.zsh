#!/usr/bin/env zsh
# Headless entrypoint for Paperclip's claude_local adapter `command` field
# (https://docs.paperclip.ing/reference/adapters/claude-code/).
#
# Paperclip's adapter execs `command` non-interactively and parses stdout as
# stream-json, so this just re-uses claude-copilot() from zsh/functions/claude/providers/copilot.zsh
# (gateway autostart + model pinning against the local copilot-api gateway)
# and passes every adapter-supplied arg straight through to `claude`. Any
# diagnostic output claude-copilot() prints must go to stderr, not stdout, or
# it corrupts the stream-json Paperclip expects on stdout -- fixed upstream in
# providers/copilot.zsh; do not reintroduce a bare `echo` there.
source "${0:A:h}/../zsh/functions/claude/load.zsh"

# Paperclip's adapter form requires a non-empty ANTHROPIC_API_KEY (or
# Bedrock/subscription login) to pass its own auth check, then injects
# whatever placeholder you typed into this process's env. claude-copilot()
# never unsets ANTHROPIC_API_KEY (only ANTHROPIC_AUTH_TOKEN, which it
# overwrites), so a real or placeholder key here could otherwise race the
# gateway's dummy bearer token depending on CLI auth precedence. Unset it so
# the copilot-api gateway credentials always win.
unset ANTHROPIC_API_KEY

claude-copilot "$@"
