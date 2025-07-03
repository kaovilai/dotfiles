# GitHub CLI related aliases
alias gh-pr-view='gh pr view --web'

# Clone and open repo in VS Code
ghcc() {
  if [ -z "$1" ]; then
    echo "Usage: ghcc <repo>"
    echo "Example: ghcc owner/repo or ghcc https://github.com/owner/repo"
    return 1
  fi
  
  local repo_spec="$1"
  local repo_name
  
  # Handle full GitHub URLs
  if [[ "$1" =~ ^https?://github\.com/(.+)$ ]]; then
    # Extract owner/repo from URL
    repo_spec="${BASH_REMATCH[1]}"
    # Remove .git suffix if present
    repo_spec="${repo_spec%.git}"
  fi
  
  # Extract just the repo name for the directory
  repo_name=$(basename "$repo_spec")
  
  # Clone the repo
  gh repo clone "$repo_spec" && cd "$repo_name" && code .
}
alias ghclone='ghcc'

# Fork, clone and open repo in VS Code
ghfc() {
  if [ -z "$1" ]; then
    echo "Usage: ghfc <repo>"
    echo "Example: ghfc owner/repo or ghfc https://github.com/owner/repo"
    return 1
  fi
  
  local repo_spec="$1"
  local repo_name
  local target_dir="${2:-$PWD}"  # Use second argument or current directory
  
  # Handle full GitHub URLs
  if [[ "$1" =~ ^https?://github\.com/(.+)$ ]]; then
    # Extract owner/repo from URL
    repo_spec="${BASH_REMATCH[1]}"
    # Remove .git suffix if present
    repo_spec="${repo_spec%.git}"
  fi
  
  # Extract just the repo name for the directory
  repo_name=$(basename "$repo_spec")
  
  # Fork the repo first (without cloning)
  echo "Forking $repo_spec..."
  if ! gh repo fork "$repo_spec" --remote=false; then
    echo "Failed to fork repository"
    return 1
  fi
  
  # Get the current user's GitHub username
  local gh_user=$(gh api user --jq .login)
  
  # Clone the forked repo
  echo "Cloning fork..."
  if gh repo clone "$gh_user/$repo_name" "$target_dir/$repo_name"; then
    cd "$target_dir/$repo_name"
    
    # Add upstream remote
    local upstream_url="https://github.com/$repo_spec.git"
    git remote add upstream "$upstream_url"
    echo "Added upstream remote: $upstream_url"
    
    code .
  else
    echo "Failed to clone forked repository"
    return 1
  fi
}
alias ghfork='ghfc'
alias pr-view='gh pr view --web'
alias pr-comment='gh pr comment --body'
alias pr-label='gh pr label --add'
alias pr-unlabel='gh pr label --remove'
alias pr-close='gh pr close'
alias pr-reopen='gh pr reopen'
alias pr-merge='gh pr merge --merge-method squash'
alias pr-merge-rebase='gh pr merge --merge-method rebase'
alias pr-merge-squash='gh pr merge --merge-method squash'
alias pr-create='gh pr create'
alias pr-create-draft='gh pr create --draft'
alias pr-create-title='gh pr create --title'
alias pr-create-body='gh pr create --body'
alias pr-create-assignee='gh pr create --assignee'
alias pr-create-reviewer='gh pr create --reviewer'
alias pr-create-label='gh pr create --label'
alias pr-create-milestone='gh pr create --milestone'
alias pr-create-project='gh pr create --project'
alias pr-create-branch='gh pr create --branch'
alias pr-create-head='gh pr create --head'
alias pr-create-base='gh pr create --base'
alias pr-create-target='gh pr create --target'
alias pr-create-draft-title='gh pr create --draft --title'
alias pr-create-draft-body='gh pr create --draft --body'
alias pr-checkout='gh pr checkout'
alias pr-checkout-branch='gh pr checkout --branch'
alias pr-checkout-head='gh pr checkout --head'
alias pr-checkout-base='gh pr checkout --base'
alias pr-checkout-target='gh pr checkout --target'
alias pr-checkout-draft='gh pr checkout --draft'
alias pr-checkout-draft-title='gh pr checkout --draft --title'
alias pr-checkout-draft-body='gh pr checkout --draft --body'
alias pr-checkout-draft-branch='gh pr checkout --draft --branch'
alias pr-checkout-draft-head='gh pr checkout --draft --head'
alias pr-checkout-draft-base='gh pr checkout --draft --base'
alias pr-checkout-draft-target='gh pr checkout --draft --target'
alias pr-checkout-title='gh pr checkout --title'
alias pr-checkout-body='gh pr checkout --body'
alias pr-checkout-branch='gh pr checkout --branch'
alias pr-checkout-head='gh pr checkout --head'
alias pr-checkout-base='gh pr checkout --base'
alias pr-checkout-target='gh pr checkout --target'
alias pr-checkout-assignee='gh pr checkout --assignee'
alias pr-checkout-reviewer='gh pr checkout --reviewer'
alias pr-checkout-label='gh pr checkout --label'
alias pr-checkout-milestone='gh pr checkout --milestone'
alias pr-checkout-project='gh pr checkout --project'
alias pr-checkout-draft-assignee='gh pr checkout --draft --assignee'
alias pr-checkout-draft-reviewer='gh pr checkout --draft --reviewer'
alias pr-checkout-draft-label='gh pr checkout --draft --label'
alias pr-checkout-draft-milestone='gh pr checkout --draft --milestone'
alias pr-checkout-draft-project='gh pr checkout --draft --project'
alias pr-checkout-draft-branch='gh pr checkout --draft --branch'
alias pr-checkout-draft-head='gh pr checkout --draft --head'
alias pr-checkout-draft-base='gh pr checkout --draft --base'
alias pr-checkout-draft-target='gh pr checkout --draft --target'
alias changelog-not-required='((gh pr view --json labels | jq .labels | grep -q "kind/changelog-not-required") || (gh pr comment --body "/kind changelog-not-required" && until (gh pr view --json labels | jq .labels | grep "kind/changelog-not-required"); do sleep 1; done && gh pr close $(gh pr view --json number | jq .number) && gh pr reopen $(gh pr view --json number | jq .number)))'

# Set GitHub default repository to upstream
gh-set-default-upstream() {
  local upstream_url=$(git remote get-url upstream 2>/dev/null)
  if [ -z "$upstream_url" ]; then
    echo "Error: No upstream remote found"
    return 1
  fi
  
  # Extract owner/repo from the upstream URL
  local repo_spec
  if [[ "$upstream_url" =~ github\.com[:/]([^/]+/[^/]+)(\.git)?$ ]]; then
    repo_spec="${BASH_REMATCH[1]}"
    gh repo set-default "$repo_spec"
  else
    echo "Error: Could not parse upstream URL: $upstream_url"
    return 1
  fi
}
alias ghsdu='gh-set-default-upstream'
alias gh-set-upstream-default='gh-set-default-upstream'
