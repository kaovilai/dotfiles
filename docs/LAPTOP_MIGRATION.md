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

#### T3 Code (threads, settings, pairing data)

`backup-before-migration` already does this step. To run it on its own:

```bash
# On OLD laptop - writes an encrypted archive (prompts for a passphrase)
export-t3-data ~/t3-code.tar.gz.enc

# Transfer the archive privately (AirDrop/USB). It contains server signing
# keys and auth tokens.

# On NEW laptop - install Claude Code and the app, quit the app if it's
# running, then import. Claude Code goes first because T3's Claude providers
# run it (see "Claude provider launchers" below).
curl -fsSL https://claude.ai/install.sh | bash
brew install --cask t3-code
import-t3-data ~/t3-code.tar.gz.enc

# Re-check any time
verify-t3-migration
```

What gets migrated:
- `~/.t3/userdata`: settings, keybindings, themes, providers, `secrets/`, `clerk-tokens.json`, attachments, and the `state*.sqlite` databases, which hold every thread, project, pairing link, and auth session
- `~/.t3/dev`: dev-build state
- `~/Library/Application Support/t3code-v2` and `t3code`: UI storage

The databases are copied with `sqlite3 .backup`, so exporting while T3 Code is running is safe. Every table's row count is recorded at export and compared on import. If any thread is missing, `verify-t3-migration` reports the table and both counts.

Not migrated, because the app rebuilds them: logs, `server-browser`, usage caches, `~/.t3/bin`, `~/.t3/tools`, `~/.t3/caches`, and `~/.t3/worktrees`. Recreate the worktrees from their branches.

After importing:
- Sign in again. The Electron cookies are encrypted with the `t3code Safe Storage` keychain item, which isn't migrated.
- Re-pair any phone or browser that doesn't reconnect.
- If your username or home path changed, re-add projects whose paths no longer exist, or symlink the old path. Do the same for each provider `binaryPath` in `~/.t3/userdata/settings.json`.
- Anything that was already in `~/.t3/userdata` is moved to `userdata.pre-import-<timestamp>`, not deleted.

##### Claude provider launchers

T3 Code's Claude provider instances don't run `claude` directly. Each instance's `binaryPath` in `~/.t3/userdata/settings.json` points at `~/.local/bin/claude-t3-<backend>` (`copilot`, `vertex`, `openai`, or `enmaas`), a symlink to `scripts/claude-provider.zsh` in this repo. The script takes the backend from the link name, reads keys from `~/secrets.zsh`, sets up that backend's gateway or proxy, then starts Claude Code from `~/.local/bin/claude`.

Git doesn't track these links and `export-t3-data` doesn't include them. On the new laptop, after installing Claude Code (above):

```bash
# Create or repoint the links (migrate-to-new-laptop runs this too).
# Run it again whenever the dotfiles checkout moves.
link-claude-t3-launchers

# Each launcher should resolve to this checkout and start Claude Code
verify-claude-t3-launchers
```

`verify-t3-migration` also warns about any enabled provider whose absolute `binaryPath` in `settings.json` doesn't exist, and `verify-migration` counts that as a failed check.

Every backend needs `python3` and `jq` from the Brewfile. Beyond that:
- `enmaas`: `ENMAAS_API_BASE_URL` and `ENMAAS_API_KEY` in `~/secrets.zsh`, and `uv` for the local LiteLLM proxy
- `openai`: `OPENAI_API_KEY` in `~/secrets.zsh`, or the key `codex login --with-api-key` saves to `~/.codex/auth.json`, and `uv`
- `vertex`: `CLOUD_ML_REGION` and `ANTHROPIC_VERTEX_PROJECT_ID` in `~/secrets.zsh`, `gcloud auth application-default login`, and `uv`
- `copilot`: the copilot-api gateway checkout (`git clone -b dev https://github.com/kaovilai/copilot-api ~/git/copilot-api`) and `bun`. Its GitHub login in `~/.local/share/copilot-api` isn't migrated, so sign in again with `bun run --cwd ~/git/copilot-api ./src/main.ts auth`.

##### Copilot-only Linux host (Fedora, WSL2)

