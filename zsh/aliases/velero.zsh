# Velero related aliases
export VELERO_NS=openshift-adp
alias kubectl-patch-velero-debug="kubectl patch -n \$VELERO_NS deployment.apps/velero --type=json -p=\"[{\"op\": \"add\", \"path\": \"/spec/template/spec/containers/0/args/-\", \"value\": \"--log-level=debug\"}]\""
alias velero-goruninstall='velero-makecontainer-cluster-arch; go run cmd/velero/velero.go install --image=$(ghcr_notag):$(current-branch)-$(rev-sha-short)-$(cluster-arch-only) --provider aws --bucket $AWS_BUCKET --prefix velero --plugins velero/velero-plugin-for-aws:latest --secret-file $AWS_SECRET_FILE'
alias velero-goruninstall-node-agent='velero-makecontainer-cluster-arch; go run cmd/velero/velero.go install --use-node-agent --image=$(ghcr_notag):$(current-branch)-$(rev-sha-short)-$(cluster-arch-only) --provider aws --bucket $AWS_BUCKET --prefix velero --plugins velero/velero-plugin-for-aws:latest --secret-file $AWS_SECRET_FILE'
alias velero-makecontainer='make container IMAGE=$(ghcr_notag) VERSION=$(current-branch)-$(rev-sha-short) && docker push $(ghcr_notag):$(current-branch)-$(rev-sha-short); echo $(ghcr_notag):$(current-branch)-$(rev-sha-short)'
alias velero-makecontainer-cluster-arch='make container IMAGE=$(ghcr_notag) VERSION=$(current-branch)-$(rev-sha-short)-$(cluster-arch-only) && docker push $(ghcr_notag):$(current-branch)-$(rev-sha-short)-$(cluster-arch-only) && echo $(ghcr_notag):$(current-branch)-$(rev-sha-short)-$(cluster-arch-only)'
alias velero-makecontainer-velero-restore-helper-cluster-arch='make container IMAGE=$(ghcr_notag) VERSION=velero-restore-helper-$(current-branch)-$(rev-sha-short)-$(cluster-arch-only) && docker push $(ghcr_notag):velero-restore-helper-$(current-branch)-$(rev-sha-short)-$(cluster-arch-only) && echo $(ghcr_notag):velero-restore-helper-$(current-branch)-$(rev-sha-short)-$(cluster-arch-only)'
alias cluster-arch="kubectl get nodes -o jsonpath='{range .items[0]}{.status.nodeInfo.operatingSystem}{\"/\"}{.status.nodeInfo.architecture}{end}'"
# without linux/
alias cluster-arch-only="kubectl get nodes -o jsonpath='{range .items[0]}{.status.nodeInfo.architecture}{end}'"
alias ocregistry_tag='echo $(oc-registry-route)/$(basename $PWD):$(current-branch)'
alias ocregistry_notag='echo $(oc-registry-route)/$(basename $PWD)'

# Wait for deployments and follow logs
logs-velero() {
  local ns="${1:-$(oc config view --minify -o jsonpath='{.contexts[0].context.namespace}')}"
  until oc get deployment/velero -n "$ns" &>/dev/null; do 
    echo "Waiting for velero deployment to exist in namespace $ns..."
    sleep 2
  done && \
  oc wait --for=condition=available deployment/velero -n "$ns" --timeout=300s && \
  oc logs deploy/velero -n "$ns" -f
}

logs-oadp() {
  local ns="${1:-$(oc config view --minify -o jsonpath='{.contexts[0].context.namespace}')}"
  until oc get deployment/openshift-adp-controller-manager -n "$ns" &>/dev/null; do 
    echo "Waiting for openshift-adp-controller-manager deployment to exist in namespace $ns..."
    sleep 2
  done && \
  oc wait --for=condition=available deployment/openshift-adp-controller-manager -n "$ns" --timeout=300s && \
  oc logs deploy/openshift-adp-controller-manager -n "$ns" -f
}

# Set PR_REVIEW_USERS to current Velero maintainers (excluding emeritus)
set-velero-pr-review-users() {
  # Fetch current maintainers from GitHub
  local maintainers_url="https://raw.githubusercontent.com/vmware-tanzu/velero/main/MAINTAINERS.md"
  local maintainers=$(curl -s "$maintainers_url" | grep -E '@[a-zA-Z0-9_-]+' | grep -v -i 'emeritus' | sed -E 's/.*@([a-zA-Z0-9_-]+).*/\1/' | sort -u | tr '\n' ' ')
  
  if [[ -z "$maintainers" ]]; then
    echo "Error: Could not fetch Velero maintainers"
    return 1
  fi
  
  export PR_REVIEW_USERS="$maintainers"
  echo "PR_REVIEW_USERS set to: $PR_REVIEW_USERS"
  echo "To persist, add the following to ~/secrets.zsh:"
  echo "export PR_REVIEW_USERS=\"$PR_REVIEW_USERS\""
}

