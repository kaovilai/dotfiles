# Omnigent (https://omnigent.ai) — Claude Code native TUI wrapper
# `omni claude-native` boots the real `claude` CLI in a pane and mirrors it,
# wrapped with Omnigent's collab/policy layer (as opposed to `omni claude`,
# which is Omnigent's own direct-execution mode driving the model itself).
omni-claude() {
    if ! command -v omni &>/dev/null; then
        echo "❌ omni not found. Install: curl -fsSL https://omnigent.ai/install.sh | sh" >&2
        return 1
    fi
    omni claude-native "$@"
}
