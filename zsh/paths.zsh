PATH=~/go/bin:$PATH
PATH=$PATH:~/google-cloud-sdk/bin
PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"

# The next line updates PATH for the Google Cloud SDK.
if [ -f '~/google-cloud-sdk/path.zsh.inc' ]; then . '~/google-cloud-sdk/path.zsh.inc'; fi