# Alias for convenience
alias velero-set-reviewers='set-velero-pr-review-users'

# Set PR_REVIEW_USERS to current OADP operator owners
set-oadp-pr-review-users() {
  # Fetch current owners from GitHub OWNERS file
  local owners_url="https://raw.githubusercontent.com/openshift/oadp-operator/master/OWNERS"
  local owners=$(curl -s "$owners_url" | grep -E '^\s*-\s+[a-zA-Z0-9_-]+\s*$' | sed -E 's/^\s*-\s+([a-zA-Z0-9_-]+)\s*$/\1/' | sort -u | tr '\n' ' ')
  
  if [[ -z "$owners" ]]; then
    echo "Error: Could not fetch OADP owners"
    return 1
  fi
  
  export PR_REVIEW_USERS="$owners"
  echo "PR_REVIEW_USERS set to: $PR_REVIEW_USERS"
  echo "To persist, add the following to ~/secrets.zsh:"
  echo "export PR_REVIEW_USERS=\"$PR_REVIEW_USERS\""
}

# Alias for convenience
alias oadp-set-reviewers='set-oadp-pr-review-users'

# Review PRs from a specific author
pr-review-user() {
  local user="${1:-kaovilai}"
  local repo="${2:-vmware-tanzu/velero}"
  gh pr list --repo "$repo" --author "$user" --state open --json url --jq '.[].url' | xargs -I {} zsh -ic 'claude-review {}'
}

# Review PRs from multiple users defined in environment variable
pr-review-all-users() {
  local repo="${1:-vmware-tanzu/velero}"
  
  # Check if PR_REVIEW_USERS is set
  if [[ -z "$PR_REVIEW_USERS" ]]; then
    echo "Error: PR_REVIEW_USERS environment variable not set"
    echo "Add 'export PR_REVIEW_USERS=\"user1 user2 user3\"' to ~/secrets.zsh"
    echo "Or use velero-set-reviewers or oadp-set-reviewers to set automatically"
    return 1
  fi
  
  # Loop through each user
  for user in ${=PR_REVIEW_USERS}; do
    echo "Reviewing PRs from $user in $repo..."
    pr-review-user "$user" "$repo"
  done
}

# Review all Velero maintainer PRs without setting environment variable
review-velero-maintainer-prs() {
  echo "Fetching Velero maintainers..."
  local maintainers_url="https://raw.githubusercontent.com/vmware-tanzu/velero/main/MAINTAINERS.md"
  local maintainers=$(curl -s "$maintainers_url" | grep -E '@[a-zA-Z0-9_-]+' | grep -v -i 'emeritus' | sed -E 's/.*@([a-zA-Z0-9_-]+).*/\1/' | sort -u)
  
  if [[ -z "$maintainers" ]]; then
    echo "Error: Could not fetch Velero maintainers"
    return 1
  fi
  
  echo "Found maintainers: $(echo $maintainers | tr '\n' ' ')"
  echo ""
  
  # Loop through each maintainer
  for user in ${=maintainers}; do
    echo "Reviewing PRs from $user..."
    pr-review-user "$user" "vmware-tanzu/velero"
  done
}

# Review all OADP owner PRs without setting environment variable
review-oadp-owner-prs() {
  echo "Fetching OADP owners..."
  local owners_url="https://raw.githubusercontent.com/openshift/oadp-operator/master/OWNERS"
  local owners=$(curl -s "$owners_url" | grep -E '^\s*-\s+[a-zA-Z0-9_-]+\s*$' | sed -E 's/^\s*-\s+([a-zA-Z0-9_-]+)\s*$/\1/' | sort -u)
  
  if [[ -z "$owners" ]]; then
    echo "Error: Could not fetch OADP owners"
    return 1
  fi
  
  echo "Found owners: $(echo $owners | tr '\n' ' ')"
  echo ""
  
  # Loop through each owner
  for user in ${=owners}; do
    echo "Reviewing PRs from $user..."
    pr-review-user "$user" "openshift/oadp-operator"
  done
}

# Aliases for convenience
alias velero-review-all='review-velero-maintainer-prs'
alias oadp-review-all='review-oadp-owner-prs'
