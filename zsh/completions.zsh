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
  timeout 1s sh -c "curl -s https://raw.githubusercontent.com/docker/docker-ce/master/components/cli/contrib/completion/zsh/_docker > ~/_docker_curl" && mv ~/_docker_curl ~/_docker || (rm ~/_docker_curl; echo "offline - _docker")
  source <(cat ~/_docker)
  compdef _docker docker
fi

if [ $(command -v podman) ]; then
  # https://raw.githubusercontent.com/containers/podman/main/completions/zsh/_podman
  timeout 1s sh -c "curl -s https://raw.githubusercontent.com/containers/podman/main/completions/zsh/_podman > ~/_podman_curl" && mv ~/_podman_curl ~/_podman || (rm ~/_podman_curl; echo "offline - _podman")
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

if [ $(command -v ccoctl) ]; then
  source <(ccoctl completion zsh)
  compdef _ccoctl ccoctl
fi
