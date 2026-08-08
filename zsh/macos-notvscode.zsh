# Heavy operations and network-related functions
# This file is sourced only when not in VS Code to keep terminal startup fast

is-at-home() {
    [[ "$OSTYPE" != darwin* ]] && return 1
    local usb_info
    usb_info=$(ioreg -p IOUSB) &&
    grep -q "Plugable USBC-6950U" <<< "$usb_info" &&
    grep -q "TS4" <<< "$usb_info" &&
    networksetup -getnetworkserviceenabled "Thunderbolt Ethernet Slot 2" | grep -q Enabled
}
is-displaylink-connected() {
    [[ "$OSTYPE" != darwin* ]] && return 1
    local display_info
    display_info=$(system_profiler SPDisplaysDataType)
    grep -q "ARZOPA" <<< "$display_info" ||
    grep -q "TYPE-C" <<< "$display_info"
}
restart-displaylink() {
    if [[ "$OSTYPE" != darwin* ]]; then
        echo "Error: restart-displaylink is only supported on macOS" >&2
        return 1
    fi
    osascript -e 'quit app "DisplayLink Manager"'
    while pgrep DisplayLinkUserAgent > /dev/null; do sleep 0.1; done
    open -a "DisplayLink Manager"
}

set-ttl-for-hotspot(){
    if [[ "$OSTYPE" != darwin* ]]; then
        echo "Error: set-ttl-for-hotspot is only supported on macOS" >&2
        return 1
    fi
    sudo sysctl -w net.inet.ip.ttl=65
}

