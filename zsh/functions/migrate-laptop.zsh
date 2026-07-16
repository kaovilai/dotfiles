#!/usr/bin/env zsh

# Laptop Migration Functions
# Automates the process of setting up a new macOS laptop with your dotfiles

# Color codes for output — conditional so we don't overwrite user-defined values
: ${RED:=$'\033[0;31m'}
: ${GREEN:=$'\033[0;32m'}
: ${YELLOW:=$'\033[1;33m'}
: ${BLUE:=$'\033[0;34m'}
: ${NC:=$'\033[0m'}

# Progress indicator
progress() {
    echo "${BLUE}==>${NC} $1"
}

# Success indicator
success() {
    echo "${GREEN}✓${NC} $1"
}

# Warning indicator
warning() {
    echo "${YELLOW}⚠${NC} $1" >&2
}

# Error indicator
error() {
    echo "${RED}✗${NC} $1" >&2
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to manually install packages (fallback when no Brewfile)
install_packages_manually() {
    if ! command_exists brew; then
        error "brew not found. Install Homebrew: https://brew.sh"
        return 1
    fi

    # ⚡ Bolt: Cache installed packages into an array to avoid O(N) `brew list` subprocess calls.
    # Impact: Reduces N+1 subprocess queries into a single query with fast O(1) in-memory lookups.
    local -a installed_packages=($(brew list -1 2>/dev/null))

    progress "Installing essential tools..."
    local essential_tools=(
        "git"
        "gh"
        "ripgrep"
        "fzf"
        "jq"
        "yq"
        "gnupg"
        "wget"
        "curl"
    )
    
    local tool
    for tool in "${essential_tools[@]}"; do
        if (( ${installed_packages[(Ie)$tool]} )); then
            echo "  ${GREEN}✓${NC} $tool already installed"
        else
            echo "  Installing $tool..."
            brew install "$tool" || warning "Failed to install $tool"
        fi
    done
    
    progress "Installing core development tools..."
    local dev_tools=(
        "go"
        "node"
        "docker"
        "kubectl"
    )
    
    for tool in "${dev_tools[@]}"; do
        if (( ${installed_packages[(Ie)$tool]} )); then
            echo "  ${GREEN}✓${NC} $tool already installed"
        else
            echo "  Installing $tool..."
            brew install "$tool" || warning "Failed to install $tool"
        fi
    done
    
    warning "Only essential packages installed. Run 'brew bundle' to install all packages from Brewfile"
}

# Main migration function
migrate-to-new-laptop() {
    if [[ "$OSTYPE" != darwin* ]]; then
        error "migrate-to-new-laptop is only supported on macOS"
        return 1
    fi
    echo "${BLUE}Starting laptop migration setup...${NC}"
    echo ""
    
    local errors=0
    
    # Step 1: Install Homebrew if not present
    progress "Checking Homebrew..."
    if ! command_exists brew; then
        progress "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        
        # Add Homebrew to PATH for Apple Silicon
        if [[ -f "/opt/homebrew/bin/brew" ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
        success "Homebrew installed"
    else
        success "Homebrew already installed"
    fi
    
    # Step 2: Check for Brewfile
    if [[ -f ~/git/dotfiles/Brewfile ]]; then
        progress "Found Brewfile. Installing packages..."

        if command -v fzf >/dev/null 2>&1; then
            # Use fzf to let user select which packages to install
            local all_packages selected
            all_packages=$(grep -E '^(brew|cask|tap|vscode)' ~/git/dotfiles/Brewfile)
            selected=$(fzf --multi --height 60% --reverse <<< "$all_packages" \
                --header "Select packages to install (Tab to select, Enter to confirm, Ctrl+A to select all)" \
                --bind 'ctrl-a:select-all')

            if [[ -n "$selected" ]]; then
                local tmpfile
                tmpfile=$(mktemp) || { warning "Failed to create temporary file"; return 1; }
                echo "$selected" > "$tmpfile"
                brew bundle --file="$tmpfile" || warning "Some packages failed to install"
                rm "$tmpfile"
                success "Selected packages installed"
            else
                warning "No packages selected"
            fi
        else
            local use_brewfile
            read -r "use_brewfile?Install all packages from Brewfile? (y/n): "
            if [[ "$use_brewfile" == "y" ]]; then
                pushd ~/git/dotfiles || { warning "Failed to cd to ~/git/dotfiles"; return 1; }
                brew bundle || warning "Some packages failed to install"
                success "Packages installed from Brewfile"
                popd
            else
                install_packages_manually
            fi
        fi
    else
        warning "No Brewfile found. Installing essential packages manually..."
        install_packages_manually
    fi
    
    # Step 5: Setup dotfiles
    progress "Setting up dotfiles..."
    if [[ ! -f ~/.zshrc ]] || ! grep -q "source ~/git/dotfiles/.zshrc" ~/.zshrc; then
        echo "source ~/git/dotfiles/.zshrc" > ~/.zshrc
        success "Created ~/.zshrc"
    else
        success "~/.zshrc already configured"
    fi
    
    # Step 6: Create necessary directories
    progress "Creating directory structure..."
    local dirs=(
        ~/git
        ~/go
        ~/go/src
        ~/go/bin
        ~/go/pkg
        ~/.ssh
        ~/.config
    )
    local dir
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" || { error "Failed to create directory $dir"; return 1; }
            echo "  Created $dir"
        fi
    done
    
    # Step 7: Set proper permissions
    progress "Setting permissions..."
    chmod 700 ~/.ssh
    success "SSH directory permissions set"
    
    # Step 8: Install OpenShift CLI
    progress "Installing OpenShift CLI..."
    if ! command_exists oc; then
        brew install openshift-cli
        success "OpenShift CLI installed"
    else
        success "OpenShift CLI already installed"
    fi
    
    # Step 9: Setup Git
    progress "Configuring Git..."
    local git_email git_name
    read -r "git_email?Enter your Git email: "
    read -r "git_name?Enter your Git name: "
    
    git config --global user.email "$git_email"
    git config --global user.name "$git_name"
    git config --global init.defaultBranch main
    git config --global pull.rebase true
    git config --global commit.gpgsign true
    success "Git configured"
    
    # Step 10: Check for secrets file
    progress "Checking for secrets..."
    if [[ ! -f ~/secrets.zsh ]]; then
        warning "No secrets.zsh found. Creating template..."
        cat > ~/secrets.zsh << 'EOF'
# Machine-specific secrets and configurations
# DO NOT COMMIT THIS FILE

# API Keys
export GITHUB_TOKEN=""
export ANTHROPIC_API_KEY=""

# Google Vertex AI (alternative to ANTHROPIC_API_KEY; preferred when set)
export CLOUD_ML_REGION=""
export ANTHROPIC_VERTEX_PROJECT_ID=""

# Network Configuration
export TF_NETWORK_NAME=""

# Tailscale
export TAILSCALE_API_KEY=""
export TAILSCALE_TAILNET=""

# AWS (if needed)
export AWS_ACCESS_KEY_ID=""
export AWS_SECRET_ACCESS_KEY=""
export AWS_DEFAULT_REGION="us-east-1"

# Add other secrets as needed
EOF
        warning "Please edit ~/secrets.zsh and add your secrets"
    else
        success "secrets.zsh exists"
    fi
    
    # Step 11: Generate SSH key if needed
    progress "Checking SSH keys..."
    if [[ ! -f ~/.ssh/id_ed25519 ]]; then
        local generate_ssh
        read -r "generate_ssh?Generate new SSH key? (y/n): "
        if [[ "$generate_ssh" == "y" ]]; then
            ssh-keygen -t ed25519 -C "$git_email"
            success "SSH key generated"
            echo ""
            echo "${YELLOW}Add this SSH key to GitHub:${NC}"
            cat ~/.ssh/id_ed25519.pub
            echo ""
            echo "Visit: https://github.com/settings/keys"
        fi
    else
        success "SSH key already exists"
    fi
    
    # Step 12: Install VS Code extensions
    progress "Installing VS Code extensions..."
    if command_exists code; then
        local vscode_extensions=(
            "ms-vscode-remote.remote-ssh"
            "ms-vscode.cpptools"
            "golang.go"
            "ms-python.python"
            "hashicorp.terraform"
            "redhat.vscode-yaml"
            "ms-kubernetes-tools.vscode-kubernetes-tools"
        )
        local ext
        for ext in "${vscode_extensions[@]}"; do
            code --install-extension "$ext" || warning "Failed to install $ext"
        done
        success "VS Code extensions installed"
    else
        warning "VS Code CLI not found. Install extensions manually."
    fi
    
    # Final summary
    echo ""
    echo "${GREEN}========================================${NC}"
    echo "${GREEN}Migration setup complete!${NC}"
    echo "${GREEN}========================================${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Edit ~/secrets.zsh with your secrets"
    echo "2. Import your GPG keys (see docs/LAPTOP_MIGRATION.md)"
    echo "3. Configure cloud CLI tools (aws, gcloud, ibmcloud)"
    echo "4. Test your setup with verification commands"
    echo ""
    echo "Run 'source ~/.zshrc' to reload your shell configuration"
}

# WiFi credential export/import functions
export-wifi-credentials() {
    if [[ "$OSTYPE" != darwin* ]]; then
        error "export-wifi-credentials is only supported on macOS"
        return 1
    fi
    local export_dir="${1:-$HOME/wifi-credentials-export}"
    
    progress "Exporting WiFi credentials..."
    
    # Create export directory
    mkdir -p "$export_dir" || { error "Failed to create export directory $export_dir"; return 1; }
    chmod 700 "$export_dir"
    
    # Export WiFi profiles
    local wifi_file="$export_dir/wifi-networks.xml"
    
    # Get list of WiFi networks
    progress "Finding saved WiFi networks..."
    local networks _wifi_iface network
    _wifi_iface=$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi/{found=1} found && /Device:/{print $2; exit}')
    networks=$(networksetup -listpreferredwirelessnetworks "${_wifi_iface:-en0}" 2>/dev/null | tail -n +2 | sed 's/^[[:space:]]*//')
    
    if [[ -z "$networks" ]]; then
        error "No WiFi networks found"
        return 1
    fi
    
    # Create plist file with network information
    cat > "$wifi_file" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>WiFiNetworks</key>
    <array>
EOF
    
    # Export each network
    while IFS= read -r network; do
        if [[ -n "$network" ]]; then
            echo "  Exporting: $network"
            cat >> "$wifi_file" << EOF
        <dict>
            <key>SSID</key>
            <string>$network</string>
        </dict>
EOF
        fi
    done <<< "$networks"
    
    cat >> "$wifi_file" << 'EOF'
    </array>
</dict>
</plist>
EOF
    
    # Create a script to help with importing
    cat > "$export_dir/import-wifi.sh" << 'EOF'
#!/bin/bash
# Import WiFi networks on new laptop
# Note: This will require manual password entry for each network

echo "WiFi Network Import Helper"
echo "========================="
echo ""
echo "This script will help you add the WiFi networks from your old laptop."
echo "You'll need to enter the password for each network manually."
echo ""

# Read the network list
networks=$(xmllint --xpath "//string/text()" wifi-networks.xml 2>/dev/null | sort -u)

if [[ -z "$networks" ]]; then
    echo "No networks found in wifi-networks.xml"
    exit 1
fi

echo "Found networks:"
echo "$networks" | nl -b a
echo ""

# Get the WiFi interface
wifi_interface=$(networksetup -listallhardwareports | awk '/Wi-Fi|Airport/{getline; print $2}')

if [[ -z "$wifi_interface" ]]; then
    echo "Could not find WiFi interface"
    exit 1
fi

echo "WiFi interface: $wifi_interface"
echo ""

# Process each network
echo "$networks" | while IFS= read -r network; do
    if [[ -n "$network" ]]; then
        echo ""
        echo "Network: $network"
        read -r -p "Add this network? (y/n): " add_network
        
        if [[ "$add_network" == "y" ]]; then
            # Prompt for password
            echo "Enter the password for '$network' (or press Enter to skip):"
            read -rs password
            echo ""
            
            if [[ -n "$password" ]]; then
                # Add the network
                if networksetup -addpreferredwirelessnetworkatindex "$wifi_interface" "$network" 0 WPA2 "$password"; then
                    echo "✓ Added $network"
                else
                    echo "✗ Failed to add $network" >&2
                fi
            else
                echo "Skipped $network (no password provided)"
            fi
        else
            echo "Skipped $network"
        fi
    fi
done

echo ""
echo "Import complete!"
echo ""
echo "To verify, run:"
echo "networksetup -listpreferredwirelessnetworks $wifi_interface"
EOF
    
    chmod +x "$export_dir/import-wifi.sh"
    
    # Create instructions
    cat > "$export_dir/README.txt" << EOF
WiFi Credentials Export
======================
Created: $(date)
Machine: $(hostname)

This directory contains:
- wifi-networks.xml: List of saved WiFi networks
- import-wifi.sh: Script to help import networks on new laptop

To transfer to new laptop:
1. Copy this entire directory to the new laptop
2. On the new laptop, run: ./import-wifi.sh
3. Enter the password for each network when prompted

Alternative manual method:
- Open System Preferences > Network > WiFi > Advanced
- Add networks manually using the SSID names in wifi-networks.xml

Security Note:
- Passwords are NOT exported for security reasons
- You'll need to enter passwords manually on the new laptop
- Delete this directory after successful import
EOF
    
    success "WiFi networks exported to $export_dir"
    echo ""
    local -a _networks_list=("${(@f)networks}")
    echo "Found ${#_networks_list} networks"
    echo ""
    echo "${YELLOW}Next steps:${NC}"
    echo "1. Copy $export_dir to your new laptop"
    echo "2. Run the import script on the new laptop"
    echo "3. Have your WiFi passwords ready"
    
    # Offer to create a compressed archive
    echo ""
    local create_archive
    read -r "create_archive?Create compressed archive? (y/n): "
    if [[ "$create_archive" == "y" ]]; then
        local archive_name="wifi-export-$(date +%Y%m%d-%H%M%S).tar.gz"
        tar -czf "$HOME/$archive_name" -C "$export_dir" . || { warning "Failed to create archive $HOME/$archive_name"; return 1; }
        success "Created archive: $HOME/$archive_name"
        echo "Transfer this file to your new laptop"
    fi
}

# Function to import WiFi credentials
import-wifi-credentials() {
    if [[ "$OSTYPE" != darwin* ]]; then
        error "import-wifi-credentials is only supported on macOS"
        return 1
    fi
    local import_dir="${1:-$HOME/wifi-credentials-export}"
    
    if [[ ! -d "$import_dir" ]]; then
        error "Import directory not found: $import_dir"
        echo "Please specify the directory containing the WiFi export"
        return 1
    fi
    
    if [[ ! -f "$import_dir/import-wifi.sh" ]]; then
        error "Import script not found in $import_dir"
        return 1
    fi
    
    progress "Starting WiFi import..."
    pushd "$import_dir" || { error "Failed to cd into $import_dir"; return 1; }
    ./import-wifi.sh
    popd
}

# Function to list current WiFi networks
list-wifi-networks() {
    if [[ "$OSTYPE" != darwin* ]]; then
        error "list-wifi-networks is only supported on macOS"
        return 1
    fi
    progress "Current WiFi networks:"
    
    # Find WiFi interface
    local wifi_interface
    wifi_interface=$(networksetup -listallhardwareports | awk '/Wi-Fi|Airport/{getline; print $2}')
    
    if [[ -z "$wifi_interface" ]]; then
        error "Could not find WiFi interface"
        return 1
    fi
    
    echo "Interface: $wifi_interface"
    echo ""
    
    networksetup -listpreferredwirelessnetworks "$wifi_interface"
}

_verify_check() {
    local name="$1"
    shift

    (( _verify_checks_total++ ))

    if "$@" >/dev/null 2>&1; then
        success "$name"
        (( _verify_checks_passed++ ))
    else
        error "$name"
    fi
}

# Function to verify migration
verify-migration() {
    echo "${BLUE}Verifying migration setup...${NC}"
    echo ""
    
    local _verify_checks_passed=0
    local _verify_checks_total=0
    
    _check_docker() { command_exists docker || command_exists podman; }
    _check_ssh_key() { [[ -f ~/.ssh/id_ed25519 ]] || [[ -f ~/.ssh/id_rsa ]]; }
    _check_dotfiles() { [[ -f ~/.zshrc ]] && grep -q 'dotfiles' ~/.zshrc; }

    # Run checks
    _verify_check "Homebrew" command_exists brew
    _verify_check "Git" command_exists git
    _verify_check "GitHub CLI" command_exists gh
    _verify_check "Docker/Podman" _check_docker
    _verify_check "OpenShift CLI" command_exists oc
    _verify_check "VS Code" command_exists code
    _verify_check "GPG" command_exists gpg
    _verify_check "SSH directory" test -d "$HOME/.ssh"
    _verify_check "SSH key exists" _check_ssh_key
    _verify_check "Dotfiles linked" _check_dotfiles
    _verify_check "Secrets file" test -f "$HOME/secrets.zsh"
    _verify_check "Go installed" command_exists go
    _verify_check "Node installed" command_exists node
    _verify_check "Python installed" command_exists python3
    
    echo ""
    echo "Checks passed: $_verify_checks_passed/$_verify_checks_total"
    
    if [[ $_verify_checks_passed -eq $_verify_checks_total ]]; then
        echo "${GREEN}All checks passed! ✨${NC}"
    else
        echo "${YELLOW}Some checks failed. Review the output above.${NC}"
    fi
}

# Function to backup current laptop before migration
backup-before-migration() {
    local backup_dir="$HOME/laptop-migration-backup-$(date +%Y%m%d-%H%M%S)"
    
    progress "Creating backup at $backup_dir..."
    mkdir -p "$backup_dir" || { error "Failed to create backup directory $backup_dir"; return 1; }
    
    # Backup important files
    local backup_items=(
        ~/.ssh
        ~/.gnupg
        ~/secrets.zsh
        ~/.gitconfig
        ~/.aws
        ~/.config
        ~/Documents
        ~/Desktop
    )
    local item
    for item in "${backup_items[@]}"; do
        if [[ -e "$item" ]]; then
            progress "Backing up $item..."
            cp -R "$item" "$backup_dir/" || warning "Failed to backup $item"
        fi
    done
    
    # Export WiFi credentials
    progress "Exporting WiFi credentials..."
    export-wifi-credentials "$backup_dir/wifi-credentials"
    
    # Create a manifest
    cat > "$backup_dir/MANIFEST.txt" << EOF
Laptop Migration Backup
Created: $(date)
Machine: $(hostname)
User: $(whoami)

Contents:
$(ls -la "$backup_dir")
EOF
    
    success "Backup completed at $backup_dir"
    echo "Compress with: tar -czf laptop-backup.tar.gz -C $HOME ${backup_dir:t}"
}

# Function to update Brewfile from current system
update-brewfile() {
    if ! command -v brew &>/dev/null; then
        error "brew not found. Install Homebrew: https://brew.sh"
        return 1
    fi
    progress "Updating Brewfile from current system..."
    
    if [[ ! -f ~/git/dotfiles/Brewfile ]]; then
        warning "Creating new Brewfile..."
    else
        # Backup existing Brewfile
        cp ~/git/dotfiles/Brewfile ~/git/dotfiles/Brewfile.backup || { error "Failed to backup Brewfile"; return 1; }
        success "Backed up existing Brewfile"
    fi
    
    # Generate new Brewfile
    brew bundle dump --force --file=~/git/dotfiles/Brewfile || { error "Failed to generate Brewfile"; return 1; }
    success "Generated Brewfile from current system"
    
    # Show what changed
    if [[ -f ~/git/dotfiles/Brewfile.backup ]]; then
        progress "Changes made:"
        diff ~/git/dotfiles/Brewfile.backup ~/git/dotfiles/Brewfile || true
        rm ~/git/dotfiles/Brewfile.backup
    fi
    
    echo ""
    echo "Review changes with: cd ~/git/dotfiles && git diff Brewfile"
    echo "Commit with: git add Brewfile && git commit -m 'Update Brewfile'"
}

# Function to clean up packages not in Brewfile
brewfile-cleanup() {
    if ! command -v brew &>/dev/null; then
        error "brew not found. Install Homebrew: https://brew.sh"
        return 1
    fi
    progress "Checking for packages not in Brewfile..."
    
    if [[ ! -f ~/git/dotfiles/Brewfile ]]; then
        error "No Brewfile found at ~/git/dotfiles/Brewfile"
        return 1
    fi
    
    echo ""
    echo "The following would be removed:"
    brew bundle cleanup --file=~/git/dotfiles/Brewfile || warning "Failed to list cleanup candidates"
    
    echo ""
    local do_cleanup
    read -r "do_cleanup?Remove these packages? (y/n): "
    
    if [[ "$do_cleanup" == "y" ]]; then
        brew bundle cleanup --file=~/git/dotfiles/Brewfile --force || { error "Cleanup failed"; return 1; }
        success "Cleanup completed"
    else
        echo "Cleanup cancelled"
    fi
}