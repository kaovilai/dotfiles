# Description: Git and directory batch operation utilities

# Usage: cherrypick-pr <#PR-number> ...
cherrypick-pr() {
    if ! command -v gh &>/dev/null; then
        echo "❌ gh not found. Install it with: brew install gh" >&2
        return 1
    fi
    if ! command -v jq &>/dev/null; then
        echo "❌ jq not found. Install it with: brew install jq" >&2
        return 1
    fi
    printf '%s\n' "$@" | xargs -n 1 -I {} sh -c 'git cherry-pick $(gh pr view {} --json commits | jq ".commits[].oid" --raw-output | xargs)'
}

# Usage: cherrypick-pr-to-branch <#PR-number> <remote/branch> <new-branch-name>
cherrypick-pr-to-branch() {
    if [[ -z "$1" || -z "$2" || -z "$3" ]]; then
        echo "Usage: cherrypick-pr-to-branch <PR-number> <remote/branch> <new-branch-name>"
        echo "Example: cherrypick-pr-to-branch 42 upstream/main my-backport"
        return 1
    fi
    local PR_NUMBER=$1
    local BRANCH=$2
    local NEW_BRANCH=$3
    echo "Cherry-picking PR $PR_NUMBER to branch $BRANCH"
    git checkout -b "$NEW_BRANCH" "$BRANCH" || (git checkout "$NEW_BRANCH" && git reset --hard "$BRANCH") || return 1
    cherrypick-pr "$PR_NUMBER"
}

# Helper function to create a new changelog for velero repos
new-changelog() {
    if ! command -v gh &>/dev/null; then
        echo "❌ gh not found. Install it with: brew install gh" >&2
        return 1
    fi
    if ! command -v jq &>/dev/null; then
        echo "❌ jq not found. Install it with: brew install jq" >&2
        return 1
    fi
    local GH_PR_JSON GH_LOGIN GH_PR_NUMBER CHANGELOG_BODY
    GH_PR_JSON=$(gh pr view --json author,number,title 2>/dev/null)
    GH_LOGIN=$(jq -r '.author.login' 2>/dev/null <<< "$GH_PR_JSON")
    GH_PR_NUMBER=$(jq -r '.number' 2>/dev/null <<< "$GH_PR_JSON")
    CHANGELOG_BODY=$(jq -r '.title' 2>/dev/null <<< "$GH_PR_JSON")
    if [[ -z "$GH_LOGIN" ]]; then
        echo "branch does not have PR or cli not logged in, try 'gh auth login' or 'gh pr create'"
        return 1
    fi
    if [[ -z "$GH_PR_NUMBER" ]]; then
        echo "Could not determine PR number. Make sure the branch has an open PR."
        return 1
    fi
    mkdir -p ./changelogs/unreleased/ && \
    echo "$CHANGELOG_BODY" > "./changelogs/unreleased/$GH_PR_NUMBER-$GH_LOGIN" && \
    echo "\"$CHANGELOG_BODY\" added to ./changelogs/unreleased/$GH_PR_NUMBER-$GH_LOGIN"
}

go-mod-upgrade() {
    # first argument is the package to upgrade
    if [[ -z "$1" ]]; then
    echo "Usage: go-mod-upgrade <package>"
    echo "Example: go-mod-upgrade github.com/openshift/oadp-operator"
    echo "Example: go-mod-upgrade github.com/openshift/oadp-operator@v1.2.0"
    return 1
    fi
    if ! command -v go &>/dev/null; then
        echo "❌ go not found. Install it with: brew install go" >&2
        return 1
    fi
    go get "$1" && go mod tidy && git add go.mod go.sum && git commit -sm "go-mod-upgrade: $1"
}

