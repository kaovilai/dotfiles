# Git related aliases
alias gcaf='git commit --amend --no-edit && git push --force'
alias gcan='git commit --amend --no-edit'
alias gca='git commit --amend'
alias gcas='git commit --amend --no-edit --signoff'
alias gcasf='git commit --amend --no-edit --signoff && git push --force'
alias gcu='(git checkout upstream/main || git checkout upstream/master)'
alias gcu_nb='(git checkout upstream/main || git checkout upstream/master) && git checkout -b'
alias gcu_master='git checkout upstream/master'
alias gcu_master_nb='git checkout upstream/master && git checkout -b'
alias gcu_main='git checkout upstream/main'
alias gcu_main_nb='git checkout upstream/main && git checkout -b'
alias grumaster='git rebase upstream/master'
alias grumain='git rebase upstream/main'
alias gfa='git fetch --all'
alias gfu='git fetch upstream'
alias gfum='git fetch upstream main'
alias gfumas='git fetch upstream master'
alias gfo='git fetch origin'
alias gfop='git fetch openshift'
alias gfopm='git fetch openshift master'
alias gfopk='git fetch openshift konveyor-dev'
alias gpf='git push  --force'
alias gpl='git pull'
alias gpo='git push'
alias grhu='git reset --hard upstream/main || git reset --hard upstream/master'
alias current-branch='git branch --show-current'
alias recent-branches='git branch --sort=committerdate | tail -n 10'
alias rev-sha-short='git rev-parse --short HEAD'
alias code-lastcommitted='code $(git log --name-only --pretty=format: | head -n 1)'
alias dco='git rebase HEAD~$(gh pr view --json commits -q ".commits | length") --signoff'
alias dco-push='dco && git push --force'

# Opencommit aliases
alias ococ='oco -y'
alias ocos='oco && gcas'
alias ocosp='oco && gcas && gpf'
alias oco-signoff='oco && gcas'
alias oco-signoff-push-force='oco && gcas && gpf'
alias oco-confirm-signoff-push-force='(oco -y || (open -a Ollama && oco -y)) && gcas && gpf'

# Worktree functions
function git-worktree-code() {
  # Create a worktree in parent directory with name <current-dir-basename>-<param1> and open in VS Code
  if [ -z "$1" ]; then
    echo "Error: Missing branch name parameter"
    echo "Usage: git-worktree-code <branch-name>"
    return 1
  fi
  
  local current_repo=$(basename $(pwd))
  local dir="../$current_repo-$1"
  
  # Check if branch exists
  if git show-ref --verify --quiet refs/heads/"$1"; then
    # Branch exists, add worktree
    git worktree add "$dir" "$1" && code "$dir"
  else
    # Branch doesn't exist, create it with the worktree
    echo "Branch '$1' doesn't exist, creating it..."
    git worktree add -b "$1" "$dir" && code "$dir"
  fi
}
alias gwc='git-worktree-code'
