# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a dotfiles repository containing ZSH shell configuration files and utilities for a productive development environment. The main entry point is `.zshrc` which sources all necessary configuration files.

## Common Commands

### Dotfiles Management
- `copy-to-dotfiles-from-zshrc` - Copy local .zshrc to the dotfiles repo
- `push-dotfiles-from-zshrc` - Push changes to the dotfiles repository  
- `update-zshrc-from-dotfiles` - Update local .zshrc from the dotfiles repo

### Installation
```bash
# Install dependencies from Brewfile
brew bundle --file=~/git/dotfiles/Brewfile

# Run automated migration for new laptop
source ~/git/dotfiles/zsh/functions/migrate-laptop.zsh
migrate-to-new-laptop
```

### Testing
No formal test suite exists. Changes should be manually tested by:
1. Sourcing the modified file: `source ~/git/dotfiles/zsh/[modified-file].zsh`
2. Testing the modified aliases/functions
3. Restarting shell to ensure no startup errors

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

### Dependencies
When adding features that require new tools, update the `Brewfile` with the necessary formulae or casks.