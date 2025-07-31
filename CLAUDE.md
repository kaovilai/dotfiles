# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a dotfiles repository containing ZSH shell configuration files and utilities for a productive development environment. The main entry point is `.zshrc` which sources all necessary configuration files.

## Common Commands

### Dotfiles Management
- `copy-to-dotfiles-from-zshrc` - Copy local .zshrc to the dotfiles repo
- `push-dotfiles-from-zshrc` - Push changes to the dotfiles repository  
- `update-zshrc-from-dotfiles` - Update local .zshrc from the dotfiles repo

### Updating .zshrc
When making changes to the ZSH configuration:

1. **Edit in dotfiles repo**:
   ```bash
   cd ~/git/dotfiles
   # Make your changes to files in zsh/
   ```

2. **Test changes locally**:
   ```bash
   # Test specific file
   source ~/git/dotfiles/zsh/[modified-file].zsh
   
   # Update local .zshrc with changes
   update-zshrc-from-dotfiles
   ```

3. **Commit and push**:
   ```bash
   cd ~/git/dotfiles
   git add -A
   git commit -m "feat: description of changes"
   git push
   ```

### Installation
```bash
# Install dependencies from Brewfile
brew bundle --file=~/git/dotfiles/Brewfile

# Run automated migration for new laptop
source ~/git/dotfiles/zsh/functions/migrate-laptop.zsh
migrate-to-new-laptop
```

### Testing & Validation

#### Testing ZSH Changes
No formal test suite exists. Changes should be manually tested by:

1. **Syntax Checking**:
   ```bash
   # Check syntax of a specific file
   zsh -n ~/git/dotfiles/zsh/[modified-file].zsh
   
   # Check entire .zshrc
   zsh -n ~/.zshrc
   ```

2. **Source and Test**:
   ```bash
   # Source the modified file
   source ~/git/dotfiles/zsh/[modified-file].zsh
   
   # Test the modified aliases/functions
   # For functions, check if they're loaded:
   which function_name
   type function_name
   ```

3. **Full Shell Test**:
   ```bash
   # Start a new shell session to test startup
   zsh -l
   
   # Or reload the entire configuration
   exec zsh
   ```

4. **Debug Mode**:
   ```bash
   # Start shell with verbose output for debugging
   zsh -xv
   
   # Or trace specific function execution
   zsh -c 'set -x; function_name'
   ```

#### Common Issues to Check
- **Function conflicts**: Use `which` or `type` to check if a function/alias already exists
- **Syntax errors**: Run `zsh -n` on files before committing
- **Performance**: Use `time zsh -i -c exit` to measure shell startup time
- **Dependencies**: Ensure required commands exist with `command -v cmd_name`

## Architecture

### Directory Structure
- **zsh/**: Main configuration directory
  - **aliases/**: Organized aliases by category (docker, git, github, code, etc.)
  - **functions/**: Complex shell functions
    - **openshift/**: Modular OpenShift cluster management functions
  - **znap.zsh**: Plugin manager configuration
  - **alias.zsh**: Main alias loader that sources all category files

### Key Design Patterns
1. **Modular Aliases**: Aliases are organized by category in separate files under `zsh/aliases/`
2. **Function Organization**: Complex functions use `znap function` for lazy loading
3. **OpenShift Functions**: Hierarchically organized by cloud provider and functionality
4. **Environment Detection**: Special handling for VS Code terminal vs regular terminal
5. **Command Caching**: Uses completion file caching for performance

### Important Files
- `zsh/alias.zsh`: Sources all alias category files
- `zsh/functions/openshift/load.zsh`: Loads all OpenShift-related functions
- `zsh/znap.zsh`: Manages ZSH plugins (pure prompt, syntax highlighting, autocomplete)
- `Brewfile`: Defines all Homebrew dependencies

## Adding New Features

### Adding Aliases
1. Determine appropriate category file in `zsh/aliases/`
2. Add alias to the file
3. For new categories, create file and add source line to `zsh/alias.zsh`

### Adding Functions
1. For simple functions: Add to `zsh/util.zsh`
2. For complex functions: Create new file in `zsh/functions/`
3. For OpenShift functions: Follow the structure in `zsh/functions/openshift/`

### OpenShift Cluster Management

#### Listing and Using Clusters
- `list-ocp-clusters` - List all OpenShift clusters (AWS, GCP, Azure, ROSA)
- `use-ocp-cluster [PATTERN]` - Set KUBECONFIG to a selected cluster
- `check-for-existing-clusters [PROVIDER] [PATTERN]` - Check for existing clusters before creating new ones

#### Supported Cloud Providers
- **AWS**: Traditional OpenShift on AWS (`*-aws-*` naming pattern)
- **GCP**: Google Cloud Platform with Workload Identity (`*-gcp-wif*` naming pattern)
- **Azure**: Azure with STS/Workload Identity (`*-azure-sts*` naming pattern)
- **ROSA**: Red Hat OpenShift Service on AWS (`*-rosa-sts-*` naming pattern)

#### Directory Structure
Clusters are stored in `$OCP_MANIFESTS_DIR` with naming patterns:
- AWS: `$TODAY-aws-$ARCH` (e.g., `20250131-aws-arm64`)
- GCP: `$TODAY-gcp-wif` (e.g., `20250131-gcp-wif`)
- Azure: `$TODAY-azure-sts` (e.g., `20250131-azure-sts`)
- ROSA: `$TODAY-rosa-sts-$ARCH` (e.g., `20250131-rosa-sts-amd64`)

Note: ROSA clusters may not have traditional kubeconfig files. Use `use-rosa-sts` functions to connect.

### Dependencies
When adding features that require new tools, update the `Brewfile` with the necessary formulae or casks.