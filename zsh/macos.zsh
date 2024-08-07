alias code='open -a Visual\ Studio\ Code'
alias ghd='open -a GitHub\ Desktop'
alias finder='open -R'
alias idlesleeppreventers='pmset -g assertions'
alias edgedev='open -a Microsoft\ Edge\ Dev'
alias edge='open -a Microsoft\ Edge'
alias docker-desktop='open -a /Applications/Docker.app/Contents/MacOS/Docker\ Desktop.app'
alias dockerd='open -a /Applications/Docker.app'
alias ocwebconsole='edgedev $(oc whoami --show-console)'
PATH=$PATH:~/Library/Python/3.9/bin

function podmanMachineReset(){
    podman machine stop; podman machine rm --save-image --force; podman machine init --cpus 6 --disk-size 30 --memory 1500 --now
}

function setTTLforHotspot(){
    sudo sysctl -w net.inet.ip.ttl=65
}
# https://docs.brew.sh/Shell-Completion says need to be done before compinit which is in znap.zsh sourced right after this in .zshrc
FPATH="$(brew --prefix)/share/zsh/site-functions:${FPATH}"

WIFI_NAME=$(networksetup -getairportnetwork en0 | cut -d " " -f 4)
if [[ "$WIFI_NAME" = "$TF_NETWORK_NAME" ]]; then
    export TF_ROUTER_IP=$(networksetup -getinfo Wi-Fi | grep -e "^Router" | cut -d " " -f 2)
    export TF_ROUTER_PROXY_PORT=8228
    export http_proxy=$TF_ROUTER_IP:$TF_ROUTER_PROXY_PORT
    export https_proxy=$TF_ROUTER_IP:$TF_ROUTER_PROXY_PORT
    networksetup -setwebproxy Wi-Fi $TF_ROUTER_IP $TF_ROUTER_PROXY_PORT
    networksetup -setsecurewebproxy Wi-Fi $TF_ROUTER_IP $TF_ROUTER_PROXY_PORT
    networksetup -setwebproxystate Wi-Fi on
    networksetup -setsecurewebproxystate Wi-Fi on
else
    networksetup -setwebproxystate Wi-Fi off
    networksetup -setsecurewebproxystate Wi-Fi off
fi