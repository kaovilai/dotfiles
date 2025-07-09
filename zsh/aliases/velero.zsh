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
