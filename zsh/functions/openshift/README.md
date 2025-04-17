# OpenShift Functions

This directory contains modular ZSH functions for working with OpenShift clusters.

## Directory Structure

```
openshift/
├── aws/                   # AWS-specific functions
│   ├── create-ocp-aws.zsh # Create AWS clusters
│   └── delete-ocp-aws.zsh # Delete AWS clusters
├── cluster/               # General cluster management
│   ├── check-existing-clusters.zsh # Check for existing clusters
│   ├── install-cluster.zsh         # Install local clusters
│   └── list-and-use.zsh            # List clusters and set KUBECONFIG
├── crc/                   # CodeReady Containers functions
│   └── crc-functions.zsh  # CRC start, login, etc.
├── gcp/                   # GCP-specific functions
│   ├── create-ocp-gcp-wif.zsh # Create GCP clusters with WIF
│   └── delete-ocp-gcp-wif.zsh # Delete GCP clusters
├── util/                  # Utility functions
│   ├── ca-functions.zsh   # Certificate authority functions
│   └── install-tools.zsh  # Tool installation functions
├── variables.zsh          # Shared variables
├── load.zsh               # Main loader for all functions
└── README.md              # This file
```

## Usage

All functions are loaded automatically when the shell starts via the `load.zsh` file, which is sourced from `.zshrc`.

## Key Functions

### Cluster Safety Check

The `check-for-existing-clusters` function detects existing clusters before creating new ones:

```bash
check-for-existing-clusters [CLOUD_PROVIDER] [PATTERN]
```

- `CLOUD_PROVIDER`: Optional filter by provider (aws, gcp, all)
- `PATTERN`: Optional pattern to match in cluster names

When found, it provides options to:
1. Destroy existing clusters and create new ones
2. Cancel the operation
3. Force continue (with warning about resource conflicts)

### AWS Functions

- `create-ocp-aws-arm64`/`create-ocp-aws-amd64`: Create AWS clusters with the specified architecture
- `delete-ocp-aws-arm64`/`delete-ocp-aws-amd64`: Delete AWS clusters with the specified architecture
- `delete-ocp-aws-dir`: Delete AWS clusters based on directory name

### GCP Functions

- `create-ocp-gcp-wif`: Create GCP cluster with Workload Identity Federation
- `delete-ocp-gcp-wif`: Delete GCP cluster
- `delete-ocp-gcp-wif-dir`: Delete GCP cluster based on directory name

### Cluster Management

- `list-ocp-clusters`: List all available clusters with optional details
- `use-ocp-cluster`: Interactively select and use a cluster by setting KUBECONFIG
- `installClusterOpenshiftInstall`: Install a cluster using local install-config.yaml

## Adding New Functions

1. Create a new `.zsh` file in the appropriate subdirectory
2. Define your function with `znap function your_function_name() { ... }`
3. Add the file to `load.zsh` using `source ~/git/dotfiles/zsh/functions/openshift/path/to/file.zsh`

## Variables

Common variables are defined in `variables.zsh`:
- `OCP_FUNCTIONS_RELEASE_IMAGE`: Default OpenShift release image
- `OCP_MANIFESTS_DIR`: Directory for cluster manifests
- `TODAY`: Current date in YYYYMMDD format
- Client OS and architecture detection for downloads
