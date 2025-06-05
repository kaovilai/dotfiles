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

#### WiFi Networks
Export and import your saved WiFi networks (passwords must be entered manually):

```bash
# On OLD laptop - export WiFi networks
source ~/git/dotfiles/zsh/functions/migrate-laptop.zsh
export-wifi-credentials
# This creates ~/wifi-credentials-export directory

# Transfer the wifi-credentials-export directory to new laptop
# Method 1: AirDrop
#   - Select the wifi-credentials-export folder in Finder
#   - Right-click and choose "Share" > "AirDrop"
#   - Select your new laptop from the AirDrop window
#
# Method 2: File Sharing
#   - On OLD laptop: System Settings > General > Sharing > File Sharing
#   - Enable File Sharing and note the computer name/IP
#   - On NEW laptop: Finder > Go > Connect to Server
#   - Enter: smb://[old-laptop-name].local or smb://[IP-address]
#   - Navigate to and copy the wifi-credentials-export folder
#
# Method 3: USB Drive
#   - Copy wifi-credentials-export folder to USB drive
#   - Transfer to new laptop
# On NEW laptop - import WiFi networks
import-wifi-credentials ~/path/to/wifi-credentials-export

# List current WiFi networks
list-wifi-networks
```

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

#### Which ~/Library Directories to Migrate

Here's a guide to which directories under `~/Library` are worth migrating:

**SHOULD MIGRATE (Important):**

- **`~/Library/Application Support/`** - App settings and data
  - Selective migration recommended (see details below)
- **`~/Library/Preferences/`** - App preferences (.plist files)
  - Contains app settings, but many apps recreate these
  - Consider for apps with complex configurations
- **`~/Library/Keychains/`** - Passwords and certificates
  - Usually better to use iCloud Keychain
  - Manual migration is complex and risky
- **`~/Library/Services/`** - Custom macOS services/workflows
  - If you've created custom services
- **`~/Library/Scripts/`** - AppleScripts and Automator workflows
  - If you have custom scripts

**MAYBE MIGRATE (Depends on needs):**

- **`~/Library/Fonts/`** - Custom installed fonts
  - Only if you have non-system fonts
- **`~/Library/ColorSync/Profiles/`** - Custom color profiles
  - For designers/photographers
- **`~/Library/Mail/`** - Local email storage
  - Better to use IMAP/Exchange sync
- **`~/Library/Messages/`** - iMessage history
  - Better to use iCloud Messages

**DON'T MIGRATE (Will be recreated):**

- **`~/Library/Caches/`** - Temporary cache files
- **`~/Library/Logs/`** - Application logs
- **`~/Library/Cookies/`** - Browser cookies
- **`~/Library/Saved Application State/`** - Window positions
- **`~/Library/WebKit/`** - Browser data

#### Application Support Directory

The `~/Library/Application Support` directory contains important app data, settings, and caches. This is often worth migrating for specific apps.

**Important directories to consider migrating:**

```bash
# List what's in Application Support
ls -la ~/Library/Application\ Support/

# Common important directories:
# - Code (VS Code settings if not using sync)
# - JetBrains (IntelliJ, PyCharm, etc.)
# - Slack (workspace data)
# - Discord (settings)
# - iTerm2 (preferences)
# - Spotify (offline cache)
# - Steam (game saves)
```

**Selective migration approach:**

```bash
# On OLD laptop - backup specific app data
cd ~/Library/Application\ Support/

# Example: Backup iTerm2 settings
tar -czf ~/iterm2-backup.tar.gz iTerm2/

# Example: Backup JetBrains IDEs
tar -czf ~/jetbrains-backup.tar.gz JetBrains/

# Transfer files via AirDrop/File Sharing
# On NEW laptop - restore after installing apps
cd ~/Library/Application\ Support/
tar -xzf ~/iterm2-backup.tar.gz
```

**Apps that typically sync their own data:**
- VS Code (with Settings Sync)
- Chrome/Firefox (with account sync)
- 1Password, Bitwarden (via account)
- Obsidian (via vault sync)

#### Library/Containers Directory

The `~/Library/Containers` directory contains sandboxed app data. You generally **don't need** to migrate this unless:

- You have important data in specific apps (e.g., notes, documents)
- You want to preserve app-specific settings not synced via cloud

**Common apps that store data in Containers:**
- Mail.app
- Notes.app
- Safari (extensions data)
- Calendar.app
- Reminders.app

**Migration approach (if needed):**

```bash
# List all container directories on OLD laptop
ls -la ~/Library/Containers/

# For specific apps you want to migrate (example: Notes)
# On OLD laptop
tar -czf notes-backup.tar.gz ~/Library/Containers/com.apple.Notes

# Transfer via AirDrop/File Sharing/USB
# On NEW laptop (after installing the app)
tar -xzf notes-backup.tar.gz -C ~/
```

**Better alternatives:**
- Use iCloud sync for Apple apps
- Export/import data through the app itself
- Most modern apps have cloud sync options

#### Login Items & System Preferences

**Login Items (Apps that start at login):**

```bash
# On OLD laptop - list current login items
osascript -e 'tell application "System Events" to get the name of every login item'

# Document them manually as there's no easy export
# On NEW laptop - add them via:
# System Settings > General > Login Items
```

**Common login items to reconfigure:**
- Backup software (Time Machine, Backblaze, etc.)
- Cloud sync (Dropbox, Google Drive, OneDrive)
- Utilities (Rectangle, Alfred, Bartender)
- Development tools (Docker Desktop)
- Communication apps (Slack, Discord)

**Other System Preferences to reconfigure:**

1. **Keyboard Shortcuts**
   - System Settings > Keyboard > Keyboard Shortcuts
   - Screenshot shortcuts
   - Spotlight search
   - Mission Control

2. **Security & Privacy**
   - FileVault encryption
   - Firewall settings
   - Privacy permissions for apps

3. **Desktop & Dock**
   - Hot corners
   - Dock position and size
   - Mission Control settings

4. **Trackpad/Mouse Settings**
   - Gestures
   - Scrolling direction
   - Tracking speed

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