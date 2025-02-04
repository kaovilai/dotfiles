# Don't put secrets here, put them in ~/secrets.zsh
# edit ~/.zshrc first then run copy-to-dotfiles-from-zshrc to copy to dotfiles
[[ -f ~/secrets.zsh ]] && source ~/secrets.zsh
export HISTSIZE=100000 # number of commands stored in history
export HISTFILESIZE=200000 # bytes in history file
[[ -f ~/git/dotfiles/zsh/znap.zsh ]] || sh -c "mkdir -p ~/git && git clone --depth 1 -- \
    git@github.com:kaovilai/dotfiles.git ~/git/dotfiles"
source ~/git/dotfiles/zsh/colors.zsh
if diff ~/git/dotfiles/.zshrc ~/.zshrc; then
  echo ".zshrc is up to date with dotfiles"
else
  echo "diff ~/git/dotfiles/.zshrc ~/.zshrc";\
  echo ".zshrc is out of sync with dotfiles\n\
    ${RED}copy-to-dotfiles-from-zshrc${NC} to copy .zshrc to dotfiles and review diff\n\
    ${RED}push-dotfiles-from-zshrc${NC} to push dotfiles\n\
    ${RED}update-zshrc-from-dotfiles${NC} to update ~/.zshrc"
fi
alias edit-dotfiles='code ~/git/dotfiles/'
if git -C ~/git/dotfiles status --porcelain | grep -q "M"; then
  echo "dotfiles repo has uncommitted changes, run ${RED}edit-dotfiles${NC} to review"
fi
source ~/git/dotfiles/zsh/alias.zsh
# gpg tty
export GPG_TTY=$(tty)
# for openshift/release makefile
export CONTAINER_ENGINE=docker
# for velero Makefile to skip buildx running checks
export BUILDX_ENABLED=true
export BUILDX_PUSH=true
export GCR_IMAGE_TAGS=""
# for velero to `make container` for multi-arch builds
export BUILDX_PLATFORMS=linux/amd64,linux/arm64

[[ "$(uname -s)" = "Darwin" ]] && echo "macOS detected" && source ~/git/dotfiles/zsh/macos.zsh
source ~/git/dotfiles/zsh/znap.zsh
znap function update-zshrc-from-dotfiles() {
  git -C ~/git/dotfiles pull > /dev/null && \
  cp ~/git/dotfiles/.zshrc ~/.zshrc
}
znap function copy-to-dotfiles-from-zshrc() {
  cp ~/.zshrc ~/git/dotfiles/.zshrc && \
  git -C ~/git/dotfiles diff
  echo
  echo "${RED}push-dotfiles-from-zshrc${NC} to push dotfiles"
}
znap function push-dotfiles-from-zshrc() {
  git -C ~/git/dotfiles add .zshrc && \
  git -C ~/git/dotfiles commit -m "Update .zshrc" && \
  git -C ~/git/dotfiles push
}

source ~/git/dotfiles/zsh/util.zsh
source ~/git/dotfiles/zsh/go.zsh
source ~/git/dotfiles/zsh/paths.zsh
source ~/git/dotfiles/zsh/openshift-functions.zsh
source ~/git/dotfiles/zsh/aws.zsh
source ~/git/dotfiles/zsh/podman.zsh
source ~/git/dotfiles/zsh/completions.zsh
eval "$(gh copilot alias -- zsh)"
