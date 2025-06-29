# Retry wrapper for ccoctl azure commands to handle eventual consistency issues
# This addresses the Azure equivalent of OCPBUGS-44933 (which only fixed GCP)
# Also handles role assignment timeouts that occur due to replication delays

retry_ccoctl_azure() {
    local max_retries=5
    local retry_count=0
    local wait_time=5
    local exponential_factor=2
    
    # Check if this is likely to be a role assignment error and increase retries
    if [[ "$*" =~ "create-all" ]]; then
        # Role assignment errors typically need more retries
        max_retries=10
        echo "INFO: Using extended retry count ($max_retries) for create-all operation"
    fi
    
    # Execute the command and capture both stdout and stderr
    local cmd_output
    local cmd_exit_code
    
    while [[ $retry_count -lt $max_retries ]]; do
        echo "INFO: Executing ccoctl azure command (attempt $((retry_count + 1))/$max_retries)..."
        echo "DEBUG: Command: ccoctl $*"
        
        # Run the command and capture output
        cmd_output=$(ccoctl "$@" 2>&1)
        cmd_exit_code=$?
        
        # Check if command succeeded
        if [[ $cmd_exit_code -eq 0 ]]; then
            echo "$cmd_output"
            echo "INFO: ccoctl azure command completed successfully"
            return 0
        fi
        
        # Check if error is storage account already exists
        if echo "$cmd_output" | grep -E "StorageAccountAlreadyExists" >/dev/null; then
            echo "WARNING: Storage account already exists. Running destroy to clean up..."
            
            # Extract parameters from the original command to run destroy
            local destroy_args=()
            local i=1
            local skip_next=false
            while [[ $i -le $# ]]; do
                local arg="${(P)i}"
                
                # Skip if we're supposed to skip this argument (it was a value for a skipped flag)
                if [[ "$skip_next" == "true" ]]; then
                    skip_next=false
                    i=$((i + 1))
                    continue
                fi
                
                # Replace create-all with delete
                if [[ "$arg" == "create-all" ]]; then
                    destroy_args+=("delete")
                # Skip flags that are not compatible with delete command
                elif [[ "$arg" == "--tenant-id" || "$arg" == "--installation-resource-group-name" || "$arg" == "--dnszone-resource-group-name" || "$arg" == "--output-dir" || "$arg" == "--credentials-requests-dir" ]]; then
                    # Skip this flag and its value
                    skip_next=true
                else
                    destroy_args+=("$arg")
                fi
                i=$((i + 1))
            done
            
            # Add --delete-oidc-resource-group flag for proper cleanup
            destroy_args+=("--delete-oidc-resource-group")
            
            # Run destroy command
            echo "INFO: Running ccoctl azure destroy to clean up existing resources..."
            echo "DEBUG: Destroy command: ccoctl ${destroy_args[*]}"
            local destroy_output=$(ccoctl "${destroy_args[@]}" 2>&1)
            local destroy_exit_code=$?
            
            if [[ $destroy_exit_code -eq 0 ]]; then
                echo "INFO: Cleanup completed successfully"
            else
                echo "WARNING: Destroy command failed with exit code $destroy_exit_code"
                echo "Destroy output: $destroy_output"
                echo "WARNING: Continuing with retry despite destroy failure"
            fi
            
            # Extract storage account name and derive resource group from the arguments
            local storage_account=""
            local resource_group=""
            local cluster_name=""
            local oidc_resource_group_override=""
            local i=1
            while [[ $i -le $# ]]; do
                local arg="${(P)i}"
                if [[ "$arg" == "--storage-account-name" && $((i + 1)) -le $# ]]; then
                    i=$((i + 1))
                    storage_account="${(P)i}"
                elif [[ "$arg" == "--name" && $((i + 1)) -le $# ]]; then
                    i=$((i + 1))
                    cluster_name="${(P)i}"
                elif [[ "$arg" == "--oidc-resource-group-name" && $((i + 1)) -le $# ]]; then
                    i=$((i + 1))
                    oidc_resource_group_override="${(P)i}"
                fi
                i=$((i + 1))
            done
            
            # Determine the OIDC resource group name
            # Note: The actual pattern seems to vary - could be <name>-oidc or <name>-wif-oidc
            # Let's try to find the storage account in any resource group if the direct lookup fails
            if [[ -n "$oidc_resource_group_override" ]]; then
                resource_group="$oidc_resource_group_override"
            elif [[ -n "$cluster_name" ]]; then
                # CCO creates storage account in OIDC resource group: typically <name>-oidc
                resource_group="${cluster_name}-oidc"
            fi
            
            # Use az CLI to ensure storage account is deleted
            if [[ -n "$storage_account" ]]; then
                echo "INFO: Checking if storage account '$storage_account' still exists..."
                
                # First try with the derived resource group
                if [[ -n "$resource_group" ]]; then
                    echo "DEBUG: Command: az storage account show --name \"$storage_account\" --resource-group \"$resource_group\""
                    if az storage account show --name "$storage_account" --resource-group "$resource_group" &>/dev/null; then
                        echo "INFO: Found storage account in resource group '$resource_group'"
                    else
                        echo "INFO: Storage account not found in expected resource group '$resource_group'"
                        # Try to find it in any resource group
                        echo "INFO: Searching for storage account across all resource groups..."
                        local found_rg=$(az storage account list --query "[?name=='$storage_account'].resourceGroup | [0]" -o tsv 2>/dev/null)
                        if [[ -n "$found_rg" ]]; then
                            echo "INFO: Found storage account in resource group '$found_rg'"
                            resource_group="$found_rg"
                        else
                            echo "INFO: Storage account does not exist or is already deleted"
                            resource_group=""
                        fi
                    fi
                fi
                
                # Delete the storage account if we found it
                if [[ -n "$resource_group" ]]; then
                    echo "INFO: Deleting storage account '$storage_account' from resource group '$resource_group'..."
                    if az storage account delete --name "$storage_account" --resource-group "$resource_group" --yes &>/dev/null; then
                        echo "INFO: Successfully deleted storage account using az CLI"
                    else
                        echo "WARNING: Failed to delete storage account using az CLI"
                    fi
                fi
            fi
            
            # Wait for Azure resources to be fully cleaned up with exponential backoff
            if [[ -n "$storage_account" ]]; then
                echo "INFO: Waiting for storage account to be fully deleted..."
                local wait_intervals=(2 4 8 16)  # Total max wait: 30 seconds
                local deleted=false
                
                for interval in "${wait_intervals[@]}"; do
                    echo "INFO: Checking if storage account is deleted (waiting ${interval}s)..."
                    sleep $interval
                    
                    # Check if storage account still exists
                    if ! az storage account list --query "[?name=='$storage_account'].name" -o tsv 2>/dev/null | grep -q "$storage_account"; then
                        echo "INFO: Storage account has been deleted successfully"
                        deleted=true
                        break
                    fi
                    echo "INFO: Storage account still exists, continuing to wait..."
                done
                
                if [[ "$deleted" == "false" ]]; then
                    echo "WARNING: Storage account still exists after waiting, proceeding anyway..."
                fi
            else
                # No storage account to check, just wait a bit for other resources
                echo "INFO: Waiting 10 seconds for other Azure resources to be cleaned up..."
                sleep 10
            fi
            
            # Don't increment retry count here - give it another full attempt after cleanup
            echo "INFO: Retrying create command after cleanup (attempt $((retry_count + 1))/$max_retries)..."
            continue
        fi
        
        # Check if error is retryable (Azure eventual consistency issues or role assignment timeouts)
        if echo "$cmd_output" | grep -E "(ParentResourceNotFound|404.*not found|does not exist|please retry)" >/dev/null; then
            echo "WARNING: Encountered Azure eventual consistency error or timeout:"
            echo "$cmd_output" | grep -E "(ParentResourceNotFound|404.*not found|does not exist|please retry)" | head -5
            
            # Special handling for role assignment timeout errors
            if echo "$cmd_output" | grep -q "please retry"; then
                echo "INFO: Detected role assignment timeout error - this typically requires longer wait times"
                # Use a fixed 10-second wait for role assignment errors (matching cloud-credential-operator behavior)
                wait_time=10
            fi
            
            retry_count=$((retry_count + 1))
            
            if [[ $retry_count -lt $max_retries ]]; then
                echo "INFO: Waiting ${wait_time}s before retry $((retry_count + 1))/$max_retries..."
                sleep $wait_time
                
                # Exponential backoff (skip for role assignment errors which use fixed 10s)
                if ! echo "$cmd_output" | grep -q "please retry"; then
                    wait_time=$((wait_time * exponential_factor))
                    
                    # Cap maximum wait time at 60 seconds
                    if [[ $wait_time -gt 60 ]]; then
                        wait_time=60
                    fi
                fi
            else
                echo "ERROR: Maximum retries ($max_retries) reached. Command failed."
                echo "Full error output:"
                echo "$cmd_output"
                return 1
            fi
        else
            # Non-retryable error
            echo "ERROR: ccoctl azure command failed with non-retryable error:"
            echo "$cmd_output"
            return 1
        fi
    done
    
    return 1
}