`scripts/setup-t3-headless.zsh` also brings over your Claude config: it clones the private `kaovilai/.claude` repo to `~/.config/claude` and links `~/.claude` to it as on the Mac (`gh auth login` first), then installs every plugin `settings.json` enables from its `extraKnownMarketplaces`. `claude plugin marketplace add` rewrites marketplace entries in `settings.json` with this machine's paths, so the script restores that file afterwards; installed plugins are tracked in the gitignored `plugins/*.json`. MCP servers are in `~/.claude.json`, not the repo; re-add them with `claude mcp add`. Hooks reach their scripts through `$HOME`, so the same `settings.json` works on both machines. The script does everything in this section and the headless one below that can run unattended, then runs `verify-t3-headless` and lists what is left (GitHub login without a terminal, shared Wi-Fi, TPM unlock, the Windows-side task, `t3 pair`). Rerun it any time; finished steps are skipped. `--dry-run` shows the commands without running them, `--no-power` skips the laptop power settings, `--no-tailscale` skips Tailscale. With Tailscale it installs the package, starts `tailscaled`, runs `sudo tailscale up` when you're at a terminal, and makes you its operator: `t3 pair --tailscale` runs `tailscale serve` as you, which Linux allows only root or the operator to change. For Tailscale SSH as the way in with the lid shut, also run `sudo tailscale set --ssh`.

```bash
sudo dnf install -y zsh git        # Ubuntu / WSL2: sudo apt install -y zsh git
git clone https://github.com/kaovilai/dotfiles ~/git/dotfiles
zsh ~/git/dotfiles/scripts/setup-t3-headless.zsh
```

The manual steps follow for reference.

A Linux machine, or WSL2 on Windows 11, can serve as another T3 Code environment on Copilot alone, with no EnMaaS, Vertex or `~/secrets.zsh`. Tested on Fedora 44 and on Ubuntu 24.04 with a simulated WSL PATH (both arm64 containers). The wrappers fall back to `sha256sum` and `ss` where macOS has `shasum` and `lsof`.

On WSL2, install a distro first from PowerShell (Fedora, see "Fedora on WSL2" below; or `wsl --install -d Ubuntu-24.04`) and run everything below inside it. Keep both checkouts in the Linux filesystem (`~/git`), not under `/mnt/c`: the Windows drive is slow and Windows git checks files out with CRLF line endings. `link-claude-t3-launchers` warns about either, and about a tool on PATH that resolves to a Windows program under `/mnt/c`.

```bash
sudo dnf install zsh git jq curl python3                 # Fedora
sudo apt install zsh git jq curl python3 unzip iproute2  # Ubuntu / WSL2 (unzip: bun's installer)
git clone https://github.com/kaovilai/dotfiles ~/git/dotfiles
curl -fsSL https://claude.ai/install.sh | bash
# Before the symlink: bun's installer appends its PATH lines to ~/.zshrc
# unconditionally, and this repo's .zshrc already carries them.
curl -fsSL https://bun.sh/install | bash
ln -sf ~/git/dotfiles/.zshrc ~/.zshrc
chsh -s "$(command -v zsh)" && exec zsh
git clone -b dev https://github.com/kaovilai/copilot-api ~/git/copilot-api
bun run --cwd ~/git/copilot-api ./src/main.ts auth   # GitHub device login

link-claude-t3-launchers copilot     # only claude-t3-copilot
verify-claude-t3-launchers copilot
claude-t3-copilot --prepare          # starts the gateway on :4141, prints the tiers
```

In T3 Code, add a Claude provider instance whose `binaryPath` is `/home/<user>/.local/bin/claude-t3-copilot`. With the desktop app on Windows that's its WSL backend, so the path is the Linux one; a headless box runs the T3 server itself, below.

##### EnMaaS on a Linux host (--enmaas)

EnMaaS works from a personal machine: the gateway (`api.enmaas.devshift.net`) is public and access comes from your API key, which you request or revoke in Atlas key management (VPN needed for that step only). Not approved in Works Council countries. `setup-t3-headless.zsh --enmaas` adds:

- `lsof`, `uv`, `shasum` (`perl-Digest-SHA`) and `ps` (`procps-ng`); on Ubuntu `lsof perl procps` plus uv from astral's installer. The EnMaaS proxy code calls `lsof`, `shasum` and `ps` directly.
- The Codex CLI (`npm i -g --prefix ~/.local @openai/codex`).
- `ENMAAS_API_BASE_URL` / `ENMAAS_API_KEY` in `~/secrets.zsh` (mode 600): asked for with hidden input when you run it from a terminal. `~/secrets.zsh` is not synced; the rest of yours stays on the Mac.
- A one-time download of the pinned LiteLLM. On a cold uv cache the first proxy boot spends its whole startup timeout downloading and fails.
- `claude-t3-{enmaas,hosted-only}` and `codex-t3-{enmaas,hosted-only}`, then `--prepare` of both Claude backends to prove the key works.

T3 provider instances come from the Mac: `export-t3-providers` there writes every launcher-backed instance (model pins, Codex launch arguments, env) to `t3/provider-instances.json`, home directory as `@HOME@`, values marked sensitive left out. Commit it; `setup-t3-headless.zsh` and `fleet-sync` run `import-t3-providers`, which adds instances whose launcher is linked on that machine and updates ones nobody changed locally since the last import.

