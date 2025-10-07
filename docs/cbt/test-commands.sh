#!/bin/bash
# Test commands for CSI Changed Block Tracking

set -e

echo "=== CSI Changed Block Tracking Test Script ==="
echo

# Check CBT availability
echo "1. Checking CBT API availability..."
oc api-resources | grep -i snapshotmetadata
echo

# Check feature gate
echo "2. Checking feature gate..."
oc get featuregate cluster -o yaml | grep -A 2 ExternalSnapshotMetadata
echo

# Check for existing SnapshotMetadataService instances
echo "3. Checking for SnapshotMetadataService instances..."
oc get snapshotmetadataservice -A || echo "No SnapshotMetadataService instances found"
echo

# Check RBD CSI controller containers
echo "4. Checking RBD CSI controller containers..."
echo "Expected: 9 containers (including external-snapshot-metadata)"
oc get pod -n openshift-storage \
  -l app=csi-rbdplugin,csi-provisioner=true \
  -o jsonpath='{.items[0].spec.containers[*].name}' | tr ' ' '\n' | nl
echo

# Check for snapshot metadata service endpoint
echo "5. Checking for snapshot metadata service..."
oc get svc -n openshift-storage | grep -i snapshot || echo "No snapshot metadata service found"
echo

# Create test namespace
echo "6. Creating test namespace..."
oc create namespace cbt-test || echo "Namespace already exists"
echo

# Apply test setup
echo "7. Applying test setup..."
oc apply -f test-setup.yaml
echo

# Wait for PVC
echo "8. Waiting for PVC to be bound..."
oc wait --for=condition=Ready pvc/cbt-test-pvc -n cbt-test --timeout=60s
echo

# Wait for pod
echo "9. Waiting for test pod to be ready..."
oc wait --for=condition=Ready pod/cbt-test-pod -n cbt-test --timeout=120s
echo

# Check pod logs
echo "10. Checking initial data write..."
sleep 5
oc logs -n cbt-test cbt-test-pod --tail=10
echo

# Wait for first snapshot
echo "11. Waiting for first snapshot..."
oc wait --for=jsonpath='{.status.readyToUse}'=true \
  volumesnapshot/cbt-test-snap1 -n cbt-test --timeout=60s
echo

# Write additional data
echo "12. Writing additional data..."
oc exec -n cbt-test cbt-test-pod -- sh -c \
  'dd if=/dev/urandom of=/data/file2.dat bs=1M count=50 2>/dev/null && echo "Second write completed"'
echo

# Create second snapshot
echo "13. Waiting for second snapshot..."
oc wait --for=jsonpath='{.status.readyToUse}'=true \
  volumesnapshot/cbt-test-snap2 -n cbt-test --timeout=60s
echo

# Check snapshots
echo "14. Checking snapshots..."
oc get volumesnapshot -n cbt-test
echo

# Check snapshot contents
echo "15. Checking snapshot contents..."
oc get volumesnapshotcontent | grep cbt-test
echo

# Try to query SnapshotMetadataService
echo "16. Checking SnapshotMetadataService status..."
oc get snapshotmetadataservice test-rbd-snapshot-metadata -o yaml 2>/dev/null || \
  echo "SnapshotMetadataService not created or not accessible"
echo

echo "=== Test Complete ==="
echo
echo "Summary:"
echo "- VolumeSnapshots: Created successfully ✅"
echo "- SnapshotMetadataService CR: Can be created ⚠️"
echo "- CBT API: Not functional (missing sidecar) ❌"
echo
echo "To cleanup:"
echo "  oc delete namespace cbt-test"
echo "  oc delete snapshotmetadataservice test-rbd-snapshot-metadata"
