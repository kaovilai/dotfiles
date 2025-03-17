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

# git checkout -b CVE-2025-22869+CVE-2025-22868 && go get golang.org/x/oauth2@v0.27.0  golang.org/x/crypto@v0.35.0 toolchain@1.23.6 && go mod tidy && git add go.mod go.sum && find . -type f -name "Dockerfile" -name "Tiltfile" -exec sed s/golang:1.22.10/golang:1.23.6/g {} \;

# execute commands in dirs matched by find . -type d -maxdepth 1 -name "<$1>"
# Examples: exec-dirs "velero*" branch-name "command"
# Examples: exec-dirs "velero*" golang.org/x/oauth2@v0.27.0 "pwd && pwd"
# Examples: exec-dirs "velero*" golang.org/x/oauth2@v0.27.0 "snyk test"
#   find . -type f -name \"Dockerfile*\" -name \"Tiltfile\" -exec sed s/golang:1.22.10/golang:1.23.6/g {} \; \
#   find . -type f -name \"Dockerfile*\" -name \"Tiltfile\" -exec git add {} \;"
function exec-dirs(){
    find . -type d -maxdepth 1 -name "$1" -exec sh -c "cd {} && pwd && git fetch upstream && (git checkout upstream/main || git checkout upstream/master) && (git checkout -b $2 || git checkout $2) && sh -c \"$3\"" \;
}

# like exec-dirs but for downstream
# $1: path pattern
# $2: ds name
# $3: base branch
# $4: branch checkout name
# $5: command
# Examples: exec-dirs-ds "velero*" openshift oadp-1.3 CVE-2025-22869+CVE-2025-22868+CVE-2025-22870 'go get golang.org/x/oauth2@v0.27.0 golang.org/x/crypto@v0.35.0 golang.org/x/net@v0.36.0 toolchain@1.23.6 && go mod tidy && git add go.mod go.sum && \
#    find . -type f \( -name "Dockerfile*" -or -name "Tiltfile" \) -not -path "./\.go/*" -exec gsed -i s/golang:1.22.10/golang:1.23.6/g \{\} \; && \
#    find . -type f \( -name "Dockerfile*" -or -name "Tiltfile" \) -not -path "./\.go/*" -exec git add \{\} \; ; \
#    find . -type f \( -name "Dockerfile*" -or -name "Tiltfile" \) -not -path "./\.go/*" -exec gsed -i s#quay.io/konveyor/builder:ubi9-v1.20#quay.io/konveyor/builder:ubi9-v1.23#g \{\} \; && \
#    find . -type f \( -name "Dockerfile*" -or -name "Tiltfile" \) -not -path "./\.go/*" -exec git add \{\} \; ; \
#    (git commit -m "CVE-2025-22869+CVE-2025-22868+CVE-2025-22870" --signoff || echo "nothing to comit")'
function exec-dirs-ds(){
    find . -type d -maxdepth 1 -name "$1" -exec sh -c "cd {} && pwd && git fetch $2 && (git checkout $2/$3) && (git checkout -b $2-$3-$4 || git checkout $2-$3-$4 && git reset --hard $2/$3) && sh -c '$5' && git push --force -u origin $2-$3-$4 && gh pr create --repo $2/\$(basename {}) --base $3 --title \"$3-$4\"" \;
}
function exec-dirs-ds-echo(){
    find . -type d -maxdepth 1 -name "$1" -exec sh -c "cd {} && pwd && git fetch $2 && (git checkout $2/$3) && (git checkout -b $2-$3-$4 || git checkout $2-$3-$4 && git reset --hard $2/$3) && echo -c '$5' && echo git push --force -u origin $2-$3-$4 && gh pr create --repo $2/\$(basename {}) --base $3 --title \"$3-$4\"" \;
}

# open all dirs matching patterh in code
# ex: code-dirs "velero*"
function code-dirs() {
    find . -type d -maxdepth 1 -name "$1" | parallel code {}
}

# open all dirs matching patterh in finder
# ex: finder-dirs "velero*"
function finder-dirs() {
    find . -type d -maxdepth 1 -name "$1" | parallel open -a Finder {}
}

