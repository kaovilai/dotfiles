# CBT Test Results - hostpath-csi-driver v1.17.0

**Test Date**: October 7, 2025
**Cluster**: OpenShift 4.20.0-rc.3
**Driver Version**: hostpath-csi-driver v1.17.0
**Test Location**: `/tmp/csi-driver-host-path`

## Summary

✅ **SUCCESS** - Changed Block Tracking fully operational with hostpath-csi-driver v1.17.0

## Test Environment

### Cluster Configuration
- **Kubernetes Version**: 1.33.5
- **OpenShift Version**: 4.20.0-rc.3
- **ExternalSnapshotMetadata Feature Gate**: Enabled
- **SnapshotMetadataService CRD**: Installed

### Deployment Architecture

```
openshift-cluster-csi-drivers namespace:
├── StatefulSet: csi-hostpathplugin-0 (8 containers)
│   ├── hostpath (v1.17.0)
│   ├── node-driver-registrar
│   ├── liveness-probe
│   ├── csi-attacher
│   ├── csi-provisioner
│   ├── csi-resizer
│   ├── csi-snapshotter
│   └── csi-snapshot-metadata (sidecar)
├── Service: csi-snapshot-metadata (172.30.1.1:6443)
├── ServiceAccount: csi-hostpathplugin-sa
└── Secret: csi-snapshot-metadata-certs

SnapshotMetadataService (cluster-scoped):
├── Name: hostpath.csi.k8s.io
├── Address: csi-snapshot-metadata.openshift-cluster-csi-drivers.svc:6443
└── Audience: test-backup-client
```

## Test Execution

### Test Data Pattern

Following Red Hat documentation pattern with 4K blocks at specific offsets:

**Initial Data (Snapshot 1)**:
```bash
# Write 5 blocks of 4K at offsets 1, 3, 5, 7, 9
for offset in 1 3 5 7 9; do
  oc exec -n cbt-test pod-raw -- dd if=/dev/urandom of=/dev/loop3 bs=4K count=1 seek=$offset conv=notrunc
done
```

**Delta Data (Snapshot 2)**:
```bash
# Write 5 additional blocks at offsets 15-19
oc exec -n cbt-test pod-raw -- dd if=/dev/urandom of=/dev/loop3 bs=4K count=5 seek=15 conv=notrunc
```

### Snapshot Creation

Both snapshots created successfully:
```bash
$ oc get volumesnapshot -n cbt-test
NAME             READYTOUSE   SOURCEPVC   RESTORESIZE   SNAPSHOTCLASS
test-snapshot1   true         csi-pvc     1Gi           csi-hostpath-snapclass
test-snapshot2   true         csi-pvc     1Gi           csi-hostpath-snapclass
```

## CBT Query Results

### Query 1: Allocated Blocks (Snapshot 1)

**Command**:
```bash
oc exec -n cbt-test pods/snapshot-metadata-tools -c tools -- \
  /tools/snapshot-metadata-lister -n cbt-test -s test-snapshot1
```

**Output**:
```
Record#   VolCapBytes  BlockMetadataType   ByteOffset     SizeBytes
------- -------------- ----------------- -------------- --------------
      1     1073741824      FIXED_LENGTH           4096           4096
      1     1073741824      FIXED_LENGTH          12288           4096
      1     1073741824      FIXED_LENGTH          20480           4096
      1     1073741824      FIXED_LENGTH          28672           4096
      1     1073741824      FIXED_LENGTH          36864           4096
```

**Verification** ✅:
- Offset 4096 = seek 1 (4K × 1)
- Offset 12288 = seek 3 (4K × 3)
- Offset 20480 = seek 5 (4K × 5)
- Offset 28672 = seek 7 (4K × 7)
- Offset 36864 = seek 9 (4K × 9)

All 5 blocks correctly reported at expected offsets.

### Query 2: Changed Blocks (Delta)

**Command**:
```bash
oc exec -n cbt-test pods/snapshot-metadata-tools -c tools -- \
  /tools/snapshot-metadata-lister -n cbt-test -p test-snapshot1 -s test-snapshot2
```

