# Don't put secrets here, put them in ~/secrets.zsh
[[ -f ~/secrets.zsh ]] && source ~/secrets.zsh
[[ "$(uname -s)" = "Darwin" ]] && echo "macOS detected" && source ~/git/dotfiles/zsh/macos.zsh
source ~/git/dotfiles/zsh/colors.zsh
if diff ~/git/dotfiles/.zshrc ~/.zshrc; then
  echo ".zshrc is up to date with dotfiles"
else
  echo ".zshrc is out of sync with dotfiles\n\
    ${RED}copy-to-dotfiles-from-zshrc${NC} to copy .zshrc to dotfiles and review diff\n\
    ${RED}push-dotfiles-from-zshrc${NC} to push dotfiles\n\
    ${RED}update-zshrc-from-dotfiles${NC} to update .zshrc"
fi
function update-zshrc-from-dotfiles() {
  git -C ~/git/dotfiles pull && \
  cp ~/git/dotfiles/.zshrc ~/.zshrc
}
function copy-to-dotfiles-from-zshrc() {
  cp ~/.zshrc ~/git/dotfiles/.zshrc && \
  git -C ~/git/dotfiles diff
  echo
  echo "${RED}push-dotfiles-from-zshrc${NC} to push dotfiles"
}
function push-dotfiles-from-zshrc() {
  git -C ~/git/dotfiles add .zshrc && \
  git -C ~/git/dotfiles commit -m "Update .zshrc" && \
  git -C ~/git/dotfiles push
}
[[ -f ~/git/dotfiles/zsh/znap.zsh ]] || sh -c "mkdir -p ~/git && git clone --depth 1 -- \
    git@github.com:kaovilai/dotfiles.git ~/git/dotfiles"
source ~/git/dotfiles/zsh/znap.zsh
source ~/git/dotfiles/zsh/openshift-functions.zsh
source ~/git/dotfiles/zsh/paths.zsh
source ~/git/dotfiles/zsh/completions.zsh