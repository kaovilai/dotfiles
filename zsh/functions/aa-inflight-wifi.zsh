#!/usr/bin/env zsh
# AA Inflight WiFi automation function
# Randomizes MAC address every 20 minutes to get free WiFi on American Airlines flights

# Function to handle AA inflight WiFi reconnection
aa-inflight-wifi() {
    local SSID="aainflight.com"
    local WIFI_URL="https://www.aainflight.com/wifi/free"
    local WAIT_TIME=$((20 * 60))  # 20 minutes in seconds
    local CHECK_INTERVAL=5
    local MAX_ATTEMPTS=60  # Max attempts to reconnect (5 min timeout)

    # Detect WiFi interface dynamically
    local wifi_interface=$(networksetup -listallhardwareports | grep -A 1 "Wi-Fi" | grep "Device:" | awk '{print $2}')
    if [[ -z "$wifi_interface" ]]; then
        echo "Error: Could not detect WiFi interface"
        return 1
    fi

    echo "Starting AA Inflight WiFi automation..."
    echo "This will randomize your MAC address every 20 minutes for free WiFi"
    echo "Press Ctrl+C to stop"

    # This func only work if wifi has internet already.
    # # Function to check if we're connected to the right network
    # check_ssid() {
    #     local current_ssid=$(networksetup -getairportnetwork en0 2>/dev/null | awk -F': ' '{print $2}')
    #     [[ "$current_ssid" == "$SSID" ]]
    # }

    # Function to check internet connectivity
    check_internet() {
        # Try multiple methods to check connectivity
        curl -s --max-time 5 --head http://www.google.com > /dev/null 2>&1 || \
        ping -c 1 -t 5 8.8.8.8 > /dev/null 2>&1
    }

    # Function to randomize MAC and reconnect
    reconnect_wifi() {
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Randomizing MAC address..."

        # Source the MAC randomization function if not already loaded
        if ! command -v randomize-mac-ifconfig &>/dev/null; then
            source ~/git/dotfiles/zsh/functions/randomize-mac.zsh
        fi

        # Use the new MAC randomization function with network forgetting
        # This will forget the network and randomize the MAC in one operation
        randomize-mac-ifconfig --network "$SSID" --interface "$wifi_interface"

        # Small delay to let the interface stabilize
        sleep 2

        # Turn WiFi back on (in case it was turned off)
        sudo networksetup -setairportpower "$wifi_interface" on

        # Wait for WiFi interface to be ready
        echo "Waiting for WiFi interface to be ready..."
        sleep 3

        # Try to connect to the network
        echo "Attempting to connect to $SSID..."
        sudo networksetup -setairportnetwork "$wifi_interface" "$SSID" 2>/dev/null || true

        sleep 2

        # Open the WiFi login page
        echo "Opening WiFi login page..."
        open "$WIFI_URL"

        # # Wait for connection
        # echo "Waiting for connection to $SSID..."
        # local attempts=0
        # while ! check_ssid && [[ $attempts -lt $MAX_ATTEMPTS ]]; do
        #     sleep $CHECK_INTERVAL
        #     ((attempts++))
        #     echo -n "."

        #     # # Try to connect again every 10 attempts
        #     # if [[ $((attempts % 10)) -eq 0 ]]; then
        #     #     echo
        #     #     echo "Retrying connection to $SSID..."
        #     #     sudo networksetup -setairportnetwork en0 "$SSID" 2>/dev/null || true
        #     # fi
        # done
        # echo

        # if ! check_ssid; then
        #     echo "Failed to connect to $SSID. Please connect manually."
        #     echo "You may need to manually select the network from WiFi menu."
        #     return 1
        # fi

        # echo "Connected to $SSID"

        # Wait for internet to become available
        echo "Waiting for internet connection (complete the login in your browser)..."
        attempts=0
        while ! check_internet && [[ $attempts -lt $MAX_ATTEMPTS ]]; do
            sleep $CHECK_INTERVAL
            ((attempts++))
            echo -n "."
        done
        echo

        if check_internet; then
            echo "Internet connection established!"
            return 0
        else
            echo "Failed to establish internet connection. Please check the login page."
            return 1
        fi
    }

    # Main loop
    while true; do
        # Check if we're on the AA inflight network
        # if ! check_ssid; then
        #     echo "Not connected to $SSID network. Please connect first."
        #     echo "Waiting for connection to $SSID..."
        #     while ! check_ssid; do
        #         sleep $CHECK_INTERVAL
        #     done
        # fi

        # Perform the reconnection
        if reconnect_wifi; then
            # Success - wait 20 minutes before next cycle
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Waiting 20 minutes before next reconnection..."
            echo "Next reconnection at: $(date -v +${WAIT_TIME}S '+%Y-%m-%d %H:%M:%S')"
            sleep $WAIT_TIME
        else
            # Failed - wait a bit before retrying
            echo "Reconnection failed. Retrying in 30 seconds..."
            sleep 30
        fi
    done
}

# Alias for convenience
alias aawifi='aa-inflight-wifi'