Tested on Fedora 44: real prompts through all four launchers. The default models (Codex's `gpt-*` default, Claude's main tier) can be ones your key is not entitled to, on the Mac too; T3 threads pick the model from the instance's list.

##### Keeping machines in sync (fleet-sync)

The dotfiles, Claude config (`~/.config/claude`) and copilot-api checkouts are git repos, so the fleet stays in step by editing on one machine, pushing, and letting the others fast-forward. `fleet-sync` (`scripts/fleet-sync.zsh`) does the fast-forward and applies what changed:

- A changed Claude config installs newly enabled plugins (`sync-claude-plugins`). Once a day it also refreshes marketplaces and updates plugins.
- A changed copilot-api reinstalls dependencies when `bun.lock` changed and stops the gateway if it is idle, so the next session runs the new code.
- It never commits, merges or discards. A repo with uncommitted changes, unpushed commits or a diverged branch is skipped with a warning; fix it by hand (commit and push, or `git pull` with your merge of choice).

```bash
fleet-sync --dry-run      # fetch and report what would move
fleet-sync                # fast-forward + apply
fleet-sync --update-plugins
fleet-sync --install-timer   # Linux: hourly systemd user timer (setup-t3-headless.zsh installs it)
journalctl --user -u fleet-sync
```

The timer runs with nobody logged in, so `gh` must keep its token outside the desktop keyring for the private config repo: `setup-t3-headless.zsh` logs in with `gh auth login --insecure-storage` (token in `~/.config/gh/hosts.yml`, mode 600). Not synced, on purpose: MCP servers (`~/.claude.json`), T3 settings and every login.

##### Headless host (Fedora or WSL2)

