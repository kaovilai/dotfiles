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
- **claude-copilot.zsh**: Claude provider wrappers and mode selection
- **claude-enmass.zsh**: Isolated Claude Code sessions through EnMaaS ([setup](../../docs/setup-claude-enmass.md))

## Claude Model Picker

Provider wrappers share a `/model` picker ordered for switching: newest Claude generation first, available current GPT alternatives next, then other current alternatives and older models. Tier labels remain attached to their original model IDs; ordering does not change the active model or Auto Mode mappings. Model availability and prices depend on the selected provider.

Offline ordering regression: `zsh ~/git/dotfiles/tests/claude-model-picker.zsh`.

For using these providers from T3 Code, see [Claude backends in T3 Code](../../docs/setup-claude-t3.md). T3 runs the `claude-t3-*` executable launchers; interactive terminals continue to use the `claude-*` shell functions. Both share the existing proxy services.

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
