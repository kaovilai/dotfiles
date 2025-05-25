# OpenShift Cluster Creation Function Template

This template shows the recommended structure for cluster creation functions using common utilities.

```bash
znap function create-ocp-<provider>() {
    # Unset SSH_AUTH_SOCK on Darwin systems to avoid SSH errors
    if [[ "$(uname)" == "Darwin" ]]; then
        unset SSH_AUTH_SOCK
    fi
    
    # Get openshift-install binary
    local OPENSHIFT_INSTALL=$(get_openshift_install)
    [[ -z "$OPENSHIFT_INSTALL" ]] && return 1
    $OPENSHIFT_INSTALL version
    
    # Check if help is requested
    if [[ $1 == "help" ]]; then
        # Show help text...
        return 0
    fi
    
    # Safety check - ensure TODAY is not empty
    if [[ -z "$TODAY" ]]; then
        echo "WARNING: TODAY variable is empty, using current date"
        TODAY=$(date +%Y%m%d)
    fi
    
    # Set initial cluster name and directory
    local CLUSTER_BASE_NAME="tkaovila-$TODAY-<suffix>"
    local OCP_CREATE_DIR_BASE="$OCP_MANIFESTS_DIR/$TODAY-<provider>-<suffix>"
    
    # Generate unique cluster name if needed
    local unique_result=$(generate_unique_cluster_name "$CLUSTER_BASE_NAME" "$OCP_CREATE_DIR_BASE")
    local CLUSTER_NAME=$(echo "$unique_result" | grep "cluster_name:" | cut -d: -f2)
    local OCP_CREATE_DIR=$(echo "$unique_result" | grep "cluster_dir:" | cut -d: -f2)
    
    # Handle special commands (gather, delete)
    if [[ $1 == "gather" ]]; then
        # Handle gather...
        return 0
    fi
    
    if [[ $1 != "no-delete" ]]; then
        # Handle cleanup of existing cluster...
    fi
    
    if [[ $1 == "delete" ]]; then
        return 0
    fi
    
    # Validate required environment variables
    validate_env_vars "<provider>" \
        VAR1 \
        VAR2 \
        VAR3 || return 1
    
    # Check for existing clusters
    check-for-existing-clusters "<provider>" || return 1
    
    # Prompt for release stream and get release image
    local stream=$(prompt_release_stream)
    local RELEASE_IMAGE=$(get_release_image "$stream" "<architecture>")
    [[ -z "$RELEASE_IMAGE" ]] && return 1
    
    echo "INFO: Using release image: $RELEASE_IMAGE"
    
    # Handle registry login if needed
    local BASE_RELEASE_IMAGE_REGISTRY=$(echo $RELEASE_IMAGE | awk -F/ '{print $1}')
    handle_registry_login "$BASE_RELEASE_IMAGE_REGISTRY"
    update_pull_secret_with_podman "$BASE_RELEASE_IMAGE_REGISTRY"
    
    # Create install-config.yaml
    mkdir -p $OCP_CREATE_DIR || return 1
    
    {
        create_install_config_header
        echo "baseDomain: $<PROVIDER>_BASEDOMAIN"
        # Add provider-specific configuration...
        echo "credentialsMode: Manual"  # if using STS/WIF
        add_credentials_to_install_config
    } > $OCP_CREATE_DIR/install-config.yaml || return 1
    
    echo "created install-config.yaml"
    
    # Export release image override
    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=$RELEASE_IMAGE
    echo "INFO: Exported OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=$RELEASE_IMAGE"
    
    # Provider-specific credential extraction (if needed)
    # ...
    
    # Create manifests
    $OPENSHIFT_INSTALL create manifests --dir $OCP_CREATE_DIR || return 1
    
    # Create the cluster with error handling
    if ! $OPENSHIFT_INSTALL create cluster --dir $OCP_CREATE_DIR --log-level=info; then
        cleanup_on_failure "$OCP_CREATE_DIR" "$CLUSTER_NAME" "<provider>"
        return 1
    fi
    
    # Cleanup
    unset OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE
    [[ -n "$PROCEED_WITH_EXISTING_CLUSTERS" ]] && unset PROCEED_WITH_EXISTING_CLUSTERS
    
    return 0
}
```

## Key Improvements

1. **Consistent Structure**: All functions follow the same pattern
2. **Common Utilities**: Reusable functions for common tasks
3. **Better Error Handling**: Cleanup on failure with bootstrap log gathering
4. **Environment Validation**: Centralized validation with clear error messages
5. **Release Stream Selection**: User-friendly prompt with version preview
6. **Registry Management**: Automated login and pull secret updates
7. **Unique Naming**: Automatic handling of cluster name conflicts

## Common Utilities Available

- `get_openshift_install()`: Find appropriate openshift-install binary
- `validate_env_vars()`: Validate required environment variables
- `prompt_release_stream()`: Interactive release stream selection
- `get_release_image()`: Get release image for stream/architecture
- `handle_registry_login()`: Handle registry authentication
- `update_pull_secret_with_podman()`: Update pull secret with podman creds
- `generate_unique_cluster_name()`: Generate unique cluster names
- `cleanup_on_failure()`: Cleanup resources on failure
- `create_install_config_header()`: Standard install-config header
- `add_credentials_to_install_config()`: Add pull secret and SSH key