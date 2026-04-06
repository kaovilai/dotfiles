# ~/.zshrc should be a symlink to this file:
#   ln -sf ~/git/dotfiles/.zshrc ~/.zshrc
# -- Essential initialization section (happens in foreground) --
# profiling start
# zmodload zsh/zprof

# Brew completions FPATH must be set before compinit (in znap.zsh)
[[ "$(uname -s)" = "Darwin" ]] && FPATH="$(brew --prefix)/share/zsh/site-functions:${FPATH}"
# Custom user completions
FPATH="$HOME/.zsh/completions:${FPATH}"
source ~/git/dotfiles/zsh/znap.zsh
[[ -f ~/git/dotfiles/zsh/znap.zsh ]] || sh -c "mkdir -p ~/git && git clone --depth 1 -- \
    git@github.com:kaovilai/dotfiles.git ~/git/dotfiles"
function timezsh() {
  shell=${1-$SHELL}
  for i in $(seq 1 10); do /usr/bin/time $shell -i -c exit; done;
}

# Don't put secrets here, put them in ~/secrets.zsh
# edit ~/.zshrc first then run copy-to-dotfiles-from-zshrc to copy to dotfiles
if [[ -f ~/secrets.zsh ]]; then
  local secrets_perms=$(stat -f "%Lp" ~/secrets.zsh)
  if [[ "$secrets_perms" != "600" ]]; then
    print -P "%F{yellow}[dotfiles] Warning: ~/secrets.zsh has permissions $secrets_perms (should be 600)%f" >&2
  fi
  source ~/secrets.zsh
fi
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
  source ~/git/dotfiles/zsh/functions/openshift/load-lazy.zsh
  source ~/git/dotfiles/zsh/functions/claude/functions.zsh
  source ~/git/dotfiles/zsh/functions/s3/load.zsh
source ~/git/dotfiles/zsh/functions/git-utils.zsh
  source ~/git/dotfiles/zsh/functions/podman-utils.zsh
  source ~/git/dotfiles/zsh/functions/dns.zsh
  source ~/git/dotfiles/zsh/functions/symlink-sd.zsh
  source ~/git/dotfiles/zsh/functions/wifi.zsh
source ~/git/dotfiles/zsh/util.zsh
if [[ "$TERM_PROGRAM" != "vscode" ]]; then
  # Git status check (background to avoid blocking startup)
  {
    if command -v gtimeout &>/dev/null; then
      if gtimeout 2 git -C ~/git/dotfiles status --porcelain 2>/dev/null | grep -q "M"; then
        print "dotfiles repo has uncommitted changes, run ${RED}edit-dotfiles${NC} to review"
      fi
    else
      print -P "%F{yellow}[dotfiles] Install coreutils for git timeout support: brew install coreutils%f" >&2
      if git -C ~/git/dotfiles status --porcelain 2>/dev/null | grep -q "M"; then
        print "dotfiles repo has uncommitted changes, run ${RED}edit-dotfiles${NC} to review"
      fi
    fi
  } &!
fi
# -- Non-essential initialization (happens in background) --
{
  # Load extended utilities in background
  # completions are written to fpaths, so likely won't need to run them everytime, esp in vscode.
  if [[ "$TERM_PROGRAM" != "vscode" ]]; then
    source ~/git/dotfiles/zsh/completions.zsh
  fi
} &
