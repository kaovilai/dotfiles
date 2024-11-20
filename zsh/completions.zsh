#compdef kubectl
compdef _kubectl kubectl
if [ -f '~/Downloads/google-cloud-sdk/path.zsh.inc' ]; then . '~/Downloads/google-cloud-sdk/path.zsh.inc'; fi
if [ $(command -v oc) ]; then
  source <(oc completion zsh)
  compdef _oc oc
fi

# The next line updates PATH for the Google Cloud SDK.
if [ -f '~/google-cloud-sdk/path.zsh.inc' ]; then . '~/google-cloud-sdk/path.zsh.inc'; fi

# The next line enables shell command completion for gcloud.
if [ -f '~/google-cloud-sdk/completion.zsh.inc' ]; then . '~/google-cloud-sdk/completion.zsh.inc'; fi

if [ $(command -v gh) ]; then
  source <(gh completion -s zsh)
  compdef _gh gh
fi
if [ $(command -v docker) ]; then
  # get completion by curling from https://raw.githubusercontent.com/docker/docker-ce/master/components/cli/contrib/completion/zsh/_docker
  (curl -sLm 10 https://raw.githubusercontent.com/docker/docker-ce/master/components/cli/contrib/completion/zsh/_docker > ~/_docker_curl && mv ~/_docker_curl ~/_docker || (rm ~/_docker_curl; echo "offline - _docker")) &
  source <(cat ~/_docker)
  compdef _docker docker
fi

if [ -n "$(command -v podman)" ]; then
  # https://raw.githubusercontent.com/containers/podman/main/completions/zsh/_podman
  (curl -sLm 10 https://raw.githubusercontent.com/containers/podman/main/completions/zsh/_podman > ~/_podman_curl && mv ~/_podman_curl ~/_podman || (rm -f ~/_podman_curl; echo "offline - _podman")) &
  source <(cat ~/_podman)
  compdef _podman podman
fi

if [ $(command -v aws_completer) ]; then
  complete -C aws_completer aws
fi

if [ $(command -v rosa) ]; then
  source <(rosa completion zsh)
  compdef _rosa rosa
fi

if [ $(command -v crc) ]; then
  source <(crc completion zsh)
  compdef _crc crc
fi

if [ $(command -v ccoctl) ]; then
  source <(ccoctl completion zsh)
  compdef _ccoctl ccoctl
fi

# if [ $(command -v glab) ]; then
#   source <(glab completion -s zsh)
#   compdef _glab glab
# fi

if [ $(command -v velero) ]; then
  source <(velero completion zsh)
  compdef _velero velero
fi

if [ $(command -v colima) ]; then
  source <(colima completion zsh)
  compdef _colima colima
fi

# kind completion zsh
if [ $(command -v kind) ]; then
  source <(kind completion zsh)
  compdef _kind kind
fi

# openshift-installer zshcompletion
if [ $(command -v openshift-install) ]; then
  source <(cat /Users/tiger/git/dotfiles/openshift-install-completion-zsh.txt)
  compdef _openshift-install openshift-install
fi

# The next line enables shell command completion for gcloud.
if [ -f '/Users/tiger/google-cloud-sdk/completion.zsh.inc' ]; then . '/Users/tiger/google-cloud-sdk/completion.zsh.inc'; fi

source /usr/local/ibmcloud/autocomplete/zsh_autocomplete

eval "$(_PIPENV_COMPLETE=zsh_source pipenv)"
