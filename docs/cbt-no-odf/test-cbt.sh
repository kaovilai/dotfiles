#!/bin/bash
# Test script for CSI Changed Block Tracking with hostpath-csi-driver
# This is a simplified test without ODF complexity

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Detect kubectl or oc
if command -v oc &> /dev/null; then
    KUBECTL="oc"
else
    KUBECTL="kubectl"
fi

echo -e "${BLUE}=== CSI Changed Block Tracking Test (hostpath-csi-driver) ===${NC}"
echo -e "${BLUE}Simplified test without ODF complexity${NC}"
echo ""

# Function to print status
print_status() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# 1. Check prerequisites
echo -e "${BLUE}1. Checking prerequisites...${NC}"

# Check if CBT API is available
if $KUBECTL api-resources | grep -q snapshotmetadataservices; then
    print_status "SnapshotMetadataService API is available"
else
    print_error "SnapshotMetadataService API not found"
    print_info "Install the CRD with:"
    print_info "  kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshot-metadata/master/client/config/crd/cbt.storage.k8s.io_snapshotmetadataservices.yaml"
    exit 1
fi

# Check if hostpath driver is deployed
if $KUBECTL get csidriver hostpath.csi.k8s.io &> /dev/null; then
    print_status "hostpath CSI driver is installed"
else
    print_warning "hostpath CSI driver not found"
    print_info "Deploy with:"
    print_info "  git clone https://github.com/kubernetes-csi/csi-driver-host-path.git"
    print_info "  cd csi-driver-host-path"
    print_info "  SNAPSHOT_METADATA_TESTS=true ./deploy/kubernetes-latest/deploy.sh"
    exit 1
fi

