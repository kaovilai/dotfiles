# Heavy operations and network-related functions
# This file is sourced only when not in VS Code to keep terminal startup fast

AT_HOME='(ioreg -p IOUSB | grep "Plugable USBC-6950U" > /dev/null && ioreg -p IOUSB | grep "TS4" > /dev/null && networksetup -getnetworkserviceenabled Thunderbolt\ Ethernet\ Slot\ 2 | grep Enabled > /dev/null)'
DISPLAYLINK_CONNECTED='(system_profiler SPDisplaysDataType | grep ARZOPA > /dev/null || system_profiler SPDisplaysDataType | grep TYPE-C > /dev/null)'
RESTART_DISPLAYLINK='(osascript -e "quit app \"DisplayLink Manager\""; while pgrep DisplayLinkUserAgent > /dev/null; do sleep 0.1; done; open -a DisplayLink\ Manager)'

znap function setTTLforHotspot(){
    sudo sysctl -w net.inet.ip.ttl=65
}

znap function setTFproxy(){
    export TF_ROUTER_IP=$(networksetup -getinfo Wi-Fi | grep -e "^Router" | cut -d " " -f 2)
    export TF_ROUTER_PROXY_PORT=8228
    export http_proxy=$TF_ROUTER_IP:$TF_ROUTER_PROXY_PORT
    export https_proxy=$TF_ROUTER_IP:$TF_ROUTER_PROXY_PORT
    networksetup -setwebproxy Wi-Fi $TF_ROUTER_IP $TF_ROUTER_PROXY_PORT
    networksetup -setsecurewebproxy Wi-Fi $TF_ROUTER_IP $TF_ROUTER_PROXY_PORT
    networksetup -setwebproxystate Wi-Fi on
    networksetup -setsecurewebproxystate Wi-Fi on
}

znap function unsetTFproxy(){
    networksetup -setwebproxystate Wi-Fi off
    networksetup -setsecurewebproxystate Wi-Fi off
    unset http_proxy
    unset https_proxy
}

znap function setSOCKSproxy(){
    # Allow IP override via parameter, otherwise get from router
    if [[ -n "$1" ]]; then
        export SOCKS_ROUTER_IP="$1"
    else
        export SOCKS_ROUTER_IP=$(networksetup -getinfo Wi-Fi | grep -e "^Router" | cut -d " " -f 2)
    fi
    export SOCKS_ROUTER_PROXY_PORT=1888
    networksetup -setsocksfirewallproxy Wi-Fi $SOCKS_ROUTER_IP $SOCKS_ROUTER_PROXY_PORT off
    networksetup -setsocksfirewallproxystate Wi-Fi on
}

znap function unsetSOCKSproxy(){
    networksetup -setsocksfirewallproxystate Wi-Fi off
}

# Wi-Fi and network-related setup - cache network name
if [[ "$TERM_PROGRAM" != "vscode" ]]; then
  # Get WiFi name once and cache it
  WIFI_NAME=$(networksetup -getairportnetwork en0 2>/dev/null | cut -d " " -f 4)
  
  # Run home setup check in background
  eval $AT_HOME && (eval $DISPLAYLINK_CONNECTED || eval $RESTART_DISPLAYLINK) &!
  
  # Handle proxy setup based on network
  if [[ "$WIFI_NAME" = "PASSAWIT's Z Fold7" ]]; then
        (curl --silent --socks5 $SOCKS_ROUTER_IP:$SOCKS_ROUTER_PROXY_PORT http://www.google.com && setSOCKSproxy) &!
    else
        unsetSOCKSproxy &!
    fi
    # randomize mac address, requires wi-fi to be en0, check with `sudo networksetup -listallhardwareports`
    # requires spoof-mac -> https://formulae.brew.sh/formula/spoof-mac
    alias randomize-mac='sudo networksetup -setairportpower en0 off && sudo spoof-mac randomize wi-fi'

    # To get git to work over ssh via 443 proxy,
    # replace .git/config `git@github.com:(.*)/`
    # with `ssh://git@ssh.github.com:443/$1/`
    if [[ "$WIFI_NAME" = "$TF_NETWORK_NAME" ]]; then
        setTFproxy &!
        # mkdir -p ~/.ssh/tigerdotfiles/
        # echo "Host github.com
        # Hostname github.com
        # ServerAliveInterval 55
        # ForwardAgent yes
        # ProxyCommand $(which socat) - PROXY:$TF_ROUTER_IP:%h:%p,proxyport=$TF_ROUTER_PROXY_PORT" > ~/.ssh/tigerdotfiles/config
    else
        unsetTFproxy &!
    fi
fi

# kill apps that are not essential
znap function give-me-ram(){
    ps aux | grep -v grep | grep -E '/Messenger.app/|Acrobat|Fathom|Todoist|LINE' | sed -E 's/ +/ /g' | cut -d ' ' -f 2 | xargs kill -9
}
