# Claude Code related aliases
alias edit-dotfiles='claude ~/git/dotfiles/'

# Open specific projects in Claude Code
alias coadp='claude ~/oadp-operator/'
alias coadp-nac='claude ~/git/oadp-non-admin/'
alias cvelero='claude ~/git/velero/'
alias cvelero-aws='claude ~/git/velero-plugin-for-aws/'
alias cvelero-gcp='claude ~/git/velero-plugin-for-gcp/'
alias cvelero-azure='claude ~/git/velero-plugin-for-microsoft-azure/'
alias cvelero-ocp='claude ~/git/openshift-velero-plugin/'
alias cvelero-lvp='claude ~/git/local-volume-provider/'
alias clvp='claude ~/git/local-volume-provider/'
alias crelease='claude ~/git/release'
alias cclaude='claude ~/.claude/'

# Open directories from ~/git/ selected via fzf
cg() {
  if ! command -v fzf &>/dev/null; then
    echo "❌ fzf not found. Install it with: brew install fzf" >&2
    return 1
  fi
  if ! command -v claude &>/dev/null; then
    echo "❌ claude not found. Install Claude Code CLI." >&2
    return 1
  fi
  local dirs d
  dirs=$(print -l ~/git/*(N/:t) | fzf --multi --prompt="~/git/ > " --preview 'git -C ~/git/{} status -sb 2>/dev/null || echo "Not a git repo"') || return
  while IFS= read -r d; do
    claude ~/git/"$d" </dev/null
  done <<< "$dirs"
}
