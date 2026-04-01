# Description: Git and directory batch operation utilities

# Usage: cherrypick-pr <#PR-number> ...
cherrypick-pr() {
    echo $* | xargs -n 1 -I {} sh -c 'git cherry-pick $(gh pr view {} --json commits | jq ".commits[].oid" --raw-output | xargs)'
}

# Usage: cherrypick-pr-to-branch <#PR-number> <remote/branch> <new-branch-name>
cherrypick-pr-to-branch() {
    local PR_NUMBER=$1
    local BRANCH=$2
    local NEW_BRANCH=$3
    echo "Cherry-picking PR $PR_NUMBER to branch $BRANCH"
    git checkout -b $NEW_BRANCH $BRANCH || (git checkout $NEW_BRANCH && git reset --hard $BRANCH)
    cherrypick-pr $PR_NUMBER
}

# Helper function to create a new changelog for velero repos
new-changelog() {
    GH_LOGIN=$(gh pr view --json author --jq .author.login 2> /dev/null)
    GH_PR_NUMBER=$(gh pr view --json number --jq .number 2> /dev/null)
    CHANGELOG_BODY="$(gh pr view --json title --jq .title)"
    if [ "$GH_LOGIN" = "" ]; then \
        echo "branch does not have PR or cli not logged in, try 'gh auth login' or 'gh pr create'"; \
        return 1; \
    fi
    mkdir -p ./changelogs/unreleased/ && \
    echo $CHANGELOG_BODY > ./changelogs/unreleased/$GH_PR_NUMBER-$GH_LOGIN && \
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
    go get $1 && go mod tidy && git add go.mod go.sum && git commit -sm "go-mod-upgrade: $1"
}

# run go mod upgrade for each dir matched by find . -type d -maxdepth 1 -name "<$1>"
# $1 is dir pattern
# $2 is go mod to upgrade
# $3 is additional commands to execute such as "gsed -i \"s/golang:1.22-bookworm/golang:1.23-bookworm/g\" Dockerfile && git add Dockerfile"
# $4 is text to prefix commit/PR title such as "CVE-2025-22869: "
# Examples: GOTOOLCHAIN=go1.23.6 go-mod-upgrade-dirs "velero*" golang.org/x/oauth2@v0.27.0
# Examples: GOTOOLCHAIN=go1.23.6 go-mod-upgrade-dirs "velero*" golang.org/x/crypto@v0.35.0 "gsed -i \"s/golang:1.22-bookworm/golang:1.23-bookworm/g\" Dockerfile && git add Dockerfile" CVE-2025-22869
go-mod-upgrade-dirs() {
    find . -type d -maxdepth 1 -name "$1" -exec sh -c "cd {} && pwd && \
        git fetch upstream && (git checkout upstream/main || git checkout upstream/master || git checkout upstream/oadp-dev) && \
        (git checkout -b $2 || git checkout $2) && \
        go get $2 && go mod tidy && git add go.mod go.sum && \
        sh -c \"$3\" && \
        git commit -sm \"$4$2\" && \
        gh pr create --web --title \"$4$2\"" \;
}

# execute commands in dirs matched by find . -type d -maxdepth 1 -name "<$1>"
# Examples: exec-dirs "velero*" branch-name "command"
# Examples: exec-dirs "velero*" golang.org/x/oauth2@v0.27.0 "pwd && pwd"
# Examples: exec-dirs "velero*" golang.org/x/oauth2@v0.27.0 "snyk test"
exec-dirs() {
    find . -type d -maxdepth 1 -name "$1" -exec sh -c "cd {} && pwd && git fetch upstream && (git checkout upstream/main || git checkout upstream/master || git checkout upstream/oadp-dev) && (git checkout -b $2 || git checkout $2) && sh -c \"$3\"" \;
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
    local pattern="$1"
    local ds_name="$2"
    local base_branch="$3"
    local branch_name="$4"
    local cmd="$5"
    local echo_only=false

    # Use find to locate matching directories
    find . -type d -maxdepth 1 -name "$pattern" | while read dir; do
        (
            echo "\033[1;34mProcessing $dir...\033[0m"
            cd "$dir" || { echo "\033[1;31mFailed to cd into $dir\033[0m"; return 1; }

            echo "Fetching from $ds_name..."
            git fetch $ds_name || { echo "\033[1;31mFailed to fetch $ds_name\033[0m"; return 1; }

            echo "Checking out $ds_name/$base_branch..."
            git checkout $ds_name/$base_branch || { echo "\033[1;31mFailed to checkout $ds_name/$base_branch\033[0m"; return 1; }

            branch_full="$ds_name-$base_branch-$branch_name"
            echo "Creating/checking out branch $branch_full..."
            git checkout -b $branch_full 2>/dev/null || (
                git checkout $branch_full &&
                git reset --hard $ds_name/$base_branch
            ) || { echo "\033[1;31mFailed to setup branch $branch_full\033[0m"; return 1; }

            if [ "$echo_only" = true ]; then
                echo "Would execute: $cmd"
            else
                echo "Executing command..."
                sh -c "$cmd" || { echo "\033[1;31mCommand execution failed\033[0m"; return 1; }

                echo "Pushing branch..."
                git push --force -u origin $branch_full || { echo "\033[1;31mFailed to push branch\033[0m"; return 1; }

                echo "Creating PR..."
                repo_name=${dir:t}
                gh pr create --repo $ds_name/$repo_name --base $base_branch --title "$base_branch-$branch_name" || {
                    echo "\033[1;31mFailed to create PR, but branch was pushed. Create PR manually for $ds_name/$repo_name\033[0m";
                }
            fi

            echo "\033[1;32mCompleted processing $dir\033[0m"
        )
    done
}

# Echo-only version of exec-dirs-ds (for testing what would happen)
exec-dirs-ds-echo() {
    local pattern="$1"
    local ds_name="$2"
    local base_branch="$3"
    local branch_name="$4"
    local cmd="$5"

    # Pass the same arguments but set a flag to only echo commands
    find . -type d -maxdepth 1 -name "$pattern" | while read dir; do
        echo "\033[1;34mWould process $dir\033[0m"
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
    find . -type d -maxdepth 1 -name "$1" | parallel code {}
}

# open all dirs matching pattern in finder
# ex: finder-dirs "velero*"
finder-dirs() {
    find . -type d -maxdepth 1 -name "$1" | parallel open -a Finder {}
}
