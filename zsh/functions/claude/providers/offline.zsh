# ---------------------------------------------------------------------------
# claude-offline: dispatches to claude-mlx on Apple Silicon Darwin (where MLX
# generally beats Ollama's llama.cpp/GGUF backend for throughput/memory
# efficiency), claude-ollama everywhere else (Linux, Intel Mac) -- see
# claude-mlx's comment block above for why MLX can't just replace Ollama
# outright (Apple-Silicon-only, single-shared-model instead of three tiers).
# CLAUDE_OFFLINE_FORCE_OLLAMA=1 is the escape hatch back to the old
# Ollama-only behavior on Apple Silicon without typing claude-ollama directly.
claude-offline() {
    if [[ ( -z "$CLAUDE_OFFLINE_FORCE_OLLAMA" || "$CLAUDE_OFFLINE_FORCE_OLLAMA" == 0 ) ]] \
        && _claude_mlx_supported; then
        claude-mlx "$@"
    else
        claude-ollama "$@"
    fi
}
