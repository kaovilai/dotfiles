# Load all OpenShift functions in the correct order
# This file is sourced by .zshrc

# Ensure _safe_source is available (defined in alias.zsh, but load.zsh may be
# sourced independently). Inline a minimal fallback if needed.
(( ${+functions[_safe_source]} )) || _safe_source() {
  [[ -f "$1" ]] || { print -P "%F{yellow}[dotfiles] File not found: $1%f" >&2; return 1; }
  source "$1" || print -P "%F{red}[dotfiles] Failed to source: $1%f" >&2
}

# First load variables
_safe_source ~/git/dotfiles/zsh/functions/openshift/variables.zsh

# Load cluster functions
_safe_source ~/git/dotfiles/zsh/functions/openshift/cluster/check-existing-clusters.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/cluster/cluster-logins.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/cluster/install-cluster.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/cluster/list-and-use.zsh

# Load provider-specific functions
_safe_source ~/git/dotfiles/zsh/functions/openshift/aws/create-ocp-aws.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/aws/delete-ocp-aws.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/aws/use-ocp-aws.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/rosa/create-rosa-sts.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/rosa/delete-rosa-sts.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/rosa/use-rosa-sts.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/rosa/select-rosa-cluster.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/rosa/velero-rosa-sts.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/azure/retry-ccoctl-azure.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/azure/create-ocp-azure-sts.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/azure/delete-ocp-azure-sts.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/azure/use-ocp-azure-sts.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/gcp/create-ocp-gcp-wif.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/gcp/delete-ocp-gcp-wif.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/gcp/use-ocp-gcp-wif.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/crc/crc-functions.zsh

# Load utility functions
_safe_source ~/git/dotfiles/zsh/functions/openshift/util/common-functions.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/util/ca-functions.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/util/install-tools.zsh
_safe_source ~/git/dotfiles/zsh/functions/openshift/util/misc-functions.zsh

# Set common aliases
alias kubectl=oc
alias oc-registry-login='oc registry login'
alias oc-registry-route='oc get route -n openshift-image-registry default-route -o jsonpath={.spec.host}'
alias ocwebconsole='comet $(oc whoami --show-console)'
alias oc-run='oc run --rm -it --image'
# ROSA functions are now available as create-rosa-sts-arm64 and create-rosa-sts-amd64

# Export variables (in case they were not exported in the variables file)
export EDITOR="code -w"
