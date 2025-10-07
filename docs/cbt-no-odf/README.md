# Changed Block Tracking (CBT) Test - Simplified with hostpath-csi-driver

## Overview

This is a simplified test for Kubernetes CSI Changed Block Tracking (CBT) using the **hostpath-csi-driver** instead of OpenShift Data Foundation (ODF). This test focuses on demonstrating the core CBT functionality without the complexity of a full storage solution.

## Why This Test?

This simplified test is useful for:
- **Learning CBT concepts** without needing ODF
- **Testing on vanilla Kubernetes** (e.g., minikube, kind)
- **Quick verification** of CBT infrastructure
- **Development and debugging** of CBT clients

For production ODF testing with Ceph RBD, see the full documentation in `../cbt/`.

## Prerequisites

- Kubernetes 1.33+ or OpenShift 4.20+
- `kubectl` or `oc` CLI
- Cluster with CBT feature gates enabled
- **hostpath-csi-driver v1.17.0+**

**Important**: Version 1.17.0 is required for working CBT metadata. See [TEST-RESULTS.md](TEST-RESULTS.md) for verified test results.

## What is Changed Block Tracking?

CBT enables efficient incremental backups by identifying which blocks changed between snapshots:

```
Initial Snapshot (100MB data)
    ↓
Write 50MB more data
    ↓
Second Snapshot
    ↓
CBT API tells you: "Only 50MB changed in these blocks: [x, y, z]"
```

**Benefits:**
- ✅ Faster incremental backups (only copy changed blocks)
- ✅ Reduced bandwidth and storage
- ✅ Better performance for large volumes

## Architecture

```
┌─────────────────────────────────────┐
│  Backup Application                 │
│  (snapshot-metadata-lister tool)    │
└────────────┬────────────────────────┘
             │ gRPC + Authentication
             ▼
┌─────────────────────────────────────┐
│  external-snapshot-metadata         │
│  (sidecar container)                │
└────────────┬────────────────────────┘
             │ Internal gRPC
             ▼
┌─────────────────────────────────────┐
│  CSI hostpath driver                │
│  (implements SnapshotMetadata RPCs) │
└────────────┬────────────────────────┘
             │ File system operations
             ▼
┌─────────────────────────────────────┐
│  Host file system                   │
│  (local directory)                  │
└─────────────────────────────────────┘
```

## Differences from ODF Test

| Aspect | ODF Test (docs/cbt/) | Simplified Test (this) |
|--------|---------------------|------------------------|
| Storage Backend | Ceph RBD (distributed) | Local hostpath |
| Complexity | High (full ODF stack) | Low (single CSI driver) |
| Production Ready | Yes | No (demo only) |
| Installation | Complex | Simple script |
| Use Case | Production testing | Learning/development |
| Performance | Distributed, scalable | Single node only |
| Volume Mode | Filesystem + Block | Block only (CBT requirement) |

## Installation

### 1. Install SnapshotMetadataService CRD

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshot-metadata/master/client/config/crd/cbt.storage.k8s.io_snapshotmetadataservices.yaml
```

### 2. Create Required ClusterRoles

See [INSTALL.md](INSTALL.md#step-2-create-required-clusterroles) for the complete ClusterRole definitions.

These ClusterRoles are required:
- `external-snapshot-metadata-client-runner` - For client tools
- `external-snapshot-metadata-runner` - For the CSI driver sidecar

### 3. Deploy hostpath-csi-driver with CBT Support

```bash
# Clone the repository
git clone https://github.com/kubernetes-csi/csi-driver-host-path.git
cd csi-driver-host-path

# Deploy with snapshot metadata enabled
SNAPSHOT_METADATA_TESTS=true \
HOSTPATHPLUGIN_REGISTRY=registry.k8s.io/sig-storage \
HOSTPATHPLUGIN_TAG=v1.17.0 \
./deploy/kubernetes-latest/deploy.sh
```

### 4. Verify Installation

```bash
# Check CRD
kubectl get crd snapshotmetadataservices.cbt.storage.k8s.io

# Check CSI driver pods
kubectl get pods -n default | grep csi-hostpath

# Check for SnapshotMetadataService
kubectl get snapshotmetadataservice
```

## Running the Test

### Quick Test

```bash
./test-cbt.sh
```

### Manual Test Steps

1. **Create test namespace**:
   ```bash
   kubectl create namespace cbt-test
   ```

2. **Deploy test resources**:
   ```bash
   kubectl apply -f test-setup.yaml
   ```

3. **Write initial data** (100MB):
   ```bash
   kubectl exec -n cbt-test cbt-test-pod -- \
     dd if=/dev/urandom of=/dev/xvda bs=1M count=100 seek=0
   ```

4. **Create first snapshot**:
   ```bash
   kubectl wait --for=jsonpath='{.status.readyToUse}'=true \
     volumesnapshot/cbt-snap1 -n cbt-test --timeout=60s
   ```

5. **Write additional data** (50MB at different offset):
   ```bash
   kubectl exec -n cbt-test cbt-test-pod -- \
     dd if=/dev/urandom of=/dev/xvda bs=1M count=50 seek=200
   ```

6. **Create second snapshot**:
   ```bash
   kubectl wait --for=jsonpath='{.status.readyToUse}'=true \
     volumesnapshot/cbt-snap2 -n cbt-test --timeout=60s
   ```

7. **Query changed blocks** (requires snapshot-metadata-lister tool):
   ```bash
   # Get allocated blocks in snapshot 1
   snapshot-metadata-lister allocated \
     --namespace cbt-test \
     --snapshot cbt-snap1

   # Get changed blocks between snapshots
   snapshot-metadata-lister delta \
     --namespace cbt-test \
     --base-snapshot cbt-snap1 \
     --target-snapshot cbt-snap2
   ```

## Expected Results

### Snapshot Creation
Both snapshots should be created successfully:
```
NAME        READYTOUSE   SOURCEPVC       RESTORESIZE
cbt-snap1   true         cbt-test-pvc    1Gi
cbt-snap2   true         cbt-test-pvc    1Gi
```

### Changed Block Query
The delta query should show approximately **50MB of changed blocks** at the offset where we wrote the second data chunk (around block 200MB).

### Verified Test Results

✅ **Tested successfully with v1.17.0** on OpenShift 4.20.0-rc.3 (October 7, 2025)

For detailed test results including actual CBT metadata output, see:
- **[TEST-RESULTS.md](TEST-RESULTS.md)** - Full test results with working metadata
- Verified allocated block queries return correct data
- Verified delta queries accurately identify changed blocks

### What You'll Learn
- ✅ How to create block mode volumes
- ✅ How snapshots work with CBT
- ✅ How to query allocated blocks in a snapshot
- ✅ How to identify changed blocks between snapshots
- ✅ The CBT authentication and gRPC flow

## Important Notes

### Block Mode Only
CBT **requires Block volumeMode**. Filesystem volumes won't work:

```yaml
# ✅ This works for CBT
spec:
  volumeMode: Block

# ❌ This won't work for CBT
spec:
  volumeMode: Filesystem
```

### hostpath-csi-driver Limitations

⚠️ **This is a demo driver, not for production:**
- Single node only (no replication)
- No real durability guarantees
- Data stored in local directory
- Performance not optimized
- Security not hardened

**For production**, use:
- ODF/Ceph RBD (see `../cbt/`)
- Cloud provider CSI drivers with CBT support
- Enterprise storage arrays with CBT

### CBT Status in Kubernetes

| Component | Status |
|-----------|--------|
| Kubernetes API | ✅ Alpha in 1.33+ |
| Feature Gates | `ExternalSnapshotMetadata=true` |
| CRDs | Available |
| hostpath-csi-driver | ✅ v1.17.0+ required |
| Production Drivers | ⏳ Varies by vendor |

## Testing with snapshot-metadata-lister

The `snapshot-metadata-lister` tool is included in the external-snapshot-metadata repository:

```bash
# Build the tool
git clone https://github.com/kubernetes-csi/external-snapshot-metadata.git
cd external-snapshot-metadata
make build

# Use the tool
./bin/snapshot-metadata-lister --help
```

## Cleanup

```bash
# Delete test namespace
kubectl delete namespace cbt-test

# Undeploy hostpath driver (if needed)
cd csi-driver-host-path
./deploy/kubernetes-latest/destroy.sh
```

## Troubleshooting

### No SnapshotMetadataService found
```bash
# Check if driver was deployed with SNAPSHOT_METADATA_TESTS=true
kubectl get snapshotmetadataservice

# Check sidecar logs
kubectl logs -l app=csi-hostpathplugin -c external-snapshot-metadata
```

### Snapshot not ready
```bash
# Check snapshot status
kubectl describe volumesnapshot cbt-snap1 -n cbt-test

# Check CSI driver logs
kubectl logs -l app=csi-hostpathplugin -c hostpath
```

### Authentication errors
```bash
# Check service account and RBAC
kubectl get sa -n cbt-test
kubectl get rolebinding -n cbt-test
```

## Next Steps

After understanding CBT basics with this test:

1. **Try the full ODF test** in `../cbt/` for production-like testing
2. **Integrate with backup tools** (e.g., Velero with CBT support)
3. **Test with real workloads** (databases, VMs)
4. **Benchmark performance** gains vs full backups

## References

- [Kubernetes CBT Blog Post](https://kubernetes.io/blog/2025/09/25/csi-changed-block-tracking/)
- [KEP-3314: CSI Changed Block Tracking](https://github.com/kubernetes/enhancements/blob/master/keps/sig-storage/3314-csi-changed-block-tracking/README.md)
- [hostpath-csi-driver CBT Example](https://github.com/kubernetes-csi/csi-driver-host-path/blob/master/docs/example-snapshot-metadata.md)
- [external-snapshot-metadata](https://github.com/kubernetes-csi/external-snapshot-metadata)
- [Full ODF CBT Documentation](../cbt/README.md)

## Comparison to Full ODF Test

See `../cbt/` for production CBT testing with ODF 4.20, including:
- Production-grade Ceph RBD storage
- Distributed, replicated volumes
- Enterprise storage considerations
- Integration with backup tools

---

**Document Version**: 1.0
**Last Updated**: October 6, 2025
**Purpose**: Simplified CBT testing without ODF complexity