set-tf-proxy(){
    if [[ "$OSTYPE" != darwin* ]]; then
        echo "Error: set-tf-proxy is only supported on macOS" >&2
        return 1
    fi
    local _router_ip
    _router_ip=${${$(networksetup -getinfo Wi-Fi | grep -e "^Router")}##* }
    if [[ -z "$_router_ip" ]]; then
        echo "Error: Could not determine Wi-Fi router IP" >&2
        return 1
    fi
    export TF_ROUTER_IP="$_router_ip"
    export TF_ROUTER_PROXY_PORT=8228
    export http_proxy="$TF_ROUTER_IP:$TF_ROUTER_PROXY_PORT"
    export https_proxy="$TF_ROUTER_IP:$TF_ROUTER_PROXY_PORT"
    networksetup -setwebproxy Wi-Fi "$TF_ROUTER_IP" "$TF_ROUTER_PROXY_PORT"
    networksetup -setsecurewebproxy Wi-Fi "$TF_ROUTER_IP" "$TF_ROUTER_PROXY_PORT"
    networksetup -setwebproxystate Wi-Fi on
    networksetup -setsecurewebproxystate Wi-Fi on
}

unset-tf-proxy(){
    if [[ "$OSTYPE" != darwin* ]]; then
        echo "Error: unset-tf-proxy is only supported on macOS" >&2
        return 1
    fi
    networksetup -setwebproxystate Wi-Fi off
    networksetup -setsecurewebproxystate Wi-Fi off
    unset http_proxy
    unset https_proxy
}

set-socks-proxy(){
    if [[ "$OSTYPE" != darwin* ]]; then
        echo "Error: set-socks-proxy is only supported on macOS" >&2
        return 1
    fi
    local _dry_run=0
    local -a _args
    for _arg in "$@"; do
        if [[ "$_arg" == "--dry-run" || "$_arg" == "-n" ]]; then
            _dry_run=1
        else
            _args+=("$_arg")
        fi
    done
    # Allow IP override via parameter, otherwise get from router
    if [[ -n "${_args[1]}" ]]; then
        export SOCKS_ROUTER_IP="${_args[1]}"
    else
        local _router_ip
        _router_ip=${${$(networksetup -getinfo Wi-Fi | grep -e "^Router")}##* }
        if [[ -z "$_router_ip" ]]; then
            echo "Error: Could not determine Wi-Fi router IP" >&2
            return 1
        fi
        export SOCKS_ROUTER_IP="$_router_ip"
    fi
    local _wifi_iface
    _wifi_iface=$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi/{found=1} found && /Device:/{print $2; exit}')

    # Detect hotspot OS: iOS Personal Hotspot always uses 172.20.10.1; Android AOSP defaults to 192.168.43.1 (Samsung Z Fold7 uses 10.168.176.*)
    local _net_type="unknown"
    if [[ "$SOCKS_ROUTER_IP" == "172.20.10.1" ]]; then
        _net_type="ios"
    elif [[ "$SOCKS_ROUTER_IP" == "192.168.43.1" || "$SOCKS_ROUTER_IP" == 192.168.*.1 || "$SOCKS_ROUTER_IP" == 10.168.176.* ]]; then
        _net_type="android"
    else
        local _ssid
        _ssid=$(networksetup -getairportnetwork "${_wifi_iface:-en0}" 2>/dev/null | sed 's/^Current Wi-Fi Network: //')
        local _ssid_lower="${_ssid:l}"
        if [[ "$_ssid_lower" == *iphone* ]]; then
            _net_type="ios"
        elif [[ "$_ssid_lower" == *android* || "$_ssid_lower" == *pixel* || "$_ssid_lower" == *galaxy* || "$_ssid_lower" == *samsung* || "$_ssid_lower" == *motorola* ]]; then
            _net_type="android"
        fi
    fi
    echo "Detected hotspot: $_net_type (router $SOCKS_ROUTER_IP)"

    # Only probe the iOS-SOCKS-Server port for iOS, the Android SOCKS server port for Android; try both if undetected
    local -a _ports_to_try
    case "$_net_type" in
        ios) _ports_to_try=(9876) ;;
        android) _ports_to_try=(1888) ;;
        *) _ports_to_try=(9876 1888) ;;
    esac

    local _port
    for _port in "${_ports_to_try[@]}"; do
        echo "Probing $SOCKS_ROUTER_IP:$_port ..."
        if nc -z -w 1 "$SOCKS_ROUTER_IP" "$_port" 2>/dev/null; then
            echo "  open"
            export SOCKS_ROUTER_PROXY_PORT="$_port"
            break
        else
            echo "  closed/unreachable"
        fi
    done
    : "${SOCKS_ROUTER_PROXY_PORT:=1888}"

    # iOS-SOCKS-Server needs a manual IPv4 (self as router+DNS) so macOS doesn't
    # flag the hotspot interface as unreachable and drop the SOCKS route - see
    # https://github.com/nneonneo/iOS-SOCKS-Server/issues/1#issuecomment-583989079
    if [[ "$_net_type" == "ios" ]]; then
        if [[ -z "$_wifi_iface" ]]; then
            echo "Error: could not find Wi-Fi interface for manual IPv4 override" >&2
            return 1
        fi
        local _current_ip
        _current_ip=$(ifconfig "$_wifi_iface" | awk '/inet /{print $2; exit}')
        if [[ -z "$_current_ip" ]]; then
            echo "Error: could not determine current IPv4 address on $_wifi_iface" >&2
            return 1
        fi
        if [[ "$_dry_run" -eq 1 ]]; then
            echo "[dry-run] Would run: sudo networksetup -setmanual Wi-Fi $_current_ip 255.255.0.0 $_current_ip"
            echo "[dry-run] Would run: sudo networksetup -setdnsservers Wi-Fi $_current_ip"
        else
            echo "Switching Wi-Fi IPv4 to manual: $_current_ip"
            sudo networksetup -setmanual Wi-Fi "$_current_ip" 255.255.0.0 "$_current_ip"
            sudo networksetup -setdnsservers Wi-Fi "$_current_ip"
            export SOCKS_IOS_MANUAL_APPLIED=1
        fi
    fi

    if [[ "$_dry_run" -eq 1 ]]; then
        echo "[dry-run] Would use SOCKS proxy $SOCKS_ROUTER_IP:$SOCKS_ROUTER_PROXY_PORT"
        echo "[dry-run] Would run: networksetup -setsocksfirewallproxy Wi-Fi $SOCKS_ROUTER_IP $SOCKS_ROUTER_PROXY_PORT off"
        echo "[dry-run] Would run: networksetup -setsocksfirewallproxystate Wi-Fi on"
        return 0
    fi
    echo "Using SOCKS proxy $SOCKS_ROUTER_IP:$SOCKS_ROUTER_PROXY_PORT"
    networksetup -setsocksfirewallproxy Wi-Fi "$SOCKS_ROUTER_IP" "$SOCKS_ROUTER_PROXY_PORT" off
    networksetup -setsocksfirewallproxystate Wi-Fi on
}

test-socks-proxy(){
    if [[ "$OSTYPE" != darwin* ]]; then
        echo "Error: test-socks-proxy is only supported on macOS" >&2
        return 1
    fi
    local _ip="${1:-$SOCKS_ROUTER_IP}"
    local _port="${2:-$SOCKS_ROUTER_PROXY_PORT}"
    if [[ -z "$_ip" || -z "$_port" ]]; then
        echo "Error: no proxy configured. Run set-socks-proxy first, or pass <ip> <port>." >&2
        return 1
    fi
    echo "Testing SOCKS proxy $_ip:$_port ..."
    if curl --silent --show-error --connect-timeout 5 --socks5 "$_ip:$_port" http://www.google.com -o /dev/null; then
        echo "  OK: $_ip:$_port reachable and proxying"
        return 0
    else
        echo "  FAIL: $_ip:$_port not reachable or not proxying" >&2
        return 1
    fi
}

