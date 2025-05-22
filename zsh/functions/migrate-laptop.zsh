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