**Output**:
```
Record#   VolCapBytes  BlockMetadataType   ByteOffset     SizeBytes
------- -------------- ----------------- -------------- --------------
      1     1073741824      FIXED_LENGTH          61440           4096
      1     1073741824      FIXED_LENGTH          65536           4096
      1     1073741824      FIXED_LENGTH          69632           4096
      1     1073741824      FIXED_LENGTH          73728           4096
      1     1073741824      FIXED_LENGTH          77824           4096
```

**Verification** ✅:
- Offset 61440 = seek 15 (4K × 15)
- Offset 65536 = seek 16 (4K × 16)
- Offset 69632 = seek 17 (4K × 17)
- Offset 73728 = seek 18 (4K × 18)
- Offset 77824 = seek 19 (4K × 19)

Delta query accurately identified exactly 5 changed blocks.

## Test Validation

| Test Aspect | Expected | Actual | Status |
|-------------|----------|--------|--------|
| Initial blocks (snapshot1) | 5 blocks at offsets 1,3,5,7,9 | 5 blocks at offsets 1,3,5,7,9 | ✅ Pass |
| Delta blocks (snapshot2) | 5 blocks at offsets 15-19 | 5 blocks at offsets 15-19 | ✅ Pass |
| GetMetadataAllocated API | Returns block data | Returns block data | ✅ Pass |
| GetMetadataDelta API | Returns changed blocks | Returns changed blocks | ✅ Pass |
| Block offsets | Accurate byte offsets | Accurate byte offsets | ✅ Pass |
| Block sizes | 4096 bytes (4K) | 4096 bytes (4K) | ✅ Pass |

## Key Findings

### Working CBT Implementation

hostpath-csi-driver v1.17.0 provides fully functional CBT:

✅ **GetMetadataAllocated**: Correctly returns all allocated blocks in a snapshot
✅ **GetMetadataDelta**: Accurately identifies changed blocks between snapshots
✅ **Block Accuracy**: Byte offsets and sizes match expected values
✅ **gRPC Service**: TLS-secured endpoint working correctly
✅ **Authentication**: ServiceAccount token-based auth functioning

### Infrastructure Components

All required components operational:

| Component | Status |
|-----------|--------|
| SnapshotMetadataService CRD | ✅ Installed |
| external-snapshot-metadata sidecar | ✅ Running (8th container) |
| gRPC service endpoint | ✅ Accessible (172.30.1.1:6443) |
| TLS certificates | ✅ Valid |
| RBAC permissions | ✅ Configured |
| Block mode PVCs | ✅ Working |
| VolumeSnapshots | ✅ Creating successfully |

## Deployment Files

### StatefulSet Configuration
```yaml
# /tmp/csi-driver-host-path/csi-hostpathplugin-v1.17.yaml
kind: StatefulSet
apiVersion: apps/v1
metadata:
  name: csi-hostpathplugin
  namespace: openshift-cluster-csi-drivers
spec:
  containers:
    - name: hostpath
      image: registry.k8s.io/sig-storage/hostpathplugin:v1.17.0
      args:
        - "--enable-snapshot-metadata"
    - name: csi-snapshot-metadata
      image: quay.io/openshift/origin-csi-external-snapshot-metadata:latest
```

### Test Resources
```yaml
# /tmp/csi-driver-host-path/test-setup-v1.17.yaml
# - Namespace: cbt-test
# - PVC: csi-pvc (Block mode, 1Gi)
# - Pod: pod-raw (busybox with block device)
# - VolumeSnapshots: test-snapshot1, test-snapshot2
# - ServiceAccount: snapshot-metadata-tools-sa
# - Query pod: snapshot-metadata-tools
```

## Commands Reference

### Deploy hostpath-csi-driver v1.17.0
```bash
cd /tmp/csi-driver-host-path
oc apply -f csi-hostpathplugin-v1.17.yaml
```

### Create Test Environment
```bash
oc apply -f test-setup-v1.17.yaml

# Wait for PVC to bind
oc wait --for=jsonpath='{.status.phase}'=Bound pvc/csi-pvc -n cbt-test --timeout=60s
```