# run go mod upgrade for each dir matched by find . -type d -maxdepth 1 -name "<$1>"
# $1 is dir pattern
# $2 is go mod to upgrade
# $3 is additional commands to execute such as "gsed -i \"s/golang:1.22-bookworm/golang:1.23-bookworm/g\" Dockerfile && git add Dockerfile"
# $4 is text to prefix commit/PR title such as "CVE-2025-22869: "
# Examples: GOTOOLCHAIN=go1.23.6 go-mod-upgrade-dirs "velero*" golang.org/x/oauth2@v0.27.0
# Examples: GOTOOLCHAIN=go1.23.6 go-mod-upgrade-dirs "velero*" golang.org/x/crypto@v0.35.0 "gsed -i \"s/golang:1.22-bookworm/golang:1.23-bookworm/g\" Dockerfile && git add Dockerfile" CVE-2025-22869
go-mod-upgrade-dirs() {
    if [[ -z "$1" || -z "$2" ]]; then
        echo "Usage: go-mod-upgrade-dirs <dir-pattern> <package> [extra-cmd] [commit-prefix]"
        echo "Example: go-mod-upgrade-dirs \"velero*\" golang.org/x/oauth2@v0.27.0"
        return 1
    fi
    if ! command -v go &>/dev/null; then
        echo "❌ go not found. Install it with: brew install go" >&2
        return 1
    fi
    if ! command -v gh &>/dev/null; then
        echo "❌ gh not found. Install it with: brew install gh" >&2
        return 1
    fi
    find . -type d -maxdepth 1 -name "$1" -exec sh -c '
        dir="$1" pkg="$2" extra_cmd="$3" prefix="$4"
        cd "$dir" && pwd &&
        git fetch upstream && (git checkout upstream/main || git checkout upstream/master || git checkout upstream/oadp-dev) &&
        (git checkout -b "$pkg" || git checkout "$pkg") &&
        go get "$pkg" && go mod tidy && git add go.mod go.sum &&
        sh -c "$extra_cmd" &&
        git commit -sm "${prefix}${pkg}" &&
        gh pr create --web --title "${prefix}${pkg}"
    ' _ {} "$2" "$3" "$4" \;
}

# execute commands in dirs matched by find . -type d -maxdepth 1 -name "<$1>"
# Examples: exec-dirs "velero*" branch-name "command"
# Examples: exec-dirs "velero*" golang.org/x/oauth2@v0.27.0 "pwd && pwd"
# Examples: exec-dirs "velero*" golang.org/x/oauth2@v0.27.0 "snyk test"
exec-dirs() {
    if [[ -z "$1" || -z "$2" || -z "$3" ]]; then
        echo "Usage: exec-dirs <pattern> <branch> <command>"
        echo "Example: exec-dirs \"velero*\" my-branch \"go mod tidy\""
        return 1
    fi
    find . -type d -maxdepth 1 -name "$1" -exec sh -c '
        dir="$1" branch="$2" cmd="$3"
        cd "$dir" && pwd &&
        git fetch upstream && (git checkout upstream/main || git checkout upstream/master || git checkout upstream/oadp-dev) &&
        (git checkout -b "$branch" || git checkout "$branch") &&
        sh -c "$cmd"
    ' _ {} "$2" "$3" \;
}

