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

znap function go-mod-upgrade(){
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
znap function go-mod-upgrade-dirs(){
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
znap function exec-dirs(){
    find . -type d -maxdepth 1 -name "$1" -exec sh -c "cd {} && pwd && git fetch upstream && (git checkout upstream/main || git checkout upstream/master) && (git checkout -b $2 || git checkout $2) && sh -c \"$3\"" \;
}

# Improved version of exec-dirs-ds and exec-dirs-ds-echo with better error handling,
# progress feedback, and streamlined implementation
# 
# $1: path pattern
# $2: ds name (downstream)
# $3: base branch
# $4: branch checkout name
# $5: command
znap function exec-dirs-ds(){
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
                repo_name=$(basename $dir)
                gh pr create --repo $ds_name/$repo_name --base $base_branch --title "$base_branch-$branch_name" || { 
                    echo "\033[1;31mFailed to create PR, but branch was pushed. Create PR manually for $ds_name/$repo_name\033[0m";
                }
            fi
            
            echo "\033[1;32mCompleted processing $dir\033[0m"
        )
    done
}

# Echo-only version of exec-dirs-ds (for testing what would happen)
znap function exec-dirs-ds-echo(){
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
        echo "  Would push branch and create PR to $ds_name/$(basename $dir) base $base_branch"
    done
}

# open all dirs matching patterh in code
# ex: code-dirs "velero*"
znap function code-dirs() {
    find . -type d -maxdepth 1 -name "$1" | parallel code {}
}

# open all dirs matching patterh in finder
# ex: finder-dirs "velero*"
znap function finder-dirs() {
    find . -type d -maxdepth 1 -name "$1" | parallel open -a Finder {}
}


# # Non Essentials -- for vscode
if [[ "$TERM_PROGRAM" != "vscode" ]]; then
    # Get the current WiFi standard (Wi-Fi 5, 6, 6E, 7)
    # Usage: wifi-standard
    znap function wifi-standard() {
        # Debug: uncomment to see when function is called
        echo "DEBUG: wifi-standard function called" >&2
        local wifi_info=$(system_profiler SPAirPortDataType 2>/dev/null)
        
        # Check if WiFi is connected by looking for "Status: Connected"
        if [[ -z "$wifi_info" || ! "$wifi_info" =~ "Status: Connected" ]]; then
            echo "Not connected to WiFi"
            return 1
        fi
        
        # Extract PHY mode which contains the standard information
        # Look for PHY Mode under Current Network Information section
        local phy_mode=$(echo "$wifi_info" | grep -A 20 "Current Network Information:" | grep -i "PHY Mode:" | head -1 | awk -F': ' '{print $2}')
        
        # Extract channel information to check for 6 GHz band
        local channel_info=$(echo "$wifi_info" | grep -A 20 "Current Network Information:" | grep -i "Channel:" | head -1)
        
        # Map PHY mode to user-friendly WiFi standard names
        case "$phy_mode" in
            *802.11ax*)
                # Check for 6 GHz band which would indicate Wi-Fi 6E
                if [[ "$channel_info" =~ "6GHz" || "$channel_info" =~ "6 GHz" ]]; then
                    echo "Wi-Fi 6E (802.11ax, 6 GHz)"
                else
                    echo "Wi-Fi 6 (802.11ax)"
                fi
                ;;
            *802.11be*)
                echo "Wi-Fi 7 (802.11be)"
                ;;
            *802.11ac*)
                echo "Wi-Fi 5 (802.11ac)"
                ;;
            *802.11n*)
                echo "Wi-Fi 4 (802.11n)"
                ;;
            *802.11a*)
                echo "Wi-Fi 2 (802.11a)"
                ;;
            *802.11g*)
                echo "Wi-Fi 3 (802.11g)"
                ;;
            *802.11b*)
                echo "Wi-Fi 1 (802.11b)"
                ;;
            *)
                # If we can't determine the standard, show the raw PHY mode
                if [[ -n "$phy_mode" ]]; then
                    echo "WiFi standard: $phy_mode"
                else
                    echo "Unknown WiFi standard"
                fi
                ;;
        esac
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
    znap function view-pr-dirs() {
        find . -type d -maxdepth 1 -name "$1" -exec sh -c "cd {} && pwd && gh pr view --web" \;
    }

    # Recreate symlinks for directories previously created with symlink-to-sd
    # Useful when moving to a new machine where the SD volume exists but original symlinks don't
    # Usage: relink-from-sd <sd-path> [<local-path>]
    # Example: relink-from-sd /Volumes/SD/Users/olduser/git/project /Users/newuser/git/project
    znap function relink-from-sd() {
        local sd_path="$1"
        local local_path="$2"
        
        # Check if SD volume is mounted
        if [ ! -d "/Volumes/SD" ]; then
            echo "Error: SD volume is not mounted at /Volumes/SD"
            return 1
        fi
        
        # Validate SD path exists
        if [ ! -d "$sd_path" ]; then
            echo "Error: The specified SD path does not exist: $sd_path"
            return 1
        fi
        
        # Ensure SD path is actually on the SD volume
        if [[ ! "$sd_path" == "/Volumes/SD"* ]]; then
            echo "Error: The specified path is not on the SD volume: $sd_path"
            return 1
        fi
        
        # If local path is not provided, derive it from the SD path
        if [ -z "$local_path" ]; then
            # Remove "/Volumes/SD" prefix to get the original path
            local_path="${sd_path#/Volumes/SD}"
            echo "No local path specified, derived path: $local_path"
        fi
        
        # Check if local path already exists
        if [ -e "$local_path" ]; then
            echo "Error: Local path already exists: $local_path"
            echo "Please remove it first or specify a different path."
            return 1
        fi
        
        # Create parent directory structure
        local parent_dir="$(dirname "$local_path")"
        echo "Creating parent directory structure: $parent_dir"
        if ! mkdir -p "$parent_dir"; then
            echo "Error: Failed to create parent directory structure"
            return 1
        fi
        
        # Create the symlink
        echo "Creating symlink: $local_path -> $sd_path"
        if ! ln -s "$sd_path" "$local_path"; then
            echo "Error: Failed to create symlink"
            return 1
        fi
        
        echo "Operation completed successfully."
        echo "Symlink created: $local_path -> $sd_path"
    }
fi