For a machine nobody sits at, run the T3 server as a background service and reach it from the phone, instead of running the desktop app. `t3 service install` writes a systemd user unit (`t3code.service`, restarts on failure) and enables lingering, so it starts at boot with nobody logged in. Tested with `t3` 0.1.3: `t3 serve` started with only the unit's environment (no shell rc files, systemd's default PATH) ran a Copilot thread through `claude-t3-copilot`. `t3 service install` itself is untested here (the test containers can't run systemd).

```bash
sudo dnf install nodejs npm libatomic          # Fedora
# Ubuntu / WSL2: apt's nodejs is too old (24.04 ships 18; t3 needs >= 20.11), so use NodeSource's
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash - && sudo apt install nodejs libatomic1
# t3's downloaded runtime links libatomic; without it: "libatomic.so.1: cannot open shared object file"
npm i -g --prefix ~/.local t3@latest
mkdir -p ~/.t3/userdata   # then add the provider instance below, or from a paired client
t3 service install
t3 pair                   # QR code for the phone; --tailscale to pair over the tailnet
verify-t3-headless        # systemd, lingering, t3code.service, claude-t3-copilot
```

Provider instance in `~/.t3/userdata/settings.json` (merge into an existing file):

```json
{"providerInstances": {"claude_copilot": {"driver": "claudeAgent", "displayName": "Claude · Copilot", "enabled": true,
  "environment": [], "config": {"binaryPath": "/home/<user>/.local/bin/claude-t3-copilot", "customModels": []}}}}
```

The copilot-api gateway the launcher starts lives in the service's cgroup, so `t3 service restart` and `t3 update` stop it too; the next session starts it again.

**WSL2, Windows side (untested).** WSL only runs while something holds the distro open, and only for a signed-in user unless a task starts it.

1. Enable systemd in the distro, then restart WSL from PowerShell with `wsl --shutdown`:
   ```ini
   # /etc/wsl.conf
   [boot]
   systemd=true
   ```
2. Start the distro at boot and keep it running, from an elevated PowerShell. "Run whether user is logged on or not" needs the account password (a Microsoft account's password, not the PIN):
   ```powershell
   # -d: your distro's name from `wsl --list` (FedoraLinux-NN, Ubuntu-24.04, ...)
   $a = New-ScheduledTaskAction -Execute 'wsl.exe' -Argument '-d FedoraLinux-NN --exec /bin/sleep infinity'
   $t = New-ScheduledTaskTrigger -AtStartup
   $s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
   Register-ScheduledTask -TaskName 'WSL keepalive' -Action $a -Trigger $t -Settings $s -User $env:USERNAME -Password (Read-Host 'Windows password')
   ```
   Systemd in the distro then starts `t3code.service` through lingering.
3. Stop the machine sleeping on AC power: `powercfg /change standby-timeout-ac 0` and `powercfg /change hibernate-timeout-ac 0`.
4. For maintenance without a screen, enable Windows' OpenSSH server (then `wsl` from the SSH session) or run Tailscale with SSH inside the distro.

After a reboot, check from inside the distro with `verify-t3-headless`.

**Fedora on WSL2 (the distro to pick).** Same package manager and versions as a Fedora laptop, so one setup path for the fleet: Fedora's repos carry a current Node, `uv` and podman, where Ubuntu 24.04 needs NodeSource and astral's installer. The setup script handles both; neither has run on real WSL yet (Fedora 44 was tested in a container, Ubuntu 24.04 in a container with a simulated WSL PATH).

```powershell
wsl --list --online              # pick the newest FedoraLinux-NN
wsl --install FedoraLinux-NN     # asks for a Linux user and password
```

Inside the distro:

```bash
sudo dnf install -y zsh git
git clone https://github.com/kaovilai/dotfiles ~/git/dotfiles   # ext4, not /mnt/c
zsh ~/git/dotfiles/scripts/setup-t3-headless.zsh --enmaas       # first run: systemd in /etc/wsl.conf
# PowerShell: wsl --shutdown, reopen the distro, then rerun the same command to finish
```

Then the Windows side above, with the Fedora name in the keepalive task. Notes for this host:

- Run T3 only as the distro's `t3code.service`, reached through Tailscale inside the distro. Don't also point the Windows T3 Code desktop app at a WSL backend: that path (desktop starting and authenticating the backend) has open startup, token and port 3773 bugs in pingdotgg/t3code.
- WSL caps the VM at half of Windows' RAM. For kind, agents and Go builds together, raise it in `%UserProfile%\.wslconfig`, then `wsl --shutdown`:
  ```ini
  [wsl2]
  memory=24GB   # size to the machine
  swap=8GB
  ```
- Containers: podman or docker-ce inside the distro, not Docker Desktop's WSL integration. Rootless podman under kind needs cgroup v2 (`stat -fc %T /sys/fs/cgroup` prints `cgroup2fs`). kind's recommended inotify limits, for this host and the laptop alike:
  ```bash
  printf 'fs.inotify.max_user_watches=524288\nfs.inotify.max_user_instances=512\n' |
      sudo tee /etc/sysctl.d/99-kind-inotify.conf && sudo sysctl --system
  ```
- No sshd is set up here (the laptop step skips WSL). To send the EnMaaS key from the Mac instead of pasting it at the prompt, run `sudo tailscale set --ssh` in the distro and pipe the two `export` lines over ssh into `~/secrets.zsh` (mode 600).

**Lid-closed Fedora laptop.** Plugged in with the lid shut and nobody logged in, a stock Fedora Workstation suspends on lid close, suspends again after a while idle at the login screen, and after a reboot can sit at the disk passphrase or come up without Wi-Fi. On a machine with a battery, `verify-t3-headless` checks each of these. The settings below are untested here (the test containers have no logind, GDM or TPM).

```bash
# Lid closed on AC: do nothing (on battery it still suspends). Applies after a reboot.
sudo mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore\n' |
    sudo tee /etc/systemd/logind.conf.d/90-t3-lid.conf

# No idle suspend on AC at the login screen (what runs with nobody logged in),
# and in your own session for when you do log in
sudo mkdir -p /etc/dconf/db/gdm.d
printf "[org/gnome/settings-daemon/plugins/power]\nsleep-inactive-ac-type='nothing'\n" |
    sudo tee /etc/dconf/db/gdm.d/95-t3-no-suspend
sudo dconf update
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
# Or never suspend at all, also on battery (undo: systemctl unmask):
#   sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# Wi-Fi up before anyone logs in: shared with all users, password stored system-wide
sudo nmcli connection modify '<SSID>' connection.permissions '' \
    802-11-wireless-security.psk-flags 0 802-11-wireless-security.psk '<password>'

# Encrypted disk only (lsblk -f shows crypto_LUKS): unlock with the TPM at boot.
# Add tpm2-device=auto to that volume's options in /etc/crypttab, then rebuild the initramfs.
sudo systemd-cryptenroll --tpm2-device=auto /dev/<luks-partition>
sudo dracut -f

sudo systemctl enable --now sshd   # a way in with the lid shut
```

If the firmware supports it, also limit charging to protect a battery that never leaves AC (GNOME Settings → Power), and set the BIOS to power on when AC returns so an outage doesn't leave it off.

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
# Or use Google Vertex AI instead (preferred when set):
# export CLOUD_ML_REGION="us-east5"
# export ANTHROPIC_VERTEX_PROJECT_ID="your-project-id"
# Claude provider launchers T3 Code runs (see "Claude provider launchers")
export ENMAAS_API_BASE_URL="https://your-gateway"
export ENMAAS_API_KEY="your-key"
# export OPENAI_API_KEY="your-key"   # optional; falls back to ~/.codex/auth.json
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
- [ ] T3 Code threads and pairings restored: `verify-t3-migration`
- [ ] T3 Code's Claude launchers start: `verify-claude-t3-launchers`

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