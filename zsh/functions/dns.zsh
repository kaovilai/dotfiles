# Description: DNS server management utilities

# Set DNS servers for IPv4 and/or IPv6
# Usage: set-dns-servers [--ipv4 "8.8.8.8 8.8.4.4"] [--ipv6 "2001:4860:4860::8888 2001:4860:4860::8844"] [--service "Wi-Fi"]
set-dns-servers() {
    local ipv4_servers=""
    local ipv6_servers=""
    local service="Wi-Fi"  # Default network service

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ipv4)
                ipv4_servers="$2"
                shift 2
                ;;
            --ipv6)
                ipv6_servers="$2"
                shift 2
                ;;
            --service)
                service="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: set-dns-servers [options]"
                echo "Options:"
                echo "  --ipv4 \"server1 server2\"    Set IPv4 DNS servers (space-separated)"
                echo "  --ipv6 \"server1 server2\"    Set IPv6 DNS servers (space-separated)"
                echo "  --service \"name\"            Network service name (default: Wi-Fi)"
                echo "  --help, -h                  Show this help message"
                echo ""
                echo "Examples:"
                echo "  # Set Google DNS for IPv4"
                echo "  set-dns-servers --ipv4 \"8.8.8.8 8.8.4.4\""
                echo ""
                echo "  # Set Cloudflare DNS for both IPv4 and IPv6"
                echo "  set-dns-servers --ipv4 \"1.1.1.1 1.0.0.1\" --ipv6 \"2606:4700:4700::1111 2606:4700:4700::1001\""
                echo ""
                echo "  # Set DNS for Ethernet instead of Wi-Fi"
                echo "  set-dns-servers --ipv4 \"8.8.8.8\" --service \"Ethernet\""
                echo ""
                echo "Common DNS servers:"
                echo "  Google:     IPv4: 8.8.8.8, 8.8.4.4"
                echo "              IPv6: 2001:4860:4860::8888, 2001:4860:4860::8844"
                echo "  Cloudflare: IPv4: 1.1.1.1, 1.0.0.1"
                echo "              IPv6: 2606:4700:4700::1111, 2606:4700:4700::1001"
                echo "  Quad9:      IPv4: 9.9.9.9, 149.112.112.112"
                echo "              IPv6: 2620:fe::fe, 2620:fe::9"
                echo "  OpenDNS:    IPv4: 208.67.222.222, 208.67.220.220"
                echo "              IPv6: 2620:119:35::35, 2620:119:53::53"
                return 0
                ;;
            *)
                echo "Unknown option: $1"
                echo "Use --help for usage information"
                return 1
                ;;
        esac
    done

    # Check if at least one DNS server type is specified
    if [[ -z "$ipv4_servers" && -z "$ipv6_servers" ]]; then
        echo "Error: No DNS servers specified"
        echo "Use --ipv4 and/or --ipv6 to specify DNS servers"
        echo "Use --help for more information"
        return 1
    fi

    # Validate IPv4 address format
    if [[ -n "$ipv4_servers" ]]; then
        for ip in ${=ipv4_servers}; do
            if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                echo "Error: Invalid IPv4 address format: $ip"
                return 1
            fi
        done
    fi

    # Validate IPv6 address format
    if [[ -n "$ipv6_servers" ]]; then
        for ip in ${=ipv6_servers}; do
            if [[ ! "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
                echo "Error: Invalid IPv6 address format: $ip"
                return 1
            fi
        done
    fi

    # Check if running on macOS
    if [[ "$(uname)" != "Darwin" ]]; then
        echo "Error: This function is only supported on macOS"
        return 1
    fi

    # Verify the network service exists
    if ! networksetup -listallnetworkservices | grep -q "^$service$"; then
        echo "Error: Network service '$service' not found"
        echo "Available network services:"
        networksetup -listallnetworkservices | grep -v "^An asterisk"
        return 1
    fi

    # Set IPv4 DNS servers
    if [[ -n "$ipv4_servers" ]]; then
        echo "Setting IPv4 DNS servers for $service: $ipv4_servers"
        if sudo networksetup -setdnsservers "$service" $ipv4_servers; then
            echo "✓ IPv4 DNS servers set successfully"
        else
            echo "✗ Failed to set IPv4 DNS servers"
            return 1
        fi
    fi

    # Set IPv6 DNS servers (macOS doesn't have a direct command, use scutil)
    if [[ -n "$ipv6_servers" ]]; then
        echo "Setting IPv6 DNS servers for $service: $ipv6_servers"

        # Convert space-separated string to array
        local ipv6_array=($ipv6_servers)

        # Create the scutil commands
        local scutil_commands="open\n"
        scutil_commands+="d.init\n"

        # Add each IPv6 DNS server
        for ((i=0; i<${#ipv6_array[@]}; i++)); do
            scutil_commands+="d.add ServerAddresses * ${ipv6_array[$i]}\n"
        done

        scutil_commands+="set State:/Network/Service/IPv6/DNS\n"
        scutil_commands+="quit\n"

        # Apply the IPv6 DNS settings
        if echo -e "$scutil_commands" | sudo scutil; then
            echo "✓ IPv6 DNS servers set successfully"
        else
            echo "Note: IPv6 DNS setting requires manual configuration"
            echo "You can set them in System Preferences > Network > $service > Advanced > DNS"
        fi
    fi

    # Display current DNS settings
    echo ""
    echo "Current DNS configuration for $service:"
    echo "IPv4 DNS servers:"
    networksetup -getdnsservers "$service"
}

# Clear DNS servers to use network defaults (DHCP)
# Usage: clear-dns-servers [--service "Wi-Fi"]
clear-dns-servers() {
    local service="Wi-Fi"  # Default network service

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --service)
                service="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: clear-dns-servers [options]"
                echo "Options:"
                echo "  --service \"name\"    Network service name (default: Wi-Fi)"
                echo "  --help, -h          Show this help message"
                echo ""
                echo "This will clear custom DNS servers and use network defaults (DHCP)"
                echo ""
                echo "Examples:"
                echo "  # Clear DNS for Wi-Fi (use DHCP)"
                echo "  clear-dns-servers"
                echo ""
                echo "  # Clear DNS for Ethernet"
                echo "  clear-dns-servers --service \"Ethernet\""
                return 0
                ;;
            *)
                echo "Unknown option: $1"
                echo "Use --help for usage information"
                return 1
                ;;
        esac
    done

    # Check if running on macOS
    if [[ "$(uname)" != "Darwin" ]]; then
        echo "Error: This function is only supported on macOS"
        return 1
    fi

    # Verify the network service exists
    if ! networksetup -listallnetworkservices | grep -q "^$service$"; then
        echo "Error: Network service '$service' not found"
        echo "Available network services:"
        networksetup -listallnetworkservices | grep -v "^An asterisk"
        return 1
    fi

    echo "Clearing DNS servers for $service (reverting to network defaults)..."

    # Clear DNS servers (empty means use DHCP)
    if sudo networksetup -setdnsservers "$service" "Empty"; then
        echo "✓ DNS servers cleared successfully"
        echo "The system will now use DNS servers provided by DHCP"
    else
        echo "✗ Failed to clear DNS servers"
        return 1
    fi

    # Display current DNS settings
    echo ""
    echo "Current DNS configuration for $service:"
    networksetup -getdnsservers "$service"
}
