# OpenShift Miscellaneous Utility Functions
#
# Functions for monitoring pods, patching resources, and cluster management
#
# Functions provided:
#   - watchAllPodLogsInNamespace: Stream logs from all pods in a namespace
#   - watchAllPodErrorsInNamespace: Stream and filter errors from all pods
#   - patchCSVreplicas: Patch ClusterServiceVersion replica count
#   - agdKubeAdminPassword: Get kubeadmin password for AgnosticD cluster

# Stream logs from all pods in a namespace
# Usage: watchAllPodLogsInNamespace <NAMESPACE>
# Description: Follows logs from all pods in a namespace in parallel
#              Uses 100 parallel processes for efficient log streaming
# Parameters:
#   $1 - namespace: OpenShift namespace name
# Example:
#   watchAllPodLogsInNamespace openshift-adp
#   watchAllPodLogsInNamespace my-app
znap function watchAllPodLogsInNamespace(){
    if [ -z "$1" ]; then
        echo "No namespace supplied"
        return 1
    fi
    oc get pods -n $1 -o name | xargs -n 1 -P 100 oc logs -f -n $1
}

# Stream and filter errors from all pods in a namespace
# Usage: watchAllPodErrorsInNamespace <NAMESPACE>
# Description: Follows logs from all pods, filters for "error", and prefixes with pod name
#              Uses 100 parallel processes for efficient monitoring
# Parameters:
#   $1 - namespace: OpenShift namespace name
# Example:
#   watchAllPodErrorsInNamespace openshift-adp
znap function watchAllPodErrorsInNamespace(){
    if [ -z "$1" ]; then
        echo "No namespace supplied"
        return 1
    fi
    # get all pod logs in namespace, grep for error, and prefix with pod name
    oc get pods -n $1 -o name | xargs -n 1 -P 100 -I {} sh -c "oc logs -n $1 -f {} | grep --line-buffered error | sed \"s#^#{}: #\""
}

# Patch ClusterServiceVersion replica count
# Usage: patchCSVreplicas <CSV_NAME> <REPLICAS>
# Description: Updates the replica count for an operator's ClusterServiceVersion
#              Useful for scaling operator pods
# Parameters:
#   $1 - CSV name: Name of the ClusterServiceVersion
#   $2 - replicas: Desired number of replicas
# Example:
#   patchCSVreplicas oadp-operator.v1.2.0 2
#   patchCSVreplicas my-operator.v1.0.0 0  # Scale down to 0
znap function patchCSVreplicas(){
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

znap function agdKubeAdminPassword(){
 if [$1 = ""]; then 
  echo "No GUID supplied"
  return 1
 else
  echo "parsing guid $1"
  cat "~/.agnosticd/$1/ocp4-cluster_$1_kubeadmin-password"
 fi
}