# Move files to SD volume and create a symlink in their place to save disk space
# Usage: symlink-to-sd
znap function symlink-to-sd() {
    local current_dir="$(pwd)"
    local current_name="$(basename "$current_dir")"
    local parent_dir="$(dirname "$current_dir")"
    local sd_target="/Volumes/SD$current_dir"
    local sd_backup="/Volumes/SD$current_dir.backup.$(date +%Y%m%d%H%M%S)"
    
    # Check if SD volume is mounted
    if [ ! -d "/Volumes/SD" ]; then
        echo "Error: SD volume is not mounted at /Volumes/SD"
        return 1
    fi
    
    # Create parent directory structure on SD
    if ! mkdir -p "$(dirname "$sd_target")"; then
        echo "Error: Failed to create directory structure on SD volume"
        return 1
    fi
    
    # Create target directory
    if ! mkdir -p "$sd_target"; then
        echo "Error: Failed to create target directory on SD volume"
        return 1
    fi
    
    echo "Copying files from $current_dir to $sd_target..."
    
    # Copy all files (including hidden files)
    if ! cp -R "$current_dir/"* "$sd_target/" 2>/dev/null; then
        echo "Warning: Some files may not have been copied (possibly empty dir)"
    fi
    
    # Copy hidden files separately (since * doesn't match them)
    # Use find to avoid issues with .* expanding to include . and ..
    find "$current_dir" -maxdepth 1 -name ".*" -type f -o -name ".*" -type d ! -path "$current_dir" | while read file; do
        cp -R "$file" "$sd_target/" 2>/dev/null || echo "Warning: Could not copy $(basename "$file")"
    done
    
    echo "Files copied to SD volume successfully."
    
    # Create a backup directory ON THE SD VOLUME
    echo "Creating backup on SD volume at $sd_backup..."
    mkdir -p "$sd_backup"
    cp -R "$sd_target/"* "$sd_backup/" 2>/dev/null || true
    
    # Backup hidden files using find to avoid issues with .* expansion
    find "$sd_target" -maxdepth 1 -name ".*" -type f -o -name ".*" -type d ! -path "$sd_target" | while read file; do
        cp -R "$file" "$sd_backup/" 2>/dev/null || echo "Warning: Could not backup $(basename "$file")"
    done
    
    # Navigate to parent directory so we can replace the current directory
    echo "Changing to parent directory: $parent_dir"
    cd "$parent_dir" || {
        echo "Error: Failed to change directory to $parent_dir"
        return 1
    }
    
    # Remove the original directory
    echo "Removing original directory to save space..."
    rm -rf "$current_name"
    
    # Create symlink at the original location pointing to SD volume
    echo "Creating symlink to replace the original directory..."
    ln -s "$sd_target" "$current_name"
    
    # Change back to the "same" directory (now a symlink to SD)
    cd "$current_dir" 2>/dev/null || echo "Note: Could not cd back to $current_dir"
    
    echo "Operation completed successfully."
    echo "Files are now stored at: $sd_target"
    echo "The original path $current_dir now points to the SD volume."
    echo "A backup was created on the SD volume at: $sd_backup"
}

# Undo the symlink-to-sd operation by moving files back from SD volume
# Usage: unsymlink-from-sd [--keep-sd-files]
znap function unsymlink-from-sd() {
    local current_path="$(pwd)"
    local parent_dir="$(dirname "$current_path")"
    local dir_name="$(basename "$current_path")"
    local keep_sd_files=false
    
    # Check for option to keep SD files
    if [[ "$1" == "--keep-sd-files" ]]; then
        keep_sd_files=true
    fi
    
    # Check if current directory is a symlink
    if [[ ! -L "$current_path" ]]; then
        # Try parent directory if we're inside a symlinked directory
        cd ..
        if [[ -L "$(pwd)" ]]; then
            current_path="$(pwd)"
            parent_dir="$(dirname "$current_path")"
            dir_name="$(basename "$current_path")"
        else
            echo "Error: Current directory is not a symlink created by symlink-to-sd"
            return 1
        fi
    fi
    
    # Get the target of the symlink
    local symlink_target="$(readlink "$current_path")"
    
    # Verify that this is a symlink to the SD volume
    if [[ ! "$symlink_target" == "/Volumes/SD"* ]]; then
        echo "Error: This symlink doesn't point to the SD volume"
        return 1
    fi
    
    # Check if SD volume is mounted
    if [ ! -d "/Volumes/SD" ]; then
        echo "Error: SD volume is not mounted at /Volumes/SD"
        return 1
    fi
    
    echo "Preparing to restore files from $symlink_target to $current_path..."
    
    # Navigate to parent directory to replace the symlink
    cd "$parent_dir"
    
    # Create a temporary directory to hold files during transfer
    local temp_dir="$parent_dir/.temp_restore_$dir_name"
    mkdir -p "$temp_dir"
    
    # Copy files from SD volume to temporary directory
    echo "Copying files from SD volume to temporary location..."
    if ! cp -R "$symlink_target/"* "$temp_dir/" 2>/dev/null; then
        echo "Warning: Some files may not have been copied (possibly empty dir)"
    fi
    
    # Copy hidden files separately using find to avoid .* expansion issues
    find "$symlink_target" -maxdepth 1 -name ".*" -type f -o -name ".*" -type d ! -path "$symlink_target" | while read file; do
        cp -R "$file" "$temp_dir/" 2>/dev/null || echo "Warning: Could not copy $(basename "$file")"
    done
    
    # Remove the symlink
    echo "Removing symlink..."
    rm "$dir_name"
    
    # Create the directory and move files
    echo "Restoring files to original location..."
    mkdir -p "$dir_name"
    mv "$temp_dir"/* "$dir_name/" 2>/dev/null || true
    
    # Move hidden files using find to avoid expansion issues
    find "$temp_dir" -maxdepth 1 -name ".*" -type f -o -name ".*" -type d ! -path "$temp_dir" | while read file; do
        mv "$file" "$dir_name/" 2>/dev/null || echo "Warning: Could not move $(basename "$file")"
    done
    
    # Remove temporary directory
    rm -rf "$temp_dir"
    
    # Remove files from SD volume if requested
    if ! $keep_sd_files; then
        echo "Removing files from SD volume..."
        rm -rf "$symlink_target"
    else
        echo "Files on SD volume have been kept as requested."
    fi
    
    echo "Operation completed successfully."
    echo "Files have been moved back to their original location: $current_path"
    echo "The symbolic link has been replaced with a regular directory."
    
    # Change back to the original directory
    cd "$current_path"
}

# view current prs in dirs matched by find . -type d -maxdepth 1 -name "<$1>"
# view-pr-dirs "velero*"
function view-pr-dirs() {
    find . -type d -maxdepth 1 -name "$1" -exec sh -c "cd {} && pwd && gh pr view --web" \;
}