unset-socks-proxy(){
    if [[ "$OSTYPE" != darwin* ]]; then
        echo "Error: unset-socks-proxy is only supported on macOS" >&2
        return 1
    fi
    networksetup -setsocksfirewallproxystate Wi-Fi off
    if [[ "$SOCKS_IOS_MANUAL_APPLIED" == "1" ]]; then
        echo "Reverting Wi-Fi IPv4/DNS to DHCP"
        sudo networksetup -setdhcp Wi-Fi
        sudo networksetup -setdnsservers Wi-Fi "Empty"
        unset SOCKS_IOS_MANUAL_APPLIED
    fi
}

get-socks-proxy(){
    if [[ "$OSTYPE" != darwin* ]]; then
        echo "Error: get-socks-proxy is only supported on macOS" >&2
        return 1
    fi
    local router_ip="${SOCKS_ROUTER_IP}"
    if [[ -z "$router_ip" ]]; then
        router_ip=${${$(networksetup -getinfo Wi-Fi | grep -e "^Router")}##* }
    fi
    local proxy_port="${SOCKS_ROUTER_PROXY_PORT:-1888}"

    echo "SOCKS Proxy: ${router_ip}:${proxy_port}"
    echo ""
    echo "Usage in other applications:"
    echo "  curl:        curl --socks5 ${router_ip}:${proxy_port} https://example.com"
    echo "  SSH config:  ProxyCommand nc -X 5 -x ${router_ip}:${proxy_port} %h %p"
    echo "  Environment: export ALL_PROXY=socks5://${router_ip}:${proxy_port}"
    echo "  Git:         git config --global http.proxy socks5://${router_ip}:${proxy_port}"
}

# Wi-Fi and network-related setup - cache network name
if [[ "$TERM_PROGRAM" != "vscode" ]]; then
  # Detect WiFi interface dynamically (consistent with set-tf-proxy and other functions)
  _WIFI_IFACE=$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi/{found=1} found && /Device:/{print $2; exit}')
  # Get WiFi name once and cache it
  WIFI_NAME=$(networksetup -getairportnetwork "${_WIFI_IFACE:-en0}" 2>/dev/null | cut -d " " -f 4)
  unset _WIFI_IFACE
  
  # Run home setup check in background
  (is-at-home && (is-displaylink-connected || restart-displaylink)) &!
  
  # Handle proxy setup based on network
  if [[ "$WIFI_NAME" = "PASSAWIT's Z Fold7" ]]; then
        (curl --silent --connect-timeout 5 --socks5 "$SOCKS_ROUTER_IP:$SOCKS_ROUTER_PROXY_PORT" http://www.google.com && set-socks-proxy) &!
    else
        unset-socks-proxy &!
    fi
    # MAC address randomization - uses ifconfig method (reliable on M4/Apple Silicon)
    # Source the function first
    _safe_source ~/git/dotfiles/zsh/functions/randomize-mac.zsh
    # Create alias for backward compatibility
    alias randomize-mac='randomize-mac-ifconfig'

fi

# kill apps that are not essential
give-me-ram(){
    if [[ "$OSTYPE" != darwin* ]]; then
        echo "Error: give-me-ram is only supported on macOS" >&2
        return 1
    fi
    local pids
    pids=$(ps aux | grep -v grep | grep -E '/Messenger.app/|Acrobat|Fathom|Todoist|LINE' | sed -E 's/ +/ /g' | cut -d ' ' -f 2)
    if [[ -z "$pids" ]]; then
        echo "No matching processes found."
        return 0
    fi
    kill -9 ${=pids}
}

# AA Inflight WiFi automation - randomize MAC every 20 minutes for free WiFi
_safe_source ~/git/dotfiles/zsh/functions/aa-inflight-wifi.zsh

# Backwards compatibility aliases for renamed functions
alias setTTLforHotspot='set-ttl-for-hotspot'
alias setTFproxy='set-tf-proxy'
alias unsetTFproxy='unset-tf-proxy'
alias setSOCKSproxy='set-socks-proxy'
alias unsetSOCKSproxy='unset-socks-proxy'
alias getSOCKSproxy='get-socks-proxy'
