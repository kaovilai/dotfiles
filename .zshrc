# expected content of ~/.zshrc
# ```
# source ~/git/dotfiles/.zshrc
# ```
# -- Essential initialization section (happens in foreground) --
# profiling start
# zmodload zsh/zprof

source ~/git/dotfiles/zsh/znap.zsh
[[ -f ~/git/dotfiles/zsh/znap.zsh ]] || sh -c "mkdir -p ~/git && git clone --depth 1 -- \
    git@github.com:kaovilai/dotfiles.git ~/git/dotfiles"
znap function timezsh() {
  shell=${1-$SHELL}
  for i in $(seq 1 10); do /usr/bin/time $shell -i -c exit; done;
}

# Don't put secrets here, put them in ~/secrets.zsh
# edit ~/.zshrc first then run copy-to-dotfiles-from-zshrc to copy to dotfiles
[[ -f ~/secrets.zsh ]] && source ~/secrets.zsh
export HISTSIZE=100000 # number of commands stored in history
export HISTFILESIZE=200000 # bytes in history file
source ~/git/dotfiles/zsh/colors.zsh
# https://docs.anthropic.com/en/docs/claude-code/settings#environment-variables:~:text=running%20bash%20commands-,BASH_MAX_TIMEOUT_MS,-Maximum%20timeout%20the
BASH_MAX_TIMEOUT_MS=600000
BASH_DEFAULT_TIMEOUT_MS=480000

# Essential exports and aliases for immediate shell usage
alias edit-dotfiles='code ~/git/dotfiles/'
alias edit-agents='code ~/.claude/agents/'
source ~/git/dotfiles/zsh/alias.zsh
# gpg tty
export GPG_TTY=$(tty)
# Export essential environment variables
export BUILDX_ENABLED=true
export BUILDX_PUSH=true
export GCR_IMAGE_TAGS=""
export BUILDX_PLATFORMS=linux/amd64,linux/arm64
# For velero to not create new instances
export BUILDX_INSTANCE=default
# Load OS-specific essentials (lightweight aliases always loaded)
[[ "$(uname -s)" = "Darwin" ]] && source ~/git/dotfiles/zsh/macos.zsh
# Essential utilities (needed for basic shell functionality)
source ~/git/dotfiles/zsh/paths.zsh
# source ~/git/dotfiles/zsh/command-cache.zsh
# source ~/git/dotfiles/zsh/cached-commands.zsh
# Load GitHub Copilot aliases
eval "$(gh copilot alias -- zsh)"
# source ~/git/dotfiles/zsh/aws.zsh
  source ~/git/dotfiles/zsh/functions/openshift/load.zsh
  source ~/git/dotfiles/zsh/functions/claude/functions.zsh
  source ~/git/dotfiles/zsh/functions/s3/load.zsh
# source ~/git/dotfiles/zsh/podman.zsh
source ~/git/dotfiles/zsh/util.zsh
if [[ "$TERM_PROGRAM" != "vscode" ]]; then
  # Git status check
  if git -C ~/git/dotfiles status --porcelain | grep -q "M"; then
    echo "dotfiles repo has uncommitted changes, run ${RED}edit-dotfiles${NC} to review"
    echo
  fi
fi
# -- Non-essential initialization (happens in background) --
{
  # Load extended utilities in background
  # completions are written to fpaths, so likely won't need to run them everytime, esp in vscode.
  if [[ "$TERM_PROGRAM" != "vscode" ]]; then
    source ~/git/dotfiles/zsh/completions.zsh
  fi
} &
# # bun completions
# [ -s "~/.bun/_bun" ] && source "~/.bun/_bun"


# # bun
# export BUN_INSTALL="$HOME/.bun"
# export PATH="$BUN_INSTALL/bin:$PATH"

# export PATH="$HOME/.local/bin:$PATH"

# [ -f "~/.ghcup/env" ] && . "~/.ghcup/env" # ghcup-env

# profiling end
# zprof
