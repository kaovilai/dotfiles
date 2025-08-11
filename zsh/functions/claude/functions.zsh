# Claude settings management functions

# Merge local Claude settings into global config with interactive prompts
znap function merge-claude-settings() {
    local local_settings=".claude/settings.local.json"
    local global_settings="${XDG_CONFIG_HOME:-$HOME/.config}/claude/settings.json"
    
    # Check if local settings file exists in current directory
    if [[ ! -f "$local_settings" ]]; then
        echo "Error: Local settings file not found at $local_settings"
        echo "Make sure you're in a directory with .claude/settings.local.json"
        return 1
    fi
    
    # Check if global settings file exists
    if [[ ! -f "$global_settings" ]]; then
        echo "Error: Global settings file not found at $global_settings"
        echo "Creating directory and empty settings file..."
        mkdir -p "$(dirname "$global_settings")"
        echo '{"permissions": {"allow": [], "deny": []}}' > "$global_settings"
    fi
    
    # Read existing permissions from both files as raw strings (not JSON-encoded)
    local local_allow=$(jq -r '.permissions.allow[]' "$local_settings" 2>/dev/null)
    local global_allow=$(jq -r '.permissions.allow[]' "$global_settings" 2>/dev/null)
    
    # Find new permissions not in global settings
    local new_permissions=()
    while IFS= read -r perm; do
        if [[ -n "$perm" ]] && ! echo "$global_allow" | grep -Fxq -- "$perm"; then
            new_permissions+=("$perm")
        fi
    done <<< "$local_allow"
    
    # If no new permissions found
    if [[ ${#new_permissions[@]} -eq 0 ]]; then
        echo "No new permissions to merge."
        return 0
    fi
    
    echo "Found ${#new_permissions[@]} new permission(s) to merge:"
    echo
    
    # Create backup of global settings before any changes
    local backup_file="${global_settings}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$global_settings" "$backup_file"
    
    # Ask about each new permission and add immediately
    local permissions_added=0
    for perm in "${new_permissions[@]}"; do
        # Permission is already a raw string, no need to decode
        echo -n "Add permission '$perm'? (y/n): "
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            # Add this permission immediately (use --arg for proper string escaping)
            local temp_file=$(mktemp)
            jq --arg new_perm "$perm" '
                .permissions.allow += [$new_perm]
                | .permissions.allow |= unique
            ' "$global_settings" > "$temp_file"
            
            if [[ $? -eq 0 ]]; then
                mv "$temp_file" "$global_settings"
                ((permissions_added++))
                echo "  ✓ Added"
            else
                echo "  ✗ Failed to add permission"
                rm -f "$temp_file"
            fi
        fi
    done
    
    # If user didn't approve any permissions
    if [[ $permissions_added -eq 0 ]]; then
        echo "No permissions were added."
        rm -f "$backup_file"  # Remove unused backup
        return 0
    fi
    
    echo
    echo "Successfully added $permissions_added permission(s) to $global_settings"
    echo "A backup was created at $backup_file"
}