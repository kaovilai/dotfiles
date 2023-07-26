PATH=$PATH:~/go/bin
PATH=$PATH:~/google-cloud-sdk/bin
PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"

# The next line updates PATH for the Google Cloud SDK.
if [ -f '/Users/tiger/google-cloud-sdk/path.zsh.inc' ]; then . '/Users/tiger/google-cloud-sdk/path.zsh.inc'; fi