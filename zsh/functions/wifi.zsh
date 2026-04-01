# Description: WiFi standard detection utility

if [[ "$TERM_PROGRAM" != "vscode" ]]; then

# Get the current WiFi standard (Wi-Fi 5, 6, 6E, 7)
# Usage: wifi-standard
function wifi-standard() {
    # Debug: uncomment to see when function is called
    echo "DEBUG: wifi-standard function called" >&2
    local wifi_info=$(system_profiler SPAirPortDataType 2>/dev/null)

    # Check if WiFi is connected by looking for "Status: Connected"
    if [[ -z "$wifi_info" || ! "$wifi_info" =~ "Status: Connected" ]]; then
        echo "Not connected to WiFi"
        return 1
    fi

    # Extract PHY mode which contains the standard information
    # Look for PHY Mode under Current Network Information section
    local phy_mode=$(echo "$wifi_info" | grep -A 20 "Current Network Information:" | grep -i "PHY Mode:" | head -1 | awk -F': ' '{print $2}')

    # Extract channel information to check for 6 GHz band
    local channel_info=$(echo "$wifi_info" | grep -A 20 "Current Network Information:" | grep -i "Channel:" | head -1)

    # Map PHY mode to user-friendly WiFi standard names
    case "$phy_mode" in
        *802.11ax*)
            # Check for 6 GHz band which would indicate Wi-Fi 6E
            if [[ "$channel_info" =~ "6GHz" || "$channel_info" =~ "6 GHz" ]]; then
                echo "Wi-Fi 6E (802.11ax, 6 GHz)"
            else
                echo "Wi-Fi 6 (802.11ax)"
            fi
            ;;
        *802.11be*)
            echo "Wi-Fi 7 (802.11be)"
            ;;
        *802.11ac*)
            echo "Wi-Fi 5 (802.11ac)"
            ;;
        *802.11n*)
            echo "Wi-Fi 4 (802.11n)"
            ;;
        *802.11a*)
            echo "Wi-Fi 2 (802.11a)"
            ;;
        *802.11g*)
            echo "Wi-Fi 3 (802.11g)"
            ;;
        *802.11b*)
            echo "Wi-Fi 1 (802.11b)"
            ;;
        *)
            # If we can't determine the standard, show the raw PHY mode
            if [[ -n "$phy_mode" ]]; then
                echo "WiFi standard: $phy_mode"
            else
                echo "Unknown WiFi standard"
            fi
            ;;
    esac
}

fi
