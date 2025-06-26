# Retry wrapper for ccoctl azure commands to handle eventual consistency issues
# This addresses the Azure equivalent of OCPBUGS-44933 (which only fixed GCP)

retry_ccoctl_azure() {
    local max_retries=5
    local retry_count=0
    local wait_time=5
    local exponential_factor=2
    
    # Execute the command and capture both stdout and stderr
    local cmd_output
    local cmd_exit_code
    
    while [[ $retry_count -lt $max_retries ]]; do
        echo "INFO: Executing ccoctl azure command (attempt $((retry_count + 1))/$max_retries)..."
        
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
            ccoctl "${destroy_args[@]}" 2>&1 || echo "WARNING: Destroy command failed, but continuing with retry"
            
            # Wait a bit for resources to be cleaned up
            echo "INFO: Waiting 10 seconds for resources to be cleaned up..."
            sleep 10
            
            # Continue with retry logic
            retry_count=$((retry_count + 1))
            if [[ $retry_count -lt $max_retries ]]; then
                echo "INFO: Retrying create command after cleanup..."
                continue
            else
                echo "ERROR: Maximum retries ($max_retries) reached after cleanup attempt."
                return 1
            fi
        fi
        
        # Check if error is retryable (Azure eventual consistency issues)
        if echo "$cmd_output" | grep -E "(ParentResourceNotFound|404.*not found|does not exist)" >/dev/null; then
            echo "WARNING: Encountered Azure eventual consistency error:"
            echo "$cmd_output" | grep -E "(ParentResourceNotFound|404.*not found|does not exist)" | head -5
            
            retry_count=$((retry_count + 1))
            
            if [[ $retry_count -lt $max_retries ]]; then
                echo "INFO: Waiting ${wait_time}s before retry $((retry_count + 1))/$max_retries..."
                sleep $wait_time
                
                # Exponential backoff
                wait_time=$((wait_time * exponential_factor))
                
                # Cap maximum wait time at 60 seconds
                if [[ $wait_time -gt 60 ]]; then
                    wait_time=60
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