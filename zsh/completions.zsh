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
  source <(curl -s https://raw.githubusercontent.com/docker/docker-ce/master/components/cli/contrib/completion/zsh/_docker)
  compdef _docker docker
fi

if [ $(command -v podman) ]; then
  # https://raw.githubusercontent.com/containers/podman/main/completions/zsh/_podman
  source <(curl -s https://raw.githubusercontent.com/containers/podman/main/completions/zsh/_podman)
  compdef _podman podman
fi