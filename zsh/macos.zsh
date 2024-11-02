alias ghd='open -a GitHub\ Desktop'
alias finder='open -R'
alias idlesleeppreventers='pmset -g assertions'
alias edgedev='open -a Microsoft\ Edge\ Dev'
alias edge='open -a Microsoft\ Edge'
alias docker-desktop='open -a /Applications/Docker.app/Contents/MacOS/Docker\ Desktop.app'
alias dockerd='open -a /Applications/Docker.app'
alias dequarantine='xattr -d com.apple.quarantine'
alias dsstoredelete='find . -name .DS_Store -delete'
PATH=$PATH:~/Library/Python/3.9/bin

# znap function podmanMachineReset(){
# if [ $(command -v podman) ]; then
#     podman machine stop; podman machine rm --save-image --force; podman machine init --cpus 6 --disk-size 30 --memory 1500 --now
# fi
# }

function setTTLforHotspot(){
    sudo sysctl -w net.inet.ip.ttl=65
}
# https://docs.brew.sh/Shell-Completion says need to be done before compinit which is in znap.zsh sourced right after this in .zshrc
FPATH="$(brew --prefix)/share/zsh/site-functions:${FPATH}"

function setTFproxy(){
    export TF_ROUTER_IP=$(networksetup -getinfo Wi-Fi | grep -e "^Router" | cut -d " " -f 2)
    export TF_ROUTER_PROXY_PORT=8228
    export http_proxy=$TF_ROUTER_IP:$TF_ROUTER_PROXY_PORT
    export https_proxy=$TF_ROUTER_IP:$TF_ROUTER_PROXY_PORT
    networksetup -setwebproxy Wi-Fi $TF_ROUTER_IP $TF_ROUTER_PROXY_PORT
    networksetup -setsecurewebproxy Wi-Fi $TF_ROUTER_IP $TF_ROUTER_PROXY_PORT
    networksetup -setwebproxystate Wi-Fi on
    networksetup -setsecurewebproxystate Wi-Fi on
}

function unsetTFproxy(){
    networksetup -setwebproxystate Wi-Fi off
    networksetup -setsecurewebproxystate Wi-Fi off
    unset http_proxy
    unset https_proxy
}

function setSOCKSproxy(){
    export SOCKS_ROUTER_IP=$(networksetup -getinfo Wi-Fi | grep -e "^Router" | cut -d " " -f 2)
    export SOCKS_ROUTER_PROXY_PORT=1888
    networksetup -setsocksfirewallproxy Wi-Fi $SOCKS_ROUTER_IP $SOCKS_ROUTER_PROXY_PORT off
    networksetup -setsocksfirewallproxystate Wi-Fi on
}

function unsetSOCKSproxy(){
    networksetup -setsocksfirewallproxystate Wi-Fi off
}
if [[ "$WIFI_NAME" = "S23" ]]; then
    (curl --silent --socks5 $SOCKS_ROUTER_IP:$SOCKS_ROUTER_PROXY_PORT http://www.google.com && setSOCKSproxy) || unsetSOCKSproxy
fi
# To get git to work over ssh via 443 proxy,
# replace .git/config `git@github.com:(.*)/`
# with `ssh://git@ssh.github.com:443/$1/`
WIFI_NAME=$(networksetup -getairportnetwork en0 | cut -d " " -f 4)
if [[ "$WIFI_NAME" = "$TF_NETWORK_NAME" ]]; then
    setTFproxy
    # mkdir -p ~/.ssh/tigerdotfiles/
    # echo "Host github.com
    # Hostname github.com
    # ServerAliveInterval 55
    # ForwardAgent yes
    # ProxyCommand $(which socat) - PROXY:$TF_ROUTER_IP:%h:%p,proxyport=$TF_ROUTER_PROXY_PORT" > ~/.ssh/tigerdotfiles/config
else
    unsetTFproxy
fi