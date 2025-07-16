# Load all OpenShift functions in the correct order
# This file is sourced by .zshrc

# First load variables 
source ~/git/dotfiles/zsh/functions/openshift/variables.zsh

# Load cluster functions 
source ~/git/dotfiles/zsh/functions/openshift/cluster/check-existing-clusters.zsh
source ~/git/dotfiles/zsh/functions/openshift/cluster/install-cluster.zsh
source ~/git/dotfiles/zsh/functions/openshift/cluster/list-and-use.zsh

# Load provider-specific functions
source ~/git/dotfiles/zsh/functions/openshift/aws/create-ocp-aws.zsh
source ~/git/dotfiles/zsh/functions/openshift/aws/delete-ocp-aws.zsh
source ~/git/dotfiles/zsh/functions/openshift/aws/use-ocp-aws.zsh
source ~/git/dotfiles/zsh/functions/openshift/rosa/create-rosa-sts.zsh
source ~/git/dotfiles/zsh/functions/openshift/rosa/delete-rosa-sts.zsh
source ~/git/dotfiles/zsh/functions/openshift/rosa/use-rosa-sts.zsh
source ~/git/dotfiles/zsh/functions/openshift/rosa/velero-rosa-sts.zsh
source ~/git/dotfiles/zsh/functions/openshift/azure/retry-ccoctl-azure.zsh
source ~/git/dotfiles/zsh/functions/openshift/azure/create-ocp-azure-sts.zsh
source ~/git/dotfiles/zsh/functions/openshift/azure/delete-ocp-azure-sts.zsh
source ~/git/dotfiles/zsh/functions/openshift/azure/use-ocp-azure-sts.zsh
source ~/git/dotfiles/zsh/functions/openshift/gcp/create-ocp-gcp-wif.zsh
source ~/git/dotfiles/zsh/functions/openshift/gcp/delete-ocp-gcp-wif.zsh
source ~/git/dotfiles/zsh/functions/openshift/gcp/use-ocp-gcp-wif.zsh
source ~/git/dotfiles/zsh/functions/openshift/crc/crc-functions.zsh

# Load utility functions
source ~/git/dotfiles/zsh/functions/openshift/util/common-functions.zsh
source ~/git/dotfiles/zsh/functions/openshift/util/ca-functions.zsh
source ~/git/dotfiles/zsh/functions/openshift/util/install-tools.zsh
source ~/git/dotfiles/zsh/functions/openshift/util/misc-functions.zsh

# Set common aliases
alias kubectl=oc
alias oc-registry-login='oc registry login'
alias oc-registry-route='oc get route -n openshift-image-registry default-route -o jsonpath={.spec.host}'
alias ocwebconsole='edge $(oc whoami --show-console)'
alias oc-run='oc run --rm -it --image'
# ROSA functions are now available as create-rosa-sts-arm64 and create-rosa-sts-amd64

# Export variables (in case they were not exported in the variables file)
export EDITOR="code -w"
