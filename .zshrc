# ~/.zshrc should be a symlink to this file:
#   ln -sf ~/git/dotfiles/.zshrc ~/.zshrc
# -- Essential initialization section (happens in foreground) --
# profiling start
# zmodload zsh/zprof

# Brew completions FPATH must be set before compinit (in znap.zsh)
# Avoid slow brew --prefix subprocess; check well-known paths directly
if [[ "$OSTYPE" == darwin* ]]; then
  if [[ -d /opt/homebrew/share/zsh/site-functions ]]; then      # Apple Silicon
    FPATH="/opt/homebrew/share/zsh/site-functions:${FPATH}"
  elif [[ -d /usr/local/share/zsh/site-functions ]]; then       # Intel
    FPATH="/usr/local/share/zsh/site-functions:${FPATH}"
  fi
fi
# Custom user completions
FPATH="$HOME/.zsh/completions:${FPATH}"
source ~/git/dotfiles/zsh/znap.zsh
[[ -f ~/git/dotfiles/zsh/znap.zsh ]] || sh -c "mkdir -p ~/git && git clone --depth 1 -- \
    git@github.com:kaovilai/dotfiles.git ~/git/dotfiles"
function timezsh() {
  local shell=${1-$SHELL}
  local i
  for i in $(seq 1 10); do /usr/bin/time $shell -i -c exit; done;
}

# Don't put secrets here, put them in ~/secrets.zsh
# edit ~/.zshrc first then run copy-to-dotfiles-from-zshrc to copy to dotfiles
if [[ -f ~/secrets.zsh ]]; then
  zmodload -F zsh/stat b:zstat
  local -a secrets_stat
  zstat -A secrets_stat +mode ~/secrets.zsh
  if (( (secrets_stat[1] & 8#777) != 8#600 )); then
    print -P "%F{yellow}[dotfiles] Warning: ~/secrets.zsh has unexpected permissions (should be 600)%f" >&2
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
export GPG_TTY=$TTY
# Export essential environment variables
export BUILDX_ENABLED=true
export BUILDX_PUSH=true
export GCR_IMAGE_TAGS=""
export BUILDX_PLATFORMS=linux/amd64,linux/arm64
# For velero to not create new instances
export BUILDX_INSTANCE=default
export HAPPY_CLAUDE_PATH=~/.local/bin/claude
# Load OS-specific essentials (lightweight aliases always loaded)
[[ "$OSTYPE" == darwin* ]] && source ~/git/dotfiles/zsh/macos.zsh
# Essential utilities (needed for basic shell functionality)
source ~/git/dotfiles/zsh/paths.zsh
  source ~/git/dotfiles/zsh/functions/openshift/load-lazy.zsh
  source ~/git/dotfiles/zsh/functions/claude/functions.zsh
  source ~/git/dotfiles/zsh/functions/s3/load-lazy.zsh
source ~/git/dotfiles/zsh/functions/git-utils.zsh
  source ~/git/dotfiles/zsh/functions/podman-utils.zsh

# DNS utilities (lazy-loaded — ~215 lines only parsed when first used)
typeset -g DNS_FUNCTIONS_LOADED=0
_lazy_load_dns() {
    if [[ $DNS_FUNCTIONS_LOADED -eq 0 ]]; then
        source ~/git/dotfiles/zsh/functions/dns.zsh && DNS_FUNCTIONS_LOADED=1
    fi
}
for func in set-dns-servers clear-dns-servers; do
    eval "${func}() { _lazy_load_dns || return 1; ${func} \"\$@\"; }"
done

# SD card symlink utilities (lazy-loaded — ~240 lines only parsed when first used)
typeset -g SYMLINK_SD_LOADED=0
_lazy_load_symlink_sd() {
    if [[ $SYMLINK_SD_LOADED -eq 0 ]]; then
        source ~/git/dotfiles/zsh/functions/symlink-sd.zsh && SYMLINK_SD_LOADED=1
    fi
}
for func in symlink-to-sd unsymlink-from-sd relink-from-sd; do
    eval "${func}() { _lazy_load_symlink_sd || return 1; ${func} \"\$@\"; }"
done

# WiFi utilities (lazy-loaded — ~62 lines only parsed when first used)
typeset -g WIFI_FUNCTIONS_LOADED=0
_lazy_load_wifi() {
    if [[ $WIFI_FUNCTIONS_LOADED -eq 0 ]]; then
        source ~/git/dotfiles/zsh/functions/wifi.zsh && WIFI_FUNCTIONS_LOADED=1
    fi
}
for func in wifi-standard; do
    eval "${func}() { _lazy_load_wifi || return 1; ${func} \"\$@\"; }"
done
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