# Improved version of exec-dirs-ds and exec-dirs-ds-echo with better error handling,
# progress feedback, and streamlined implementation
#
# $1: path pattern
# $2: ds name (downstream)
# $3: base branch
# $4: branch checkout name
# $5: command
exec-dirs-ds() {
    if ! command -v gh &>/dev/null; then
        echo "❌ gh not found. Install it with: brew install gh" >&2
        return 1
    fi
    if [[ -z "$1" || -z "$2" || -z "$3" || -z "$4" || -z "$5" ]]; then
        echo "Usage: exec-dirs-ds <pattern> <ds-name> <base-branch> <branch-name> <command>"
        echo "Example: exec-dirs-ds \"velero*\" upstream main fix-123 \"go mod tidy\""
        return 1
    fi
    local pattern="$1"
    local ds_name="$2"
    local base_branch="$3"
    local branch_name="$4"
    local cmd="$5"
    local echo_only=false

    # Use find to locate matching directories
    find . -type d -maxdepth 1 -name "$pattern" | while read -r dir; do
        (
            print "\033[1;34mProcessing $dir...\033[0m"
            cd "$dir" || { print "\033[1;31mFailed to cd into $dir\033[0m"; return 1; }

            echo "Fetching from $ds_name..."
            git fetch "$ds_name" || { print "\033[1;31mFailed to fetch $ds_name\033[0m"; return 1; }

            echo "Checking out $ds_name/$base_branch..."
            git checkout "$ds_name/$base_branch" || { print "\033[1;31mFailed to checkout $ds_name/$base_branch\033[0m"; return 1; }

            local branch_full="$ds_name-$base_branch-$branch_name"
            echo "Creating/checking out branch $branch_full..."
            git checkout -b "$branch_full" 2>/dev/null || (
                git checkout "$branch_full" &&
                git reset --hard "$ds_name/$base_branch"
            ) || { print "\033[1;31mFailed to setup branch $branch_full\033[0m"; return 1; }

            if [[ "$echo_only" == true ]]; then
                echo "Would execute: $cmd"
            else
                echo "Executing command..."
                sh -c "$cmd" || { print "\033[1;31mCommand execution failed\033[0m"; return 1; }

                echo "Pushing branch..."
                git push --force -u origin "$branch_full" || { print "\033[1;31mFailed to push branch\033[0m"; return 1; }

                echo "Creating PR..."
                local repo_name=${dir:t}
                gh pr create --repo "$ds_name/$repo_name" --base "$base_branch" --title "$base_branch-$branch_name" || {
                    print "\033[1;31mFailed to create PR, but branch was pushed. Create PR manually for $ds_name/$repo_name\033[0m";
                }
            fi

            print "\033[1;32mCompleted processing $dir\033[0m"
        )
    done
}

# Echo-only version of exec-dirs-ds (for testing what would happen)
exec-dirs-ds-echo() {
    if [[ -z "$1" || -z "$2" || -z "$3" || -z "$4" || -z "$5" ]]; then
        echo "Usage: exec-dirs-ds-echo <pattern> <ds-name> <base-branch> <branch-name> <command>"
        echo "Example: exec-dirs-ds-echo \"velero*\" upstream main fix-123 \"go mod tidy\""
        return 1
    fi
    local pattern="$1"
    local ds_name="$2"
    local base_branch="$3"
    local branch_name="$4"
    local cmd="$5"

    # Pass the same arguments but set a flag to only echo commands
    find . -type d -maxdepth 1 -name "$pattern" | while read -r dir; do
        print "\033[1;34mWould process $dir\033[0m"
        echo "  Would fetch $ds_name"
        echo "  Would checkout $ds_name/$base_branch"
        echo "  Would create/reset branch $ds_name-$base_branch-$branch_name"
        echo "  Would execute: $cmd"
        echo "  Would push branch and create PR to $ds_name/${dir:t} base $base_branch"
    done
}

# open all dirs matching pattern in code
# ex: code-dirs "velero*"
code-dirs() {
    if [[ -z "$1" ]]; then
        echo "Usage: code-dirs <pattern>"
        echo "Example: code-dirs \"velero*\""
        return 1
    fi
    if ! command -v parallel &> /dev/null; then
        echo "❌ parallel not found. Install it with: brew install parallel" >&2
        return 1
    fi
    if ! command -v code &>/dev/null; then
        echo "❌ code not found. Install VS Code and run: Shell Command: Install 'code' command in PATH" >&2
        return 1
    fi

    find . -type d -maxdepth 1 -name "$1" | parallel code {}
}

# open all dirs matching pattern in finder
# ex: finder-dirs "velero*"
finder-dirs() {
    if [[ "$OSTYPE" != darwin* ]]; then
        echo "Error: finder-dirs is only supported on macOS" >&2
        return 1
    fi
    if [[ -z "$1" ]]; then
        echo "Usage: finder-dirs <pattern>"
        echo "Example: finder-dirs \"velero*\""
        return 1
    fi
    if ! command -v parallel &> /dev/null; then
        echo "❌ parallel not found. Install it with: brew install parallel" >&2
        return 1
    fi

    find . -type d -maxdepth 1 -name "$1" | parallel open -a Finder {}
}
