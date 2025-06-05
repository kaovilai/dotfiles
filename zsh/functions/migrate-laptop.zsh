#!/usr/bin/env zsh

# Laptop Migration Functions
# Automates the process of setting up a new macOS laptop with your dotfiles

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
    echo "${YELLOW}⚠${NC} $1"
}

# Error indicator
error() {
    echo "${RED}✗${NC} $1"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to manually install packages (fallback when no Brewfile)
install_packages_manually() {
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
    
    for tool in "${essential_tools[@]}"; do
        if brew list "$tool" &>/dev/null; then
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
        if brew list "$tool" &>/dev/null; then
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
        progress "Found Brewfile. Installing all packages..."
        read -p "Install all packages from Brewfile? (y/n): " use_brewfile
        
        if [[ "$use_brewfile" == "y" ]]; then
            cd ~/git/dotfiles
            brew bundle || warning "Some packages failed to install"
            success "Packages installed from Brewfile"
        else
            # Fallback to manual installation
            install_packages_manually
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
    
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
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
    read -p "Enter your Git email: " git_email
    read -p "Enter your Git name: " git_name
    
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
        read -p "Generate new SSH key? (y/n): " generate_ssh
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
    local export_dir="${1:-$HOME/wifi-credentials-export}"
    
    progress "Exporting WiFi credentials..."
    
    # Create export directory
    mkdir -p "$export_dir"
    chmod 700 "$export_dir"
    
    # Export WiFi profiles
    local wifi_file="$export_dir/wifi-networks.xml"
    
    # Get list of WiFi networks
    progress "Finding saved WiFi networks..."
    local networks=$(networksetup -listpreferredwirelessnetworks en0 2>/dev/null | tail -n +2 | sed 's/^[[:space:]]*//')
    
    if [[ -z "$networks" ]]; then
        # Try en1 if en0 didn't work
        networks=$(networksetup -listpreferredwirelessnetworks en1 2>/dev/null | tail -n +2 | sed 's/^[[:space:]]*//')
    fi
    
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
    echo "$networks" | while IFS= read -r network; do
        if [[ -n "$network" ]]; then
            echo "  Exporting: $network"
            cat >> "$wifi_file" << EOF
        <dict>
            <key>SSID</key>
            <string>$network</string>
        </dict>
EOF
        fi
    done
    
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
        read -p "Add this network? (y/n): " add_network
        
        if [[ "$add_network" == "y" ]]; then
            # Prompt for password
            echo "Enter the password for '$network' (or press Enter to skip):"
            read -s password
            echo ""
            
            if [[ -n "$password" ]]; then
                # Add the network
                networksetup -addpreferredwirelessnetworkatindex "$wifi_interface" "$network" 0 WPA2 "$password"
                if [[ $? -eq 0 ]]; then
                    echo "✓ Added $network"
                else
                    echo "✗ Failed to add $network"
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
    echo "Found $(echo "$networks" | wc -l | tr -d ' ') networks"
    echo ""
    echo "${YELLOW}Next steps:${NC}"
    echo "1. Copy $export_dir to your new laptop"
    echo "2. Run the import script on the new laptop"
    echo "3. Have your WiFi passwords ready"
    
    # Offer to create a compressed archive
    echo ""
    read -p "Create compressed archive? (y/n): " create_archive
    if [[ "$create_archive" == "y" ]]; then
        local archive_name="wifi-export-$(date +%Y%m%d-%H%M%S).tar.gz"
        tar -czf "$HOME/$archive_name" -C "$export_dir" .
        success "Created archive: $HOME/$archive_name"
        echo "Transfer this file to your new laptop"
    fi
}

# Function to import WiFi credentials
import-wifi-credentials() {
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
    cd "$import_dir"
    ./import-wifi.sh
}

# Function to list current WiFi networks
list-wifi-networks() {
    progress "Current WiFi networks:"
    
    # Find WiFi interface
    local wifi_interface=$(networksetup -listallhardwareports | awk '/Wi-Fi|Airport/{getline; print $2}')
    
    if [[ -z "$wifi_interface" ]]; then
        error "Could not find WiFi interface"
        return 1
    fi
    
    echo "Interface: $wifi_interface"
    echo ""
    
    networksetup -listpreferredwirelessnetworks "$wifi_interface"
}

# Function to verify migration
verify-migration() {
    echo "${BLUE}Verifying migration setup...${NC}"
    echo ""
    
    local checks_passed=0
    local checks_total=0
    
    # Check function
    check() {
        local name="$1"
        local command="$2"
        ((checks_total++))
        
        if eval "$command" >/dev/null 2>&1; then
            success "$name"
            ((checks_passed++))
        else
            error "$name"
        fi
    }
    
    # Run checks
    check "Homebrew" "command_exists brew"
    check "Git" "command_exists git"
    check "GitHub CLI" "command_exists gh"
    check "Docker/Podman" "command_exists docker || command_exists podman"
    check "OpenShift CLI" "command_exists oc"
    check "VS Code" "command_exists code"
    check "GPG" "command_exists gpg"
    check "SSH directory" "[[ -d ~/.ssh ]]"
    check "SSH key exists" "[[ -f ~/.ssh/id_ed25519 ]] || [[ -f ~/.ssh/id_rsa ]]"
    check "Dotfiles linked" "[[ -f ~/.zshrc ]] && grep -q 'dotfiles' ~/.zshrc"
    check "Secrets file" "[[ -f ~/secrets.zsh ]]"
    check "Go installed" "command_exists go"
    check "Node installed" "command_exists node"
    check "Python installed" "command_exists python3"
    
    echo ""
    echo "Checks passed: $checks_passed/$checks_total"
    
    if [[ $checks_passed -eq $checks_total ]]; then
        echo "${GREEN}All checks passed! ✨${NC}"
    else
        echo "${YELLOW}Some checks failed. Review the output above.${NC}"
    fi
}

# Function to backup current laptop before migration
backup-before-migration() {
    local backup_dir="$HOME/laptop-migration-backup-$(date +%Y%m%d-%H%M%S)"
    
    progress "Creating backup at $backup_dir..."
    mkdir -p "$backup_dir"
    
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
    echo "Compress with: tar -czf laptop-backup.tar.gz -C $HOME $(basename $backup_dir)"
}

# Function to update Brewfile from current system
update-brewfile() {
    progress "Updating Brewfile from current system..."
    
    if [[ ! -f ~/git/dotfiles/Brewfile ]]; then
        warning "Creating new Brewfile..."
    else
        # Backup existing Brewfile
        cp ~/git/dotfiles/Brewfile ~/git/dotfiles/Brewfile.backup
        success "Backed up existing Brewfile"
    fi
    
    # Generate new Brewfile
    brew bundle dump --force --file=~/git/dotfiles/Brewfile
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
    progress "Checking for packages not in Brewfile..."
    
    if [[ ! -f ~/git/dotfiles/Brewfile ]]; then
        error "No Brewfile found at ~/git/dotfiles/Brewfile"
        return 1
    fi
    
    echo ""
    echo "The following would be removed:"
    brew bundle cleanup --file=~/git/dotfiles/Brewfile
    
    echo ""
    read -p "Remove these packages? (y/n): " do_cleanup
    
    if [[ "$do_cleanup" == "y" ]]; then
        brew bundle cleanup --file=~/git/dotfiles/Brewfile --force
        success "Cleanup completed"
    else
        echo "Cleanup cancelled"
    fi
}