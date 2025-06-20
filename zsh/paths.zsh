# Build PATH once to avoid multiple string operations
export PATH="/opt/homebrew/opt/gnu-sed/libexec/gnubin:$HOME/go/bin:${KREW_ROOT:-$HOME/.krew}/bin:$HOME/.npm-global/bin:$PATH:$HOME/google-cloud-sdk/bin"
