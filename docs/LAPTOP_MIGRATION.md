# Laptop Migration Guide

This guide helps you migrate your development environment to a new macOS laptop.

## Prerequisites

Before starting migration on the **OLD** laptop:
1. Ensure all dotfiles changes are committed and pushed
2. Back up any local secrets/credentials
3. Note any machine-specific configurations

## Migration Steps

### 1. Initial Setup on NEW Laptop

```bash
# Install Xcode Command Line Tools
xcode-select --install

# Install Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Add Homebrew to PATH (Apple Silicon)
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"

# Clone dotfiles
mkdir -p ~/git
git clone git@github.com:kaovilai/dotfiles.git ~/git/dotfiles

# Or if SSH isn't set up yet:
git clone https://github.com/kaovilai/dotfiles.git ~/git/dotfiles
```

### 2. Run Migration Script

```bash
# Source the migration function
source ~/git/dotfiles/zsh/functions/migrate-laptop.zsh

# Run migration
migrate-to-new-laptop
```

### 2a. Alternative: Use Brewfile for Complete Package Installation

Instead of or after running the migration script, you can use the Brewfile to install all packages at once:

```bash
# Install all packages from Brewfile
brew bundle --file=~/git/dotfiles/Brewfile

# Or if you're in the dotfiles directory
cd ~/git/dotfiles
brew bundle

# To check what would be installed without installing
brew bundle check --file=~/git/dotfiles/Brewfile

# To generate a Brewfile from your current system (on OLD laptop)
brew bundle dump --file=~/my-current-brewfile
```

The Brewfile includes:
- CLI tools (git, ripgrep, kubectl, etc.)
- Development languages (go, node, python, rust)
- Container tools (docker, podman, kind)
- GUI applications (VS Code, iTerm2, browsers)
- Fonts for development

**Note:** Some cask applications may require additional setup after installation.

### 3. Manual Steps

#### SSH Keys
- Copy `~/.ssh` from old laptop or generate new keys
- Add new SSH key to GitHub: https://github.com/settings/keys
- Update any other services with new SSH keys

#### GPG Keys
```bash
# On OLD laptop - export keys
gpg --export-secret-keys your-email@example.com > private-keys.asc
gpg --export your-email@example.com > public-keys.asc

# On NEW laptop - import keys
gpg --import private-keys.asc
gpg --import public-keys.asc

# Trust the key
gpg --edit-key your-email@example.com
# Type: trust, 5, y, quit
```

#### Application-Specific Configs

1. **VS Code**
   - Sign in to sync settings
   - Or manually copy `~/Library/Application Support/Code/User/settings.json`

2. **Docker Desktop**
   - Install from https://www.docker.com/products/docker-desktop
   - Configure resources in preferences

3. **Cloud CLIs**
   - AWS: `aws configure`
   - Google Cloud: `gcloud auth login`
   - IBM Cloud: `ibmcloud login`

#### Secrets File
Create `~/secrets.zsh` with your environment-specific variables:
```bash
# Example structure (DO NOT commit actual values)
export GITHUB_TOKEN="your-token"
export ANTHROPIC_API_KEY="your-key"
export TF_NETWORK_NAME="your-network"
export TAILSCALE_API_KEY="your-key"
export TAILSCALE_TAILNET="your-tailnet"
```

### 4. Verification Checklist

- [ ] Shell (zsh) is properly configured
- [ ] Git commits are signed (test with `git commit -S`)
- [ ] AWS CLI works: `aws s3 ls`
- [ ] Docker/Podman works: `docker ps`
- [ ] OpenShift CLI works: `oc version`
- [ ] VS Code opens with correct settings
- [ ] Homebrew packages are installed
- [ ] GPG signing works
- [ ] SSH connections work

### 5. Cleanup

On OLD laptop (after verification):
- Revoke old SSH keys from services
- Deauthorize old machine from cloud services
- Consider secure wipe if selling/returning

## Troubleshooting

### SSH Issues
```bash
# Fix permissions
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_*
chmod 644 ~/.ssh/*.pub
```

### GPG Issues
```bash
# Check GPG is working
gpg --list-keys

# Fix GPG for git signing
git config --global gpg.program $(which gpg)
```

### Homebrew Issues (Apple Silicon)
```bash
# Ensure correct PATH
echo $PATH | grep -q "/opt/homebrew" || echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
```

## Machine-Specific Configurations

Edit `~/secrets.zsh` to include machine-specific settings:
```bash
# Machine identifier
export MACHINE_NAME="$(hostname -s)"

# Machine-specific paths or configs
case "$MACHINE_NAME" in
  "work-laptop")
    export SPECIFIC_CONFIG="work-value"
    ;;
  "personal-laptop")
    export SPECIFIC_CONFIG="personal-value"
    ;;
esac
```

## Maintaining Your Brewfile

### Keeping Brewfile Updated

On your current laptop, periodically update the Brewfile:

```bash
# Generate current system's Brewfile
brew bundle dump --force --file=~/git/dotfiles/Brewfile

# Review changes
cd ~/git/dotfiles
git diff Brewfile

# Commit if changes look good
git add Brewfile
git commit -m "Update Brewfile with current packages"
```

### Cleanup Unused Packages

```bash
# Remove packages not in Brewfile
brew bundle cleanup --file=~/git/dotfiles/Brewfile

# See what would be removed without removing
brew bundle cleanup --file=~/git/dotfiles/Brewfile --force
```

### Brewfile Best Practices

1. **Comment your additions** - Add comments explaining why packages are needed
2. **Group related packages** - Keep the file organized by category
3. **Version pin sparingly** - Only pin versions when absolutely necessary
4. **Test on new machine** - Verify Brewfile works on clean installs
5. **Keep it in git** - Always commit Brewfile changes