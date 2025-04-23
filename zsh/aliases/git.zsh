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
znap function git-worktree-code() {
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

# PR management functions
# Note: For best experience with arrow key navigation, install fzf:
#   - On macOS: brew install fzf
#   - On Linux: apt/yum install fzf or follow https://github.com/junegunn/fzf#installation
znap function pr-me() {
  # List PRs by the current user and allow interactive selection for checkout
  # Usage: pr-me [worktree|wt]
  # If "worktree" or "wt" is passed as an argument, checkout to a worktree using gwc
  
  # Get the list of PRs
  local pr_list=$(gh pr list --author @me)
  
  if [[ -z "$pr_list" ]]; then
    echo "No PRs found for your user"
    return 1
  fi
  
  # Display the PR list
  echo "$pr_list"
  
  # Check if fzf is available for interactive selection
  if command -v fzf >/dev/null 2>&1; then
    # Use fzf for interactive selection with arrow keys
    local selected=$(echo "$pr_list" | fzf --height 40% --reverse --header "Select a PR to checkout (or press Ctrl+C to cancel)")
    
    # Extract PR number from selection (first column)
    if [[ -n "$selected" ]]; then
      local pr_number=$(echo "$selected" | awk '{print $1}' | sed 's/#//')
    else
      # User cancelled
      return 0
    fi
  else
    # Fallback to select builtin for a menu-based selection
    echo ""
    echo "Select a PR to checkout (or Ctrl+C to cancel):"
    
    # Parse PR list into an array
    local pr_lines=("${(@f)pr_list}")
    # Skip the header line
    shift pr_lines
    
    # If there are no PRs after removing the header, exit
    if [[ ${#pr_lines[@]} -eq 0 ]]; then
      echo "No PRs found"
      return 1
    fi
    
    # Create arrays for display and PR numbers
    local pr_display=()
    local pr_numbers=()
    
    # Parse each line to extract PR number and title
    for line in "${pr_lines[@]}"; do
      local pr_num=$(echo "$line" | awk '{print $1}' | sed 's/#//')
      local pr_title=$(echo "$line" | awk '{$1=""; $2=""; $3=""; $4=""; print $0}' | sed 's/^[ \t]*//')
      pr_numbers+=("$pr_num")
      pr_display+=("PR #$pr_num: $pr_title")
    done
    
    # Allow direct PR number input or menu selection
    echo "Enter PR number directly or select from menu:"
    local pr_input
    read -r pr_input
    
    # If input is a number, use it directly
    if [[ -n "$pr_input" ]] && [[ "$pr_input" =~ ^[0-9]+$ ]]; then
      local pr_number=${pr_input/#\#/}
    else
      # Otherwise show selection menu
      echo "Select a PR:"
      select choice in "${pr_display[@]}"; do
        if [[ -n "$choice" ]]; then
          # Extract PR number from the selection
          local index=$REPLY
          local pr_number=${pr_numbers[$index]}
          break
        else
          echo "Invalid selection"
        fi
      done
    fi
    
    # If we don't have a PR number at this point, exit
    if [[ -z "$pr_number" ]]; then
      echo "No PR selected"
      return 1
    fi
  fi
  
  # Check if we should use worktree (accept both "worktree" and "wt")
  if [[ "$1" == "worktree" || "$1" == "wt" ]]; then
    # Get the branch name for this PR
    local branch_name=$(gh pr view "$pr_number" --json headRefName -q ".headRefName")
    if [[ -z "$branch_name" ]]; then
      echo "Failed to get branch name for PR #$pr_number"
      return 1
    fi
    
    # Use worktree function
    echo "Creating worktree for PR #$pr_number (branch: $branch_name)"
    gwc "$branch_name"
  else
    # Regular checkout
    echo "Checking out PR #$pr_number"
    gh pr checkout "$pr_number"
  fi
}

# Aliases for checking out PR to worktree
alias pr-me-wt='pr-me worktree'