### Write Initial Data and Create Snapshot
```bash
# Write 5 blocks at offsets 1,3,5,7,9
for offset in 1 3 5 7 9; do
  oc exec -n cbt-test pod-raw -- dd if=/dev/urandom of=/dev/loop3 bs=4K count=1 seek=$offset conv=notrunc
done

# Create first snapshot
oc apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: test-snapshot1
  namespace: cbt-test
spec:
  volumeSnapshotClassName: csi-hostpath-snapclass
  source:
    persistentVolumeClaimName: csi-pvc
EOF

# Wait for snapshot
oc wait --for=condition=Ready volumesnapshot/test-snapshot1 -n cbt-test --timeout=30s
```

### Write Delta Data and Create Second Snapshot
```bash
# Write 5 more blocks at offsets 15-19
oc exec -n cbt-test pod-raw -- dd if=/dev/urandom of=/dev/loop3 bs=4K count=5 seek=15 conv=notrunc

# Create second snapshot
oc apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: test-snapshot2
  namespace: cbt-test
spec:
  volumeSnapshotClassName: csi-hostpath-snapclass
  source:
    persistentVolumeClaimName: csi-pvc
EOF

# Wait for snapshot
oc wait --for=condition=Ready volumesnapshot/test-snapshot2 -n cbt-test --timeout=30s
```

### Query CBT Metadata
```bash
# Query allocated blocks in snapshot1
oc exec -n cbt-test pods/snapshot-metadata-tools -c tools -- \
  /tools/snapshot-metadata-lister -n cbt-test -s test-snapshot1

# Query changed blocks between snapshots
oc exec -n cbt-test pods/snapshot-metadata-tools -c tools -- \
  /tools/snapshot-metadata-lister -n cbt-test -p test-snapshot1 -s test-snapshot2
```

## Comparison with Red Hat Documentation

| Aspect | Red Hat Docs | This Test | Match |
|--------|--------------|-----------|-------|
| Driver Version | v1.17.0 | v1.17.0 | ✅ |
| Deployment Namespace | openshift-cluster-csi-drivers | openshift-cluster-csi-drivers | ✅ |
| Data Pattern | 4K blocks at specific offsets | 4K blocks at specific offsets | ✅ |
| Volume Mode | Block | Block | ✅ |
| Query Tool | snapshot-metadata-lister | snapshot-metadata-lister | ✅ |
| Service Location | openshift-cluster-csi-drivers | openshift-cluster-csi-drivers | ✅ |
| Results | Working CBT metadata | Working CBT metadata | ✅ |

## Lessons Learned

1. **Version Requirement**: hostpath-csi-driver v1.17.0 is required for working CBT implementation.

2. **Namespace Convention**: Using `openshift-cluster-csi-drivers` namespace aligns with OpenShift and Red Hat conventions.

3. **RBAC Critical**: ClusterRoleBindings must reference correct ServiceAccount namespace for provisioning to work.

4. **Service Selector**: Service selector must exactly match pod labels for endpoint discovery.

5. **Snapshot Timing**: Create snapshots AFTER PVC is bound to avoid permanent failures.

6. **Data Pattern**: 4K block pattern at specific offsets provides clear, testable results.

7. **Block Mode Required**: CBT only works with Block volumeMode, not Filesystem.

## Conclusion

**Changed Block Tracking is fully functional** on OpenShift 4.20 with hostpath-csi-driver v1.17.0:

✅ Complete CBT infrastructure operational
✅ GetMetadataAllocated returns accurate block data
✅ GetMetadataDelta correctly identifies changed blocks
✅ Test environment matches Red Hat documentation
✅ Ready for production CBT with CSI drivers that implement the API

This test validates that:
- OpenShift 4.20 has complete CBT API support
- The infrastructure works end-to-end
- CBT can be used for efficient incremental backups
- Production drivers (like ODF) can implement CBT using this API

---

**Test Status**: ✅ All tests passed
**Date**: October 7, 2025
**Documentation**: Complete
