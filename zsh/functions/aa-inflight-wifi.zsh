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

    echo "Starting AA Inflight WiFi automation..."
    echo "This will randomize your MAC address every 20 minutes for free WiFi"
    echo "Press Ctrl+C to stop"

    # Function to check if we're connected to the right network
    check_ssid() {
        local current_ssid=$(networksetup -getairportnetwork en0 2>/dev/null | awk -F': ' '{print $2}')
        [[ "$current_ssid" == "$SSID" ]]
    }

    # Function to check internet connectivity
    check_internet() {
        # Try multiple methods to check connectivity
        curl -s --max-time 5 --head http://www.google.com > /dev/null 2>&1 || \
        ping -c 1 -t 5 8.8.8.8 > /dev/null 2>&1
    }

    # Function to randomize MAC and reconnect
    reconnect_wifi() {
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Randomizing MAC address..."

        # Randomize MAC (spoof-mac handles WiFi off/on automatically)
        # sudo networksetup -setairportpower en0 off  # Not needed, spoof-mac handles this
        sudo spoof-mac randomize wi-fi

        # Small delay for WiFi to reconnect after MAC change
        sleep 2

        # Ensure WiFi is back on (in case spoof-mac didn't turn it back on)
        # sudo networksetup -setairportpower en0 on  # Usually not needed

        # Wait for WiFi to come back up
        echo "Waiting for WiFi to reconnect..."
        local attempts=0
        while ! check_ssid && [[ $attempts -lt $MAX_ATTEMPTS ]]; do
            sleep $CHECK_INTERVAL
            ((attempts++))
            echo -n "."
        done
        echo

        if ! check_ssid; then
            echo "Failed to reconnect to $SSID. Please reconnect manually."
            return 1
        fi

        echo "Reconnected to $SSID"

        # Open the WiFi login page
        echo "Opening WiFi login page..."
        open "$WIFI_URL"

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
        if ! check_ssid; then
            echo "Not connected to $SSID network. Please connect first."
            echo "Waiting for connection to $SSID..."
            while ! check_ssid; do
                sleep $CHECK_INTERVAL
            done
        fi

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