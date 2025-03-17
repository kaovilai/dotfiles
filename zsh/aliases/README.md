# ZSH Aliases Organization

This directory contains aliases organized by category for better maintainability and readability.

## Categories

- **docker.zsh**: Docker-related aliases for building, tagging, and pushing containers
- **git.zsh**: Git commands shortcuts like commit, push, fetch, and branch operations
- **github.zsh**: GitHub CLI specific commands for pull requests, issues, and other GitHub operations
- **code.zsh**: VSCode related aliases for opening specific projects
- **ibmcloud.zsh**: IBM Cloud related commands and utilities
- **velero.zsh**: Velero-specific commands and helpers
- **misc.zsh**: Miscellaneous aliases that don't fit in other categories

## Using the Aliases

All aliases are automatically loaded by the main `zsh/alias.zsh` file, which sources each category file.

## Adding New Aliases

To add new aliases:

1. Determine which category best fits your new alias
2. Add it to the appropriate file
3. If you need to create a new category:
   - Create a new file in this directory (e.g., `newcategory.zsh`)
   - Add your aliases to this file
   - Add the source line in `zsh/alias.zsh`:
     ```zsh
     source ~/git/dotfiles/zsh/aliases/newcategory.zsh
