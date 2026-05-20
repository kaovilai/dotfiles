# Build PATH using ZSH path array with (N) glob qualifier to silently omit non-existent directories
path=(
    /opt/homebrew/opt/gnu-sed/libexec/gnubin(N)
    /opt/homebrew/opt/grep/libexec/gnubin(N)
    $HOME/go/bin(N)
    ${KREW_ROOT:-$HOME/.krew}/bin(N)
    $HOME/.npm-global/bin(N)
    $HOME/.local/bin(N)
    $path
    $HOME/google-cloud-sdk/bin(N)
)
