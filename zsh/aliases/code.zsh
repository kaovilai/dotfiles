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
  local dirs
  dirs=$(ls -d ~/git/*/ 2>/dev/null | sed "s|$HOME/git/||;s|/$||" | fzf --multi --prompt="~/git/ > " --preview 'git -C ~/git/{} status -sb 2>/dev/null || echo "Not a git repo"') || return
  echo "$dirs" | while IFS= read -r d; do
    code ~/git/"$d" </dev/null
  done
}
