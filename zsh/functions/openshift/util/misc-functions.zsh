# OpenShift Miscellaneous Utility Functions
#
# Functions for monitoring pods, patching resources, and cluster management
#
# Functions provided:
#   - watch-all-pod-logs-in-namespace: Stream logs from all pods in a namespace
#   - watch-all-pod-errors-in-namespace: Stream and filter errors from all pods
#   - patch-csv-replicas: Patch ClusterServiceVersion replica count
#   - agd-kubeadmin-password: Get kubeadmin password for AgnosticD cluster

# Stream logs from all pods in a namespace
# Usage: watch-all-pod-logs-in-namespace <NAMESPACE>
# Description: Follows logs from all pods in a namespace in parallel
#              Uses 100 parallel processes for efficient log streaming
# Parameters:
#   $1 - namespace: OpenShift namespace name
# Example:
#   watch-all-pod-logs-in-namespace openshift-adp
#   watch-all-pod-logs-in-namespace my-app
watch-all-pod-logs-in-namespace(){
    if [ -z "$1" ]; then
        echo "No namespace supplied"
        return 1
    fi
    oc get pods -n $1 -o name | xargs -n 1 -P 100 oc logs -f -n $1
}

# Stream and filter errors from all pods in a namespace
# Usage: watch-all-pod-errors-in-namespace <NAMESPACE>
# Description: Follows logs from all pods, filters for "error", and prefixes with pod name
#              Uses 100 parallel processes for efficient monitoring
# Parameters:
#   $1 - namespace: OpenShift namespace name
# Example:
#   watch-all-pod-errors-in-namespace openshift-adp
watch-all-pod-errors-in-namespace(){
    if [ -z "$1" ]; then
        echo "No namespace supplied"
        return 1
    fi
    # get all pod logs in namespace, grep for error, and prefix with pod name
    oc get pods -n $1 -o name | xargs -n 1 -P 100 -I {} sh -c "oc logs -n $1 -f {} | grep --line-buffered error | sed \"s#^#{}: #\""
}

# Patch ClusterServiceVersion replica count
# Usage: patch-csv-replicas <CSV_NAME> <REPLICAS>
# Description: Updates the replica count for an operator's ClusterServiceVersion
#              Useful for scaling operator pods
# Parameters:
#   $1 - CSV name: Name of the ClusterServiceVersion
#   $2 - replicas: Desired number of replicas
# Example:
#   patch-csv-replicas oadp-operator.v1.2.0 2
#   patch-csv-replicas my-operator.v1.0.0 0  # Scale down to 0
patch-csv-replicas(){
    if [ -z "$1" ]; then
        echo "No CSV name supplied"
        return 1
    fi
    if [ -z "$2" ]; then
        echo "No replicas supplied"
        return 1
    fi
    oc patch csv $1 --type='json' -p '[
  {
    "op": "replace",
    "path": "/spec/install/spec/deployments/0/spec/replicas",
    "value": '$2'
  }
]
'
}

agd-kubeadmin-password(){
 if [$1 = ""]; then
  echo "No GUID supplied"
  return 1
 else
  echo "parsing guid $1"
  cat "~/.agnosticd/$1/ocp4-cluster_$1_kubeadmin-password"
 fi
}

# Backwards compatibility aliases for renamed functions
alias watchAllPodLogsInNamespace='watch-all-pod-logs-in-namespace'
alias watchAllPodErrorsInNamespace='watch-all-pod-errors-in-namespace'
alias patchCSVreplicas='patch-csv-replicas'
alias agdKubeAdminPassword='agd-kubeadmin-password'