# Check for SnapshotMetadataService
if $KUBECTL get snapshotmetadataservice &> /dev/null; then
    SMS_COUNT=$($KUBECTL get snapshotmetadataservice --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$SMS_COUNT" -gt 0 ]; then
        print_status "SnapshotMetadataService found (${SMS_COUNT} instance(s))"
    else
        print_warning "No SnapshotMetadataService instances found"
        print_info "This will be created by the hostpath driver automatically"
    fi
fi

echo ""

# 2. Create test namespace
echo -e "${BLUE}2. Creating test namespace...${NC}"
$KUBECTL create namespace cbt-test 2>/dev/null || print_info "Namespace already exists"
print_status "Namespace ready"
echo ""

# 3. Apply test setup
echo -e "${BLUE}3. Deploying test resources...${NC}"
$KUBECTL apply -f test-setup.yaml
print_status "Resources created"
echo ""

# 4. Wait for PVC to be bound
echo -e "${BLUE}4. Waiting for PVC to be bound...${NC}"
$KUBECTL wait --for=jsonpath='{.status.phase}'=Bound \
  pvc/cbt-test-pvc -n cbt-test --timeout=60s
print_status "PVC is bound"
echo ""

# 5. Wait for pod to be ready
echo -e "${BLUE}5. Waiting for test pod to be ready...${NC}"
$KUBECTL wait --for=condition=Ready \
  pod/cbt-test-pod -n cbt-test --timeout=120s
print_status "Pod is ready"
echo ""

# 6. Check initial data write
echo -e "${BLUE}6. Checking initial data write (100MB)...${NC}"
sleep 5
$KUBECTL logs -n cbt-test cbt-test-pod --tail=20
echo ""

# 7. Wait for first snapshot
echo -e "${BLUE}7. Creating and waiting for first snapshot...${NC}"
if $KUBECTL wait --for=jsonpath='{.status.readyToUse}'=true \
  volumesnapshot/cbt-snap1 -n cbt-test --timeout=60s 2>/dev/null; then
    print_status "First snapshot (cbt-snap1) is ready"
else
    print_error "First snapshot failed to become ready"
    $KUBECTL describe volumesnapshot/cbt-snap1 -n cbt-test
    exit 1
fi
echo ""

# 8. Write additional data
echo -e "${BLUE}8. Writing additional data (50MB at offset 200MB)...${NC}"
$KUBECTL exec -n cbt-test cbt-test-pod -- sh -c \
  'dd if=/dev/urandom of=/dev/xvda bs=1M count=50 seek=200 2>/dev/null && echo "Second write completed"'
print_status "Additional data written"
echo ""

# 9. Create and wait for second snapshot
echo -e "${BLUE}9. Creating and waiting for second snapshot...${NC}"
if $KUBECTL wait --for=jsonpath='{.status.readyToUse}'=true \
  volumesnapshot/cbt-snap2 -n cbt-test --timeout=60s 2>/dev/null; then
    print_status "Second snapshot (cbt-snap2) is ready"
else
    print_error "Second snapshot failed to become ready"
    $KUBECTL describe volumesnapshot/cbt-snap2 -n cbt-test
    exit 1
fi
echo ""

# 10. Display snapshot information
echo -e "${BLUE}10. Snapshot information:${NC}"
$KUBECTL get volumesnapshot -n cbt-test
echo ""

# 11. Display snapshot contents
echo -e "${BLUE}11. VolumeSnapshotContent details:${NC}"
$KUBECTL get volumesnapshotcontent | grep cbt-test || print_info "No snapshot contents found"
echo ""

# 12. Check SnapshotMetadataService status
echo -e "${BLUE}12. Checking SnapshotMetadataService...${NC}"
if $KUBECTL get snapshotmetadataservice &> /dev/null; then
    SMS_LIST=$($KUBECTL get snapshotmetadataservice --no-headers 2>/dev/null)
    if [ -n "$SMS_LIST" ]; then
        print_status "SnapshotMetadataService instances found:"
        echo "$SMS_LIST"
    else
        print_warning "No SnapshotMetadataService instances found"
        print_info "The hostpath driver should create this automatically"
    fi
else
    print_warning "Cannot query SnapshotMetadataService"
fi
echo ""

# 13. Summary
echo -e "${BLUE}=== Test Summary ===${NC}"
echo ""
print_status "Test namespace created: cbt-test"
print_status "Block mode PVC created and bound"
print_status "Test pod running with block device"
print_status "Initial data written: 100MB at offset 0"
print_status "First snapshot created: cbt-snap1"
print_status "Additional data written: 50MB at offset 200MB"
print_status "Second snapshot created: cbt-snap2"
echo ""

echo -e "${BLUE}=== What Changed? ===${NC}"
echo "Between cbt-snap1 and cbt-snap2:"
echo "  • Initial data: 100MB at blocks 0-99"
echo "  • Changed data: 50MB at blocks 200-249"
echo "  • Expected delta: ~50MB of changed blocks"
echo ""

echo -e "${BLUE}=== Next Steps ===${NC}"
echo ""
echo "To query the changed blocks, you need the snapshot-metadata-lister tool:"
echo ""
echo "  1. Build the tool:"
echo "     git clone https://github.com/kubernetes-csi/external-snapshot-metadata.git"
echo "     cd external-snapshot-metadata"
echo "     make build"
echo ""
echo "  2. Query allocated blocks in snapshot 1:"
echo "     ./bin/snapshot-metadata-lister allocated \\"
echo "       --namespace cbt-test \\"
echo "       --snapshot cbt-snap1"
echo ""
echo "  3. Query changed blocks between snapshots:"
echo "     ./bin/snapshot-metadata-lister delta \\"
echo "       --namespace cbt-test \\"
echo "       --base-snapshot cbt-snap1 \\"
echo "       --target-snapshot cbt-snap2"
echo ""
echo "  4. Expected result: ~50MB changed at offset 200MB"
echo ""

echo -e "${BLUE}=== Cleanup ===${NC}"
echo "To cleanup test resources:"
echo "  $KUBECTL delete namespace cbt-test"
echo ""

echo -e "${GREEN}✓ Test setup complete!${NC}"
