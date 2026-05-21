#!/usr/bin/env zsh
# MAC address randomization using ifconfig method
# More reliable than spoof-mac on newer macOS/Apple Silicon (M4)

randomize-mac-ifconfig() {
    if [[ "$OSTYPE" != darwin* ]]; then
        echo "Error: randomize-mac-ifconfig is only supported on macOS" >&2
        return 1
    fi

    local network_ssid=""
    local wifi_interface=""
    local quiet=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --network)
                network_ssid="$2"
                shift 2
                ;;
            --interface)
                wifi_interface="$2"
                shift 2
                ;;
            --quiet)
                quiet=true
                shift
                ;;
            --help|-h)
                echo "Usage: randomize-mac-ifconfig [OPTIONS]"
                echo "Options:"
                echo "  --network SSID    Forget this network before randomizing"
                echo "  --interface DEV   Use specific interface (default: auto-detect)"
                echo "  --quiet          Suppress output"
                echo "  --help           Show this help message"
                return 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                echo "Use --help for usage information" >&2
                return 1
                ;;
        esac
    done

    # Detect WiFi interface if not specified
    if [[ -z "$wifi_interface" ]]; then
        wifi_interface=$(networksetup -listallhardwareports | grep -A 1 "Wi-Fi" | grep "Device:" | awk '{print $2}')
        if [[ -z "$wifi_interface" ]]; then
            echo "Error: Could not detect WiFi interface" >&2
            echo "Try specifying it manually with --interface" >&2
            return 1
        fi
    fi

    [[ "$quiet" == false ]] && echo "Using WiFi interface: $wifi_interface"

    # Forget network if specified (for AA inflight WiFi case)
    if [[ -n "$network_ssid" ]]; then
        [[ "$quiet" == false ]] && echo "Forgetting network: $network_ssid"
        sudo networksetup -removepreferredwirelessnetwork "$wifi_interface" "$network_ssid" 2>/dev/null || true
    fi

    # Bring interface up first (important for M4 chips)
    sudo ifconfig "$wifi_interface" up

    # Get current MAC address
    local current_mac
    current_mac=$(ifconfig "$wifi_interface" | grep ether | awk '{print $2}')
    if [[ -z "$current_mac" ]]; then
        echo "Error: Could not read current MAC address" >&2
        return 1
    fi

    [[ "$quiet" == false ]] && echo "Current MAC: $current_mac"

    # Set MAC to itself first (primes the interface - critical for M4)
    sudo ifconfig "$wifi_interface" ether "$current_mac"

    # Generate new MAC by changing the last digit randomly
    # This ensures we're only making a minimal change which is less likely to be rejected
    local last_digit
    last_digit=$(printf '%x' $((RANDOM % 16)))
    local new_mac="${current_mac%?}$last_digit"

    # Ensure we're not setting it to the same MAC
    while [[ "$new_mac" == "$current_mac" ]]; do
        last_digit=$(printf '%x' $((RANDOM % 16)))
        new_mac="${current_mac%?}$last_digit"
    done

    [[ "$quiet" == false ]] && echo "New MAC: $new_mac"

    # Set the new MAC address
    sudo ifconfig "$wifi_interface" ether "$new_mac"

    # Small delay to let the change take effect
    sleep 0.5

    # Verify the change
    local actual_mac
    actual_mac=$(ifconfig "$wifi_interface" | grep ether | awk '{print $2}')

    if [[ "$actual_mac" == "$new_mac" ]]; then
        [[ "$quiet" == false ]] && echo "✓ MAC randomized successfully"
        return 0
    else
        echo "✗ MAC randomization may have failed" >&2
        echo "Expected: $new_mac" >&2
        echo "Actual: $actual_mac" >&2
        echo "Note: Some networks may reject certain MAC addresses" >&2
        return 1
    fi
}

# Make the function available as 'randomize-mac-ifconfig'
# Can be called directly or via the 'randomize-mac' alias
