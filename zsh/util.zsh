# Description: Utility functions
# update go mod
# ORG=openshift REPO=$(basename $PWD) BRANCH=oadp-1.2 PACKAGE=google.golang.org/grpc@v1.56.3 ISSUE="CVE-2023-44487-gRPC-Go" && git checkout $ORG/$BRANCH && git checkout -b $ISSUE-$BRANCH && go get $package && go mod tidy && git add go.mod go.sum && git commit -m "$BRANCH: CVE-2023-44487 gRPC-Go HTTP/2 Rapid Reset vulnerability" --signoff && gh pr create --base $BRANCH --repo $ORG/velero-plugin-for-gcp

# Usage: cherrypick-pr <#PR-number> ...
znap function cherrypick-pr() {
    echo $* | xargs -n 1 -I {} sh -c 'git cherry-pick $(gh pr view {} --json commits | jq ".commits[].oid" --raw-output | xargs)'
}

# Usage: cherrypick-pr-to-branch <#PR-number> <remote/branch> <new-branch-name>
znap function cherrypick-pr-to-branch() {
    local PR_NUMBER=$1
    local BRANCH=$2
    local NEW_BRANCH=$3
    echo "Cherry-picking PR $PR_NUMBER to branch $BRANCH"
    git checkout -b $NEW_BRANCH $BRANCH || (git checkout $NEW_BRANCH && git reset --hard $BRANCH)
    cherrypick-pr $PR_NUMBER
}

# Helper function to create a new changelog for velero repos
znap function new-changelog(){
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

znap function code-git(){
    code ~/git/$1
}

#compdef code-git

_code-git() {
    local -a files
    files=(${(f)"$(ls ~/git)"})
    _describe 'files' files
}

compdef _code-git code-git

function go-mod-upgrade(){
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
function go-mod-upgrade-dirs(){
    find . -type d -maxdepth 1 -name "$1" -exec sh -c "cd {} && pwd && \
        git fetch upstream && (git checkout upstream/main || git checkout upstream/master) && \
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
function exec-dirs(){
    find . -type d -maxdepth 1 -name "$1" -exec sh -c "cd {} && pwd && git fetch upstream && (git checkout upstream/main || git checkout upstream/master) && (git checkout -b $2 || git checkout $2) && sh -c \"$3\"" \;
}

# open all dirs matching patterh in code
# ex: code-dirs "velero*"
function code-dirs() {
    find . -type d -maxdepth 1 -name "$1" | parallel code {}
}

# view current prs in dirs matched by find . -type d -maxdepth 1 -name "<$1>"
# view-pr-dirs "velero*"
function view-pr-dirs() {
    find . -type d -maxdepth 1 -name "$1" -exec sh -c "cd {} && pwd && gh pr view --web" \;
}
