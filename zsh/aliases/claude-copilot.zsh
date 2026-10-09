# Moved to zsh/functions/claude/ (one file per provider); kept so older
# references to this path still load every Claude provider.
source "${${(%):-%N}:A:h:h}/functions/claude/load.zsh"
