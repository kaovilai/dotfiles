# Claude Code provider wrappers: one file per provider under providers/, each
# opening with a header block covering requirements, env vars and lifecycle.
# Order matters: common.zsh helpers first, mode.zsh (the `claude` dispatcher)
# last. T3 Code launchers for these providers: scripts/claude-provider.zsh.
source "${${(%):-%N}:A:h}/common.zsh"
source "${${(%):-%N}:A:h}/providers/copilot.zsh"
source "${${(%):-%N}:A:h}/providers/vertex.zsh"
source "${${(%):-%N}:A:h}/providers/ollama.zsh"
source "${${(%):-%N}:A:h}/providers/mlx.zsh"
source "${${(%):-%N}:A:h}/providers/offline.zsh"
source "${${(%):-%N}:A:h}/providers/openai.zsh"
source "${${(%):-%N}:A:h}/providers/enmass.zsh"
source "${${(%):-%N}:A:h}/mode.zsh"
