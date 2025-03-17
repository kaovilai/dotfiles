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
