# VSCode related aliases
alias edit-dotfiles='code ~/git/dotfiles/'

# Open specific projects in VSCode
alias coadp='code ~/oadp-operator/'
alias coadp-nac='code ~/git/oadp-non-admin/'
alias cvelero='code ~/git/velero/'
alias cvelero-aws='code ~/git/velero-plugin-for-aws/'
alias cvelero-gcp='code ~/git/velero-plugin-for-gcp/'
alias cvelero-azure='code ~/git/velero-plugin-for-microsoft-azure/'
alias cvelero-ocp='code ~/git/openshift-velero-plugin/'
alias cvelero-lvp='code ~/git/local-volume-provider/'
alias clvp='code ~/git/local-volume-provider/'
alias crelease='code ~/git/release'

# Open directories from ~/git/ selected via fzf
cg() {
  if ! command -v fzf &>/dev/null; then
    echo "❌ fzf not found. Install it with: brew install fzf" >&2
    return 1
  fi
  if ! command -v code &>/dev/null; then
    echo "❌ code not found. Install VS Code and run: Shell Command: Install 'code' command in PATH" >&2
    return 1
  fi
  local dirs d
  dirs=$(print -l ~/git/*(N/:t) | fzf --multi --prompt="~/git/ > " --preview 'git -C ~/git/{} status -sb 2>/dev/null || echo "Not a git repo"') || return
  while IFS= read -r d; do
    code ~/git/"$d" </dev/null
  done <<< "$dirs"
}
