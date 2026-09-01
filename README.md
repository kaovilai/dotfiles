# Dotfiles

A collection of shell configuration files and utilities for a productive development environment.

## Structure

- **zsh/**: ZSH shell configuration files
  - **aliases/**: Organized aliases by category
    - **docker.zsh**: Docker-related aliases
    - **git.zsh**: Git command shortcuts
    - **github.zsh**: GitHub CLI commands
    - **code.zsh**: VSCode related aliases
    - **ibmcloud.zsh**: IBM Cloud commands
    - **velero.zsh**: Velero-specific commands
    - **misc.zsh**: Miscellaneous aliases
  - **alias.zsh**: Main alias loader
  - **colors.zsh**: Color definitions
  - **completions.zsh**: Command completion configuration
  - **paths.zsh**: PATH environment variable configuration
  - **util.zsh**: Utility functions
  - **znap.zsh**: ZSH Snap plugin manager configuration
  - Other tool-specific configuration files

## Usage

The main entry point is `.zshrc` which sources all the necessary files.

### Key Commands

- `copy-to-dotfiles-from-zshrc`: Copy your local .zshrc to the dotfiles repo
- `push-dotfiles-from-zshrc`: Push changes to the dotfiles repository
- `update-zshrc-from-dotfiles`: Update your local .zshrc from the dotfiles repo

### Migration Commands

- `migrate-to-new-laptop`: Set up a new laptop with your development environment
- `export-wifi-credentials`: Export WiFi network names for migration
- `import-wifi-credentials`: Import WiFi networks on new laptop
- `list-wifi-networks`: List currently saved WiFi networks

## Features

- Organized aliases by category for better maintainability
- Efficient completion file caching
- Optimized utility functions
- Znap plugin manager for fast shell startup
- Comprehensive Git and GitHub workflow aliases
- Docker and container management shortcuts
- Cloud platform integrations (IBM Cloud, AWS, etc.)

## Adding New Aliases

See `zsh/aliases/README.md` for instructions on adding new aliases to the appropriate category.

## Dependencies

This dotfiles repository relies on several tools and utilities. Below is a list of all dependencies and how to install them using Homebrew:

### Core Shell Tools

```bash
# Install ZSH (may already be installed on macOS)
brew install zsh

# Install required utilities for the shell
brew install coreutils
```

### Plugin Manager & Plugins

```bash
# ZSH Snap (znap) will be automatically installed when you source the dotfiles
# The following plugins are managed by znap and will be installed automatically:
# - sindresorhus/pure (prompt)
# - zsh-users/zsh-syntax-highlighting
# - marlonrichert/zsh-autocomplete
```

### Version Control Tools

```bash
# Git and GitHub related tools
brew install git
brew install gh
brew install jq  # Used in GitHub workflow aliases

# OpenCommit for AI-powered Git commits
npm install -g opencommit
```

### Development & Container Tools

```bash
# Container tools
brew install podman
brew install docker  # or download Docker Desktop
brew install colima  # macOS container runtime alternative

# Docker buildx for multi-architecture builds
# (included with Docker Desktop or Docker CE >= 19.03)

# Code editors
brew install --cask visual-studio-code

# Local AI
brew install ollama

# YAML processing
brew install yq

# JSON processing 
brew install jq

# Go programming language
brew install go
```

### Cloud & Kubernetes Tools

```bash
# Kubernetes and related tools
brew install kubernetes-cli  # kubectl
brew install kind
brew install krew  # kubectl plugin manager

# Cloud provider CLIs
brew install awscli
brew install google-cloud-sdk
brew install velero
brew install ibmcloud-cli

# OpenShift tools (alternative installation methods provided in functions)
# OpenShift CLI
brew install openshift-cli   # Or use the provided function: install-oc

# For OpenShift development
# install-ocp-installer  # Function provided in the repo
# For cloud credential operator
# install-ccoctl        # Function provided in the repo
```

### Utility Tools

```bash
# General utilities
brew install gnu-sed
brew install socat
brew install spoof-mac
brew install lsof
brew install coreutils

# macOS specific
brew install --cask displaylink  # For external display support
```

### Browser

```bash
# Microsoft Edge
brew install --cask microsoft-edge
```

### Optional Tools

```bash
# Additional tools referenced in aliases
brew install --cask github
brew install --cask activepieces
```

## Fedora (dnf) — Brewfile Equivalents

`Brewfile` is macOS/Homebrew-only. On Fedora, install the same tool set via `dnf` (and a few curl-script/pip/go installers where Fedora has no package) instead of running `brew bundle`.

### Essential CLI

```bash
sudo dnf install -y git gh wget curl gnupg2 gpgme bash pinentry
# glab (GitLab CLI): no Fedora repo package -- download binary from
# https://gitlab.com/gitlab-org/cli/-/releases
```

### Shell and terminal tools

```bash
# coreutils/sed/grep are already GNU on Fedora -- no gsed/ggrep prefix needed,
# unlike macOS where Homebrew's GNU versions must be g-prefixed.
sudo dnf install -y ripgrep fzf tree htop procps-ng jq lynx parallel mosh
# yq: not in Fedora repos -- pip install yq, or
#   go install github.com/mikefarah/yq/v4@latest
```

### Development tools

```bash
sudo dnf install -y golang nodejs pipx pkgconf
# golangci-lint: curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $(go env GOPATH)/bin
# uv: curl -LsSf https://astral.sh/uv/install.sh | sh
# yarn: npm install -g yarn  (or: sudo dnf install yarnpkg)
# node@18 (specific version pin): use nvm instead of a dnf package
```

### Container and Kubernetes tools

```bash
# Prefer podman over docker on this repo (see CLAUDE.md) -- native on Fedora, no VM needed.
sudo dnf install -y podman kubernetes-client skopeo
# minikube: download binary -- https://minikube.sigs.k8s.io/docs/start/
# lima (Linux VMs on macOS): not needed on Linux, podman is already native
```

### Cloud CLI tools

```bash
# azure-cli: curl -sL https://aka.ms/InstallAzureCLIDeb | bash  (Debian-flavored script; on
#   Fedora, add Microsoft's yum repo per https://learn.microsoft.com/cli/azure/install-azure-cli-linux)
# openshift-cli (oc): no dnf package -- download from mirror.openshift.com,
#   or use this repo's own install-oc function
# rosa-cli, stern: no dnf package -- download binary from each project's GitHub releases
```

### Network tools

```bash
sudo dnf install -y iperf iperf3
# spoof-mac (macOS networksetup wrapper): no Linux equivalent needed --
#   use macchanger (sudo dnf install macchanger) for MAC spoofing on Linux instead
```

### Document and media tools

```bash
sudo dnf install -y ffmpeg poppler-utils ocrmypdf   # ffmpeg needs RPM Fusion enabled
```

### YAML/config tools

```bash
sudo dnf install -y yamllint
# yamlfix: pip install yamlfix
# cfssl: go install github.com/cloudflare/cfssl/cmd/cfssl@latest (and cfssljson alongside it)
```

### AI tools

```bash
# ollama: curl -fsSL https://ollama.com/install.sh | sh
# gptme: pip install gptme
# nvidia/openshell (macOS tap): no Linux equivalent tracked
```

### Misc tools

```bash
# copyparty: pipx install copyparty
# googleworkspace-cli (gws): install per its own repo instructions, no dnf package
# cliclick, switchaudio-osx (macOS automation), container (Apple's runtime, use podman instead): skip on Linux
```

### Security

```bash
# snyk: npm install -g snyk
# trivy: add Aqua Security's dnf repo (https://aquasecurity.github.io/trivy/latest/getting-started/installation/) then: sudo dnf install trivy
```

### Runtime tools

```bash
# bun: curl -fsSL https://bun.sh/install | bash
# socktainer (macOS podman-machine socket manager): not needed -- podman runs natively on Linux
```

### Cask equivalents

```bash
# ghostty: available via Fedora COPR (or check `sudo dnf install ghostty` -- shipped in Fedora repos as of recent releases)
sudo dnf install -y gstreamer1-plugins-base gstreamer1-plugins-good gstreamer1-plugins-bad-free gstreamer1-plugins-ugly-free openscad
```

### VS Code extensions

Unaffected by OS — `code --install-extension <id>` for each entry in `Brewfile`'s `vscode "..."` lines works the same on Linux, once VS Code itself is installed:
```bash
# VS Code: add Microsoft's repo (https://code.visualstudio.com/docs/setup/linux#_rhel-fedora-and-centos-based-distributions), then:
sudo dnf install -y code
```

## Installation

After installing the dependencies above, clone this repository and source the `.zshrc` file:

```bash
git clone https://github.com/USERNAME/dotfiles.git ~/git/dotfiles
echo "source ~/git/dotfiles/.zshrc" >> ~/.zshrc
```

Replace USERNAME with your GitHub username.

## Testing Changes

Before committing changes to ZSH configuration files:

```bash
# Check syntax of modified file
zsh -n ~/git/dotfiles/zsh/[modified-file].zsh

# Source and test the changes
source ~/git/dotfiles/zsh/[modified-file].zsh

# Test full shell reload
exec zsh
```

 <3
