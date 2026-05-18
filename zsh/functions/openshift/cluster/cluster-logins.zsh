#!/bin/zsh

# Function to save cluster login to a named kubeconfig file
# Usage: save-cluster-login <name> <oc-login-command>
# Example: save-cluster-login mycluster oc login -u kubeadmin -p password https://api.cluster.example.com:6443 --insecure-skip-tls-verify
save-cluster-login() {
    if [[ $# -lt 2 ]]; then
        echo "Usage: save-cluster-login <name> <oc-login-command>"
        echo "Example: save-cluster-login mycluster oc login -u kubeadmin -p password https://api.cluster.example.com:6443 --insecure-skip-tls-verify"
        return 1
    fi

    local name="$1"
    shift
    local kubeconfig_dir="$HOME/OCP/kubeconfigs"
    local kubeconfig_path="${kubeconfig_dir}/${name}"

    # Create directory if it doesn't exist
    mkdir -p "$kubeconfig_dir"

    # Execute the oc login command with the specified kubeconfig
    echo "Logging in and saving kubeconfig to: ${kubeconfig_path}"
    if KUBECONFIG="$kubeconfig_path" "$@"; then
        echo "✓ Successfully saved kubeconfig to: ${kubeconfig_path}"
        echo "To use this cluster, run: export KUBECONFIG='${kubeconfig_path}'"
    else
        echo "✗ Login failed"
        return 1
    fi
}
