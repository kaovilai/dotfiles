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
    _router_ip=$(networksetup -getinfo Wi-Fi | grep -e "^Router" | cut -d " " -f 2)
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

# Usage: set-socks-proxy [--dry-run|-n] [--adhoc] [--wait] [--no-prompt] [<ip>]
# Description: Routes Mac traffic through a phone's WiFi hotspot via SOCKS5, to get
#   around carrier tethering restrictions. Sets macOS's system-wide SOCKS proxy
#   (networksetup -setsocksfirewallproxy) - covers Safari/Mail/CFNetwork apps; CLI
#   tools like curl/git/ssh do NOT honor it (see get-socks-proxy for those).
#
#   Primarily used with:
#     - iOS: kaovilai/iOS-SOCKS-Server (Pythonista fork) - port 9876.
#       https://github.com/kaovilai/iOS-SOCKS-Server
#     - Android: "Proxy Server" app (cn.adonet.proxy.server.pro) - port 1888.
#       https://play.google.com/store/apps/details?id=cn.adonet.proxy.server.pro
#
#   iPhone Personal Hotspot has two distinct addressing modes seen in the wild:
#     - Classic: gateway 172.20.10.1, /28 subnet (255.255.255.240), DHCP pool .2-.14.
#       The phone's own WiFi bridge interface lives here; iOS-SOCKS-Server binds to it.
#     - CLAT/464XLAT: gateway 192.0.0.1, client gets 192.0.0.2. 192.0.0.0/29 is RFC
#       7335's reserved, explicitly NON-ROUTED "IPv4 Service Continuity Prefix" - seen
#       when the phone's own cellular backhaul is IPv6-only and it runs 464XLAT
#       (RFC 6877) to translate local IPv4 to the carrier's NAT64. DHCP never hands
#       out a route to 172.20.10.0/28 in this mode, so the SOCKS server is physically
#       on the same WiFi radio but unreachable via IPv4 without manual intervention.
#       Confirmed on at least one device+carrier combo that this happens on EVERY
#       WiFi hotspot connection, independent of VPN state - so the Y/n fallback prompt
#       below firing every time is expected, not a bug or a one-off glitch.
#       The phone DOES advertise IPv6 to WiFi hotspot clients - confirmed by an
#       Android device getting a working IPv6 address on this exact same hotspot,
#       concurrently with the Mac showing 192.0.0.x. So when the Mac itself shows no
#       IPv6 (networksetup -getinfo Wi-Fi: "IPv6 Router: none"), that's a macOS-side
#       problem (VPN suppressing it, RA not being processed, etc.), not a carrier/
#       phone-side limitation - worth ruling out a VPN client and forcing a fresh
#       SLAAC solicit (toggle Wi-Fi power off/on) before assuming IPv6 isn't offered.
#
#   Recovers from the CLAT case in order of increasing invasiveness:
#     1. Probe the DHCP-given router IP on ports 9876 and 1888.
#     2. If DHCP also handed out an IPv6 router, probe that too, zone-scoped via the
#        local WiFi interface (e.g. "<addr>%en0") - same idea as the Android app's
#        "<iphone-ipv6>%wlan0" host field, just the local side instead of the
#        remote's. Free, read-only, no sudo - IPv6 link-local doesn't need routing
#        within one L2 segment, so it works regardless of which IPv4 addressing mode
#        is active.
#     3. Last resort: ask (Y/n) to manually pin the Mac's WiFi IPv4 into
#        172.20.10.0/28 (172.20.10.5, router 172.20.10.1) so it can actually reach the
#        phone's bridge interface. Needs sudo. Waits up to ~30s for the SOCKS port to
#        come up; reverts to DHCP automatically on timeout unless --wait is given, in
#        which case it keeps polling 172.20.10.1 indefinitely instead of flapping
#        manual<->DHCP every round.
#
#   Flags:
#     --dry-run/-n  Print what would happen (including probes, which are read-only),
#                   make no network config changes.
#     --adhoc       Also apply the self-as-router+DNS trick for true ad-hoc/169.254.x
#                   networks with no DHCP at all - a different scenario from the CLAT
#                   fallback above (see the --adhoc block below for the upstream issue
#                   this works around).
#     --wait        Keep retrying indefinitely (Ctrl-C to stop) instead of erroring
#                   out once nothing is found.
#     --no-prompt   Skip the Y/n prompt and decline the manual-IPv4 fallback
#                   automatically - REQUIRED for any backgrounded/non-interactive
#                   invocation. `read -q` reads /dev/tty directly (not fd 0), so
#                   `[[ -t 0 ]]` alone does NOT detect a backgrounded `&!` job in an
#                   interactive shell - it'll still see a real tty and silently hang
#                   (SIGTTIN). The auto-invoke block below always passes this.
#     <ip>          Explicit SOCKS server IP, skipping router auto-detection and the
#                   IPv6/CLAT fallback logic entirely.
#
#   Alternate proxy app note (2026-08-10): SocksBypass
#   (github.com/Nanako0129/SocksBypass) also defaults to port 9876, so it
#   hits the same probing logic above. Its iOS upstream is "device default
#   route" (not forced-cellular like its own Android side), so an
#   iPhone-side VPN (e.g. Cloudflare WARP) applies to it like any other app
#   as long as the phone's default route includes the VPN tunnel.
#
#   Working configuration found, NOT fully root-caused: initial reports had
#   it working from an Android client (the "Super Proxy" app) but not from
#   the Mac. Got both working by pointing the client at the phone's IPv6
#   link-local address with an explicit zone (fe80::...%<adapter>) instead
#   of any IPv4 address - exactly the _socks_router_ipv6 candidate this
#   function already probes automatically. Confirmed (2026-08-10, live
#   hotspot test): the auto-probe above does select this IPv6 candidate on
#   its own - no need to pass the zone-scoped address explicitly as <ip>.
#   So on this phone/carrier, `ndp -rn` did have a router entry (the phone
#   sends RA on this link) - the "empty router table" failure mode below
#   remains a real possibility on other phones/carriers, just not what
#   happened here. Still open, not yet confirmed:
#     - Whether the Mac's IPv4-broken / IPv6-working state and the working
#       zone-scoped test were even captured in the same live session - that
#       was never verified simultaneously. Next time this is tested on the
#       actual hotspot, capture `ipconfig getsummary en0`, `ifconfig en0`,
#       `ndp -rn`, `ndp -an`, and `netstat -rn -f inet` together in one
#       pass - that settles more than another round of secondhand research.
#     - CONFIRMED (2026-08-10, live hotspot test): `networksetup
#       -setsocksfirewallproxy` a few lines below (this function's actual
#       output, not just the nc port-probe above) does accept a zone-scoped
#       IPv6 literal, and a real CFNetwork app (Safari/Mail) successfully
#       browsed through it - not just a port-probe or curl round-trip. So
#       the whole path (auto-probe or explicit <ip> -> set-socks-proxy ->
#       system SOCKS proxy -> CFNetwork app) works end-to-end for
#       SocksBypass on at least one live run.
#   Confirmed separately (2026-08-10, empirically, not just per spec) for
#   get-socks-proxy's plain curl/ALL_PROXY/git output: bracketing a
#   zone-scoped IPv6 address is required - curl refuses to even parse it
#   unbracketed ("Unsupported proxy syntax") - but RFC 6874's %25-escaped
#   zone is NOT actually required for curl in practice, a raw %zone inside
#   brackets parses identically. Separately: plain `nc <host> <port>` DOES
#   handle a zone-scoped IPv6 literal fine (confirmed - it reaches a real
#   connect attempt, "Connection refused"/timeout, not a parse error), so
#   the earlier claim that nc can't do zone IDs at all was wrong. What
#   actually fails is nc's `-x proxy:port` flag specifically - it can't
#   parse ANY IPv6 address combined into one host:port string, zone-scoped
#   or not (confirmed: even a bare bracketed, non-zone `::1` fails
#   identically via -x) - so get-socks-proxy's SSH ProxyCommand line will
#   not work for a
#   link-local address; get-socks-proxy now says so when it prints one.
#
#   This file disagreed with itself on where the CLAT 192.0.0.x address
#   actually comes from, and that's still unresolved, not settled:
#     - Line 84 above: DHCP hands out the synthetic address; no route to
#       the real 172.20.10.0/28 bridge subnet exists in this mode.
#     - Lines 282-283 below (the CLAT fallback prompt): "iOS hotspots
#       sometimes hand the Mac a synthesized NAT64/CLAT gateway... via
#       DHCP."
#     - This note (an earlier revision of it): "not something the iPhone
#       hands out via DHCP - macOS self-assigns it" as its own on-device
#       CLAT client.
#   These aren't the same mechanism, and only one command actually
#   discriminates them, run live on the hotspot: `ipconfig getsummary en0`.
#   No DHCPv4 lease section at all means macOS's own CLAT (this note's
#   model) - reported (not Apple-confirmed) to reuse the literal address
#   192.0.0.2 on every interface running CLAT, per a comment on an IETF
#   v6ops draft issue (github.com/furry13/v6ops-464xlat-enable/issues/37),
#   which also means seeing 192.0.0.2 alone never tells you which interface
#   is the hotspot if more than one is CLAT-active. A real lease (yiaddr in
#   172.20.10.0/28) while the interface still shows 192.0.0.2 means a third,
#   dual-stack model neither passage above describes - a real DHCPv4 lease
#   coexisting with macOS engaging
#   CLAT anyway. Whichever it is doesn't change the recommendation below,
#   but don't read any of the three passages as confirmed until checked.
#
#   On the actual question asked - does forcing the Mac to IPv6-only
#   (`networksetup -setv4off Wi-Fi`) fix this, the same way the Android
#   client apparently avoided getting a 192.0.0.x address:
#     - Directionally, probably no: pushing the Mac further into "no native
#       IPv4" would, if CLAT's trigger really is "v6-only path + NAT64
#       signal present," make CLAT engage more reliably, not less. But that
#       trigger condition is inferred from secondhand sources, not
#       confirmed from Apple - "probably no" is different from "confirmed
#       won't help," and `-setv4off` has never actually been tried here.
#     - The Android side has NOT been shown to lack CLAT for any specific
#       reason - nobody checked its own IPv4 config. The simplest
#       explanation is that "Super Proxy" was also pointed at a link-local
#       literal, sidestepping IPv4/CLAT the same way the Mac fix did. The
#       premise "the Android client didn't get a 192.0.0.x" was taken at
#       face value, not verified.
#     - None of this needs resolving right now: the zone-scoped IPv6
#       literal already reaches SocksBypass on both platforms today, so no
#       IPv4/IPv6 toggle is needed regardless of which model above is true.
#       Revisit only if the IPv6 path itself stops working.
#     - If it ever does need revisiting: the phone's link-local address is
#       not stable long-term - iOS Private Wi-Fi Address rotates the MAC
#       the interface ID derives from, so a literal captured today should
#       be rediscovered per hotspot session, never hardcoded or cached
#       across runs. A device-side kill-switch VPN with a block-all-
#       non-tunnel filter could also drop link-local traffic despite it
#       being interface-scoped - worth ruling out if the IPv6 path ever
#       fails intermittently rather than consistently.
set-socks-proxy(){
    if [[ "$OSTYPE" != darwin* ]]; then
        echo "Error: set-socks-proxy is only supported on macOS" >&2
        return 1
    fi
    local _dry_run=0 _adhoc=0 _wait=0 _no_prompt=0
    local -a _args
    local _arg
    for _arg in "$@"; do
        case "$_arg" in
            --dry-run|-n) _dry_run=1 ;;
            --adhoc) _adhoc=1 ;;
            --wait) _wait=1 ;;
            --no-prompt) _no_prompt=1 ;;
            -*) echo "Error: unknown option: $_arg" >&2; return 1 ;;
            *) _args+=("$_arg") ;;
        esac
    done
    # Allow IP override via parameter, otherwise get from router
    if [[ -n "${_args[1]}" ]]; then
        export SOCKS_ROUTER_IP="${_args[1]}"
    else
        local _wifi_info
        _wifi_info=$(networksetup -getinfo Wi-Fi)
        if grep -q "^Manual Configuration" <<< "$_wifi_info"; then
            local _manual_router_ip
            _manual_router_ip=$(grep -e "^Router" <<< "$_wifi_info" | cut -d " " -f 2)
            if [[ "$_manual_router_ip" == "172.20.10.1" ]]; then
                echo "Wi-Fi already manually configured for the 172.20.10.1 iOS hotspot fallback; reusing it"
                export SOCKS_ROUTER_IP="172.20.10.1"
                export SOCKS_ADHOC_APPLIED=1
            else
                echo "Error: Wi-Fi is already in manual IPv4 config (likely from a previous --adhoc run). Run unset-socks-proxy first." >&2
                return 1
            fi
        else
            local _router_ip
            _router_ip=$(grep -e "^Router" <<< "$_wifi_info" | cut -d " " -f 2)
            if [[ -z "$_router_ip" || "$_router_ip" == "none" ]]; then
                echo "Error: Could not determine Wi-Fi router IP" >&2
                return 1
            fi
            export SOCKS_ROUTER_IP="$_router_ip"
        fi
    fi

    # If we have IPv6 connectivity to the phone, prefer it over the disruptive manual
    # IPv4 fallback below: link-local IPv6 is reachable directly over the same WiFi L2
    # segment regardless of whatever IPv4 subnet DHCP handed out (e.g. the 192.0.0.x
    # CLAT case above). Same idea as Android's "<addr>%wlan0" host field, just the
    # local side - `ndp -rn`'s router entries already come pre-zoned (e.g.
    # "fe80::...%en0"), so no manual zone-suffixing needed here.
    #
    # NOTE: `networksetup -getinfo Wi-Fi`'s "IPv6 Router" field is unreliable - it can
    # report "none" even when the interface has full working global IPv6 (SLAAC/autoconf
    # addresses, even a macOS-native CLAT46 address) and a live default router. Verified
    # on-device: `ifconfig en0` showed real 2607:... autoconf addresses and `ndp -rn`
    # showed a live default router on en0 while networksetup insisted "IPv6 Router:
    # none". `ndp -rn` is the actual source of truth here, not networksetup.
    local _socks_router_ipv6=""
    if [[ -z "${_args[1]}" ]]; then
        local _ipv6_zone_iface
        _ipv6_zone_iface=$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi/{found=1} found && /Device:/{print $2; exit}')
        if [[ -n "$_ipv6_zone_iface" ]]; then
            _socks_router_ipv6=$(ndp -rn 2>/dev/null | awk -v want="if=${_ipv6_zone_iface}," '$0 ~ want {print $1; exit}')
        fi
    fi

    # Don't bother detecting iOS vs Android up front: the two known SOCKS server ports
    # (iOS-SOCKS-Server's 9876, Android's 1888) never overlap, so just probe both
    # and act on whichever one answers.
    local -a _ports_to_try=(9876 1888)
    local _port _port_confirmed=0 _attempt=0
    local _clat_attempted=0 _clat_declined=0 _clat_consented=0
    local _original_router_ip="$SOCKS_ROUTER_IP"
    while true; do
        _attempt=$((_attempt + 1))
        _port_confirmed=0
        for _port in "${_ports_to_try[@]}"; do
            echo "Probing $SOCKS_ROUTER_IP:$_port ..."
            if nc -z -w 1 "$SOCKS_ROUTER_IP" "$_port" 2>/dev/null; then
                echo "  open"
                export SOCKS_ROUTER_PROXY_PORT="$_port"
                _port_confirmed=1
                break
            else
                echo "  closed/unreachable"
            fi
        done
        [[ "$_port_confirmed" -eq 1 ]] && break

        # Try the IPv6 router candidate next, if DHCP gave us one - still free/read-only,
        # no sudo or state mutation needed, unlike the manual-IPv4 fallback below.
        if [[ -n "$_socks_router_ipv6" ]]; then
            for _port in "${_ports_to_try[@]}"; do
                echo "Probing [$_socks_router_ipv6]:$_port ..."
                if nc -z -w 1 "$_socks_router_ipv6" "$_port" 2>/dev/null; then
                    echo "  open"
                    export SOCKS_ROUTER_IP="$_socks_router_ipv6"
                    export SOCKS_ROUTER_PROXY_PORT="$_port"
                    _port_confirmed=1
                    break
                else
                    echo "  closed/unreachable"
                fi
            done
        fi
        [[ "$_port_confirmed" -eq 1 ]] && break

        # Fallback: iOS hotspots sometimes hand the Mac a synthesized NAT64/CLAT
        # gateway (e.g. 192.0.0.1) via DHCP while the actual iOS-SOCKS-Server is only
        # reachable at the real Personal Hotspot gateway, 172.20.10.1, in a subnet the
        # Mac isn't in yet. Ask before reconfiguring Wi-Fi - this needs sudo.
        # NOTE: `read -q` reads /dev/tty directly, not fd 0, so `[[ -t 0 ]]` alone does
        # NOT detect a backgrounded `&!` job in an interactive shell - zsh job control
        # still sees a real tty there and `read -q` will hang (SIGTTIN, silently, since
        # `&!` disowns the job). --no-prompt is the real guard; the auto-invoke block
        # below always passes it. Ask at most once per invocation, either way.
        if [[ "$_clat_attempted" -eq 0 && "$SOCKS_ROUTER_IP" != "172.20.10.1" ]]; then
            _clat_attempted=1
            if [[ "$_dry_run" -eq 1 ]]; then
                echo "[dry-run] Would prompt: Switch Wi-Fi to manual 172.20.10.0/28 to try the iOS hotspot fallback (172.20.10.1)? [y/N]"
                echo "[dry-run] Would run: sudo networksetup -setmanual Wi-Fi 172.20.10.5 255.255.255.240 172.20.10.1"
                echo "[dry-run] Would run: sudo networksetup -setdnsservers Wi-Fi 172.20.10.1"
                echo "[dry-run] Would probe 172.20.10.1 for up to 30s, reverting to DHCP if nothing answers"
            elif [[ "$_no_prompt" -eq 1 || ! -t 0 ]]; then
                echo "Prompting disabled - skipping iOS hotspot manual-IP fallback (run set-socks-proxy directly in a terminal to use it)"
                _clat_declined=1
            elif read -q "?Switch Wi-Fi to manual 172.20.10.0/28 to try the iOS hotspot fallback (172.20.10.1)? [y/N] "; then
                echo
                _clat_consented=1
            else
                echo
                _clat_declined=1
            fi
        fi

        # Retried every --wait round once consented - no re-prompting, since the user
        # already said yes once. Only actually switch once (guarded by
        # SOCKS_ADHOC_APPLIED); after that the outer loop's own probe above keeps
        # hitting 172.20.10.1 directly every round, so no repeated sudo/flapping.
        if [[ "$_clat_consented" -eq 1 && "$_clat_declined" -eq 0 && "$SOCKS_ADHOC_APPLIED" != "1" ]]; then
            echo "Switching Wi-Fi IPv4 to manual: 172.20.10.5 (router 172.20.10.1)"
            sudo networksetup -setmanual Wi-Fi 172.20.10.5 255.255.255.240 172.20.10.1
            sudo networksetup -setdnsservers Wi-Fi 172.20.10.1
            export SOCKS_ROUTER_IP="172.20.10.1"
            export SOCKS_ADHOC_APPLIED=1

            local _clat_try
            for _clat_try in {1..10}; do
                for _port in "${_ports_to_try[@]}"; do
                    echo "Probing $SOCKS_ROUTER_IP:$_port ..."
                    if nc -z -w 1 "$SOCKS_ROUTER_IP" "$_port" 2>/dev/null; then
                        echo "  open"
                        export SOCKS_ROUTER_PROXY_PORT="$_port"
                        _port_confirmed=1
                        break
                    else
                        echo "  closed/unreachable"
                    fi
                done
                [[ "$_port_confirmed" -eq 1 ]] && break
                echo "Waiting for SOCKS proxy at 172.20.10.1 ($_clat_try/10, retrying in 3s)..."
                sleep 3
            done

            # --wait means keep polling indefinitely rather than flap manual->DHCP->manual
            # every ~35s (each -setdhcp/-setmanual round trip re-triggers a DHCP renewal
            # and eventually exhausts the sudo timestamp mid-loop). Without --wait, this
            # is the one shot, so revert on timeout as before.
            if [[ "$_port_confirmed" -ne 1 && "$_wait" -eq 0 ]]; then
                echo "Timed out waiting for SOCKS proxy at 172.20.10.1 - reverting to DHCP" >&2
                sudo networksetup -setdhcp Wi-Fi
                sudo networksetup -setdnsservers Wi-Fi "Empty"
                unset SOCKS_ADHOC_APPLIED
                export SOCKS_ROUTER_IP="$_original_router_ip"
            fi
        fi

        [[ "$_port_confirmed" -eq 1 ]] && break
        if [[ "$_wait" -eq 0 ]]; then
            echo "Error: no SOCKS proxy found on $SOCKS_ROUTER_IP (tried ports: ${_ports_to_try[*]})" >&2
            unset SOCKS_ROUTER_PROXY_PORT
            return 1
        fi
        echo "Attempt $_attempt: nothing open yet, retrying in 3s... (Ctrl-C to stop)"
        sleep 3
    done

    # --adhoc: for ad-hoc/no-DHCP networks, macOS can flag the interface as
    # unreachable and drop the SOCKS route - self-as-router+DNS works around it.
    # Opt-in only: real Personal Hotspot / Android hotspot already get valid DHCP,
    # so this isn't needed (or safe to assume) for those. See
    # https://github.com/nneonneo/iOS-SOCKS-Server/issues/1#issuecomment-583989079
    if [[ "$_adhoc" -eq 1 && "$SOCKS_ADHOC_APPLIED" != "1" ]]; then
        local _wifi_iface
        _wifi_iface=$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi/{found=1} found && /Device:/{print $2; exit}')
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
            export SOCKS_ADHOC_APPLIED=1
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
    if [[ "$SOCKS_ADHOC_APPLIED" == "1" ]]; then
        echo "Note: Wi-Fi IPv4 is manually pinned for this hotspot - run unset-socks-proxy before joining another network"
    fi

    # Replace any previous watchdog - unless we ARE the watchdog (this call
    # came from _socks-proxy-watchdog's own recovery loop re-applying the
    # proxy; it keeps polling in its existing loop, no nested poller needed,
    # and SOCKS_WATCHDOG_PID here would equal our own $$, so killing it would
    # kill ourselves mid-recovery).
    if [[ "$SOCKS_WATCHDOG_PID" != "$$" ]]; then
        if [[ -n "$SOCKS_WATCHDOG_PID" ]] && kill -0 "$SOCKS_WATCHDOG_PID" 2>/dev/null; then
            kill "$SOCKS_WATCHDOG_PID" 2>/dev/null
        fi
        local _watchdog_iface _watchdog_ssid
        _watchdog_iface=$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi/{found=1} found && /Device:/{print $2; exit}')
        _watchdog_ssid=$(networksetup -getairportnetwork "${_watchdog_iface:-en0}" 2>/dev/null | sed 's/^Current Wi-Fi Network: //')
        _socks-proxy-watchdog "$_watchdog_ssid" "$SOCKS_ROUTER_IP" "$SOCKS_ROUTER_PROXY_PORT" "${_watchdog_iface:-en0}" &!
        export SOCKS_WATCHDOG_PID=$!
    fi
}

# Internal: background poller spawned by set-socks-proxy. The system SOCKS
# proxy setting is treated as semi-permanent - a bare outage (phone app
# relaunching, hotspot hiccup) shouldn't tear it down, so the system proxy
# state is left untouched for up to 60s (12 x 5s) while the SAME ip:port is
# re-probed; only if it never comes back is unset-socks-proxy actually called.
# A confirmed SSID change is different - that means we're provably on another
# network already, so it unsets immediately, no grace period. Runs in a
# forked subshell (&!) - real OS state (networksetup calls inside
# unset-socks-proxy) is what actually reverts; shell-var changes made in here
# don't propagate back to the parent shell that spawned it.
_socks-proxy-watchdog(){
    local _ssid="$1" _ip="$2" _port="$3" _iface="$4"
    local _cur_ssid
    while true; do
        sleep 5
        # networksetup prints its own failures on STDOUT and exits non-zero ("en0 is not a
        # Wi-Fi interface.", "You are not associated with an AirPort network."), and the
        # pipeline threw that status away - so an unreadable reading compared unequal and
        # tripped the no-grace-period teardown below. Unreadable is not a *confirmed* move
        # to another network: treat it as unchanged and let the port probe decide.
        _cur_ssid=$(networksetup -getairportnetwork "$_iface" 2>/dev/null)
        if [[ "$_cur_ssid" == "Current Wi-Fi Network: "* ]]; then
            _cur_ssid="${_cur_ssid#Current Wi-Fi Network: }"
        else
            _cur_ssid="$_ssid"
        fi
        if [[ "$_cur_ssid" != "$_ssid" ]]; then
            echo "socks-proxy-watchdog: Wi-Fi changed ($_ssid -> $_cur_ssid), unsetting SOCKS proxy" >&2
            unset-socks-proxy
            return 0
        fi
        nc -z -w 2 "$_ip" "$_port" 2>/dev/null && continue

        echo "socks-proxy-watchdog: SOCKS proxy $_ip:$_port unreachable, tolerating outage up to 60s (leaving proxy setting on)" >&2
        local _recovered=0 _try
        for ((_try = 1; _try <= 12; _try++)); do
            sleep 5
            # networksetup prints its own failures on STDOUT and exits non-zero ("en0 is not a
            # Wi-Fi interface.", "You are not associated with an AirPort network."), and the
            # pipeline threw that status away - so an unreadable reading compared unequal and
            # tripped the no-grace-period teardown below. Unreadable is not a *confirmed* move
            # to another network: treat it as unchanged and let the port probe decide.
            _cur_ssid=$(networksetup -getairportnetwork "$_iface" 2>/dev/null)
            if [[ "$_cur_ssid" == "Current Wi-Fi Network: "* ]]; then
                _cur_ssid="${_cur_ssid#Current Wi-Fi Network: }"
            else
                _cur_ssid="$_ssid"
            fi
            if [[ "$_cur_ssid" != "$_ssid" ]]; then
                echo "socks-proxy-watchdog: Wi-Fi changed ($_ssid -> $_cur_ssid), unsetting SOCKS proxy" >&2
                unset-socks-proxy
                return 0
            fi
            if nc -z -w 2 "$_ip" "$_port" 2>/dev/null; then
                echo "socks-proxy-watchdog: $_ip:$_port back, resuming normal monitoring" >&2
                _recovered=1
                break
            fi
        done
        if [[ "$_recovered" -eq 0 ]]; then
            echo "socks-proxy-watchdog: $_ip:$_port still unreachable after 60s, unsetting SOCKS proxy" >&2
            unset-socks-proxy
            return 0
        fi
    done
}

# Usage: test-socks-proxy [<ip>] [<port>]
# Description: Verify the SOCKS proxy is actually reachable and proxying, via a real
#   curl request through it (not just a port probe). Defaults to $SOCKS_ROUTER_IP /
#   $SOCKS_ROUTER_PROXY_PORT as set by set-socks-proxy. Brackets IPv6 addresses (with
#   or without a %zone) since curl's host:port syntax would otherwise collide with
#   the address's own colons.
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
    local _socks5_target="$_ip:$_port"
    # IPv6 (with or without a %zone) needs bracketing so curl doesn't mistake its
    # colons for the host:port separator.
    [[ "$_ip" == *:* ]] && _socks5_target="[$_ip]:$_port"
    if curl --silent --show-error --connect-timeout 5 --socks5 "$_socks5_target" http://www.google.com -o /dev/null; then
        echo "  OK: $_ip:$_port reachable and proxying"
        return 0
    else
        echo "  FAIL: $_ip:$_port not reachable or not proxying" >&2
        return 1
    fi
}

# Usage: unset-socks-proxy
# Description: Turns off the SOCKS proxy set by set-socks-proxy. Also reverts the
#   manual IPv4/DNS config from the 172.20.10.1 CLAT fallback (or --adhoc) back to
#   DHCP - checked both via the SOCKS_ADHOC_APPLIED env flag (same shell) and the
#   actual interface state (router == 172.20.10.1, so it also works from a fresh
#   terminal after the flag's gone) without touching an unrelated static-IP config
#   you may have set up yourself on some other network.
unset-socks-proxy(){
    if [[ "$OSTYPE" != darwin* ]]; then
        echo "Error: unset-socks-proxy is only supported on macOS" >&2
        return 1
    fi
    # Stop the watchdog too, unless we ARE the watchdog (it calls this function
    # directly, not via a new fork, so its own PID equals SOCKS_WATCHDOG_PID -
    # killing "ourselves" here would abort this function before it finishes).
    if [[ -n "$SOCKS_WATCHDOG_PID" && "$SOCKS_WATCHDOG_PID" != "$$" ]] && kill -0 "$SOCKS_WATCHDOG_PID" 2>/dev/null; then
        kill "$SOCKS_WATCHDOG_PID" 2>/dev/null
        unset SOCKS_WATCHDOG_PID
    fi
    networksetup -setsocksfirewallproxystate Wi-Fi off
    # Only auto-revert manual IPv4 config recognized as our own (router 172.20.10.1,
    # the CLAT fallback's signature) - don't blindly wipe a user's own unrelated
    # static IP config on some other network just because Wi-Fi happens to be manual.
    local _wifi_info _manual_router
    _wifi_info=$(networksetup -getinfo Wi-Fi)
    if grep -q "^Manual Configuration" <<< "$_wifi_info"; then
        _manual_router=$(grep -e "^Router" <<< "$_wifi_info" | cut -d " " -f 2)
    fi
    if [[ "$SOCKS_ADHOC_APPLIED" == "1" || "$_manual_router" == "172.20.10.1" ]]; then
        echo "Reverting Wi-Fi IPv4/DNS to DHCP"
        sudo networksetup -setdhcp Wi-Fi
        sudo networksetup -setdnsservers Wi-Fi "Empty"
        unset SOCKS_ADHOC_APPLIED
    fi
}

# Usage: get-socks-proxy
# Description: Prints the currently configured SOCKS proxy address/port plus example
#   invocations for curl/ssh/git/ALL_PROXY. Useful because the macOS system-wide SOCKS
#   proxy set-socks-proxy configures only covers CFNetwork-based apps (Safari, Mail,
#   ...) - CLI tools ignore it entirely, so this is what to paste manually for those.
get-socks-proxy(){
    if [[ "$OSTYPE" != darwin* ]]; then
        echo "Error: get-socks-proxy is only supported on macOS" >&2
        return 1
    fi
    local router_ip="${SOCKS_ROUTER_IP}"
    local proxy_port="${SOCKS_ROUTER_PROXY_PORT}"
    # SOCKS_ROUTER_IP/PORT only exist in the shell that ran set-socks-proxy, and the
    # auto-invoke block below runs it under `&!` - so its exports die with that forked
    # subshell and a fresh terminal has neither. Read what is actually configured on
    # the interface before falling back to guessing the Wi-Fi router, which is wrong
    # whenever the proxy is the IPv6 candidate or on a non-1888 port.
    if [[ -z "$router_ip" ]]; then
        local _configured _reported_port
        _configured=$(networksetup -getsocksfirewallproxy Wi-Fi 2>/dev/null)
        router_ip=$(awk '/^Server: /{print $2; exit}' <<< "$_configured")
        # Only trust the reported port when a server came with it: an unconfigured
        # proxy reports "Server: " plus "Port: 0", and 0 would otherwise stick (it is
        # non-empty, so the :=1888 default below would not replace it).
        if [[ -n "$router_ip" && -z "$proxy_port" ]]; then
            _reported_port=$(awk '/^Port: /{print $2; exit}' <<< "$_configured")
            [[ "$_reported_port" != 0 ]] && proxy_port="$_reported_port"
        fi
    fi
    if [[ -z "$router_ip" ]]; then
        router_ip=$(networksetup -getinfo Wi-Fi | grep -e "^Router" | cut -d " " -f 2)
    fi
    : "${proxy_port:=1888}"

    # IPv6 (with or without a %zone) needs bracketing anywhere it's followed by a
    # port - same collision test-socks-proxy already guards against for its curl
    # call. Verified empirically (see git blame / commit adding this comment): curl
    # refuses to even parse an unbracketed zone-scoped address ("Unsupported proxy
    # syntax"), but once bracketed it accepts a raw %zone just fine - RFC 6874's
    # %25-escaped form is not required in practice for curl, only for strict URI
    # parsers that don't share curl's leniency.
    local _bracketed_ip="$router_ip"
    [[ "$router_ip" == *:* ]] && _bracketed_ip="[$router_ip]"

    # curl does not error on a bad/stale %zone - an invalid zone id fails
    # identically to a dead proxy (same "Failed to connect... Couldn't
    # connect to server" either way, confirmed empirically), so a literal
    # left over from a rotated Private Wi-Fi Address (see set-socks-proxy's
    # comments) would just look like the SOCKS server is down, not like a
    # stale address. Catch the distinguishable case - zone names a live
    # interface at all - before printing copy-paste commands built on it.
    if [[ "$router_ip" == *%* ]]; then
        local _zone="${router_ip##*%}"
        if ! ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -qx "$_zone"; then
            echo "Warning: zone '%${_zone}' in $router_ip is not a current interface -" >&2
            echo "  likely stale (rotated Private Wi-Fi Address?). Re-run set-socks-proxy" >&2
            echo "  to rediscover the address before using the commands below." >&2
        fi
    fi

    echo "SOCKS Proxy: ${_bracketed_ip}:${proxy_port}"
    echo ""
    echo "Usage in other applications:"
    echo "  curl:        curl --socks5 ${_bracketed_ip}:${proxy_port} https://example.com"
    echo "  SSH config:  ProxyCommand nc -X 5 -x ${_bracketed_ip}:${proxy_port} %h %p"
    if [[ "$router_ip" == *:* ]]; then
        echo "               (macOS nc's -x flag can't take an IPv6 address in this"
        echo "               combined host:port form at all - confirmed even a plain"
        echo "               bracketed, non-zone address fails identically - this"
        echo "               ProxyCommand will NOT work for any IPv6 proxy address)"
    fi
    echo "  Environment: export ALL_PROXY=socks5://${_bracketed_ip}:${proxy_port}"
    echo "  Git:         git config --global http.proxy socks5://${_bracketed_ip}:${proxy_port}"
}

# Wi-Fi and network-related setup - cache network name
if [[ "$TERM_PROGRAM" != "vscode" ]]; then
  # Detect WiFi interface dynamically (consistent with set-tf-proxy and other functions)
  _WIFI_IFACE=$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi/{found=1} found && /Device:/{print $2; exit}')
  # Get WiFi name once and cache it
  WIFI_NAME=$(networksetup -getairportnetwork "${_WIFI_IFACE:-en0}" 2>/dev/null | sed 's/^Current Wi-Fi Network: //')
  unset _WIFI_IFACE

  # Run home setup check in background
  (is-at-home && (is-displaylink-connected || restart-displaylink)) &!

  # Handle proxy setup based on network
  if [[ "$WIFI_NAME" = "PASSAWIT's Z Fold7" ]]; then
        set-socks-proxy --no-prompt &!
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
    pids=$(ps aux | awk '/\/Messenger\.app\/|Acrobat|Fathom|Todoist|LINE/ {print $2}')
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
