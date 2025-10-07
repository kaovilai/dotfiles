# Installation Guide - hostpath-csi-driver with CBT Support

## Prerequisites

- Kubernetes 1.33+ or OpenShift 4.20+
- Cluster admin access
- `kubectl` or `oc` CLI
- `git` and `make` for building tools

## Quick Start (3 Steps)

```bash
# 1. Install CRD
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshot-metadata/master/client/config/crd/cbt.storage.k8s.io_snapshotmetadataservices.yaml

# 2. Deploy hostpath driver
git clone https://github.com/kubernetes-csi/csi-driver-host-path.git
cd csi-driver-host-path
SNAPSHOT_METADATA_TESTS=true \
HOSTPATHPLUGIN_REGISTRY=registry.k8s.io/sig-storage \
HOSTPATHPLUGIN_TAG=v1.16.1 \
./deploy/kubernetes-latest/deploy.sh

# 3. Run the test
cd /path/to/docs/cbt-no-odf
./test-cbt.sh
```

## Detailed Installation

### Step 1: Install SnapshotMetadataService CRD

This CRD defines the SnapshotMetadataService resource used for CBT:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshot-metadata/master/client/config/crd/cbt.storage.k8s.io_snapshotmetadataservices.yaml
```

Verify:
```bash
kubectl get crd snapshotmetadataservices.cbt.storage.k8s.io
```

### Step 2: Deploy hostpath-csi-driver

Clone the repository:
```bash
git clone https://github.com/kubernetes-csi/csi-driver-host-path.git
cd csi-driver-host-path
```

Deploy with snapshot metadata support **enabled**:

```bash
# Important: SNAPSHOT_METADATA_TESTS=true enables CBT support
SNAPSHOT_METADATA_TESTS=true \
HOSTPATHPLUGIN_REGISTRY=registry.k8s.io/sig-storage \
HOSTPATHPLUGIN_TAG=v1.16.1 \
./deploy/kubernetes-latest/deploy.sh
```

**What this does:**
- Deploys the hostpath CSI driver
- Adds the `external-snapshot-metadata` sidecar to the controller
- Creates RBAC for snapshot metadata access
- Registers a SnapshotMetadataService

**Alternative: Use specific namespace**
```bash
# Deploy to custom namespace
NAMESPACE=csi-hostpath-driver \
SNAPSHOT_METADATA_TESTS=true \
./deploy/kubernetes-latest/deploy.sh
```

### Step 3: Verify Installation

Check CSI driver:
```bash
kubectl get csidriver hostpath.csi.k8s.io
```

Check driver pods (should include external-snapshot-metadata sidecar):
```bash
kubectl get pods -l app=csi-hostpathplugin

# Check containers in the controller pod
kubectl get pod -l app=csi-hostpathplugin -o jsonpath='{.items[0].spec.containers[*].name}' | tr ' ' '\n'
```

Expected containers:
- `hostpath`
- `csi-provisioner`
- `csi-snapshotter`
- `csi-resizer`
- `livenessprobe`
- `external-snapshot-metadata` ← **This is required for CBT**

Check SnapshotMetadataService:
```bash
kubectl get snapshotmetadataservice
```

You should see something like:
```
NAME                    AGE
hostpath-service        2m
```

### Step 4: Verify Feature Gates (OpenShift only)

If using OpenShift, verify the CBT feature gate is enabled:

```bash
oc get featuregate cluster -o yaml | grep ExternalSnapshotMetadata
```

Expected:
```yaml
- name: ExternalSnapshotMetadata
  featureSet: DevPreviewNoUpgrade
```

## Building snapshot-metadata-lister Tool

To query changed blocks, you need the `snapshot-metadata-lister` tool:

```bash
# Clone the repository
git clone https://github.com/kubernetes-csi/external-snapshot-metadata.git
cd external-snapshot-metadata

# Build the tool
make build

# Tool is now available at:
./bin/snapshot-metadata-lister
```

Verify:
```bash
./bin/snapshot-metadata-lister --help
```

## Testing the Installation

Run the automated test:

```bash
cd /path/to/docs/cbt-no-odf
./test-cbt.sh
```

Or manually:

```bash
# Create test resources
kubectl apply -f test-setup.yaml

# Wait for snapshots
kubectl get volumesnapshot -n cbt-test -w

# Query changed blocks (requires snapshot-metadata-lister)
/path/to/snapshot-metadata-lister delta \
  --namespace cbt-test \
  --base-snapshot cbt-snap1 \
  --target-snapshot cbt-snap2
```

## Troubleshooting

### Issue: No external-snapshot-metadata sidecar

**Problem**: The controller pod doesn't have the `external-snapshot-metadata` container.

**Cause**: Driver was deployed without `SNAPSHOT_METADATA_TESTS=true`.

**Solution**:
```bash
cd csi-driver-host-path
./deploy/kubernetes-latest/destroy.sh
SNAPSHOT_METADATA_TESTS=true ./deploy/kubernetes-latest/deploy.sh
```

### Issue: SnapshotMetadataService not found

**Problem**: `kubectl get snapshotmetadataservice` shows no resources.

**Possible causes:**
1. CRD not installed
2. Driver not deployed with CBT support
3. Driver hasn't finished initialization

**Solutions**:
```bash
# Check if CRD exists
kubectl get crd snapshotmetadataservices.cbt.storage.k8s.io

# Check driver logs
kubectl logs -l app=csi-hostpathplugin -c external-snapshot-metadata

# Wait a few seconds and try again
kubectl get snapshotmetadataservice --all-namespaces
```

### Issue: Snapshot not ready

**Problem**: VolumeSnapshot stuck in not ready state.

**Check status**:
```bash
kubectl describe volumesnapshot cbt-snap1 -n cbt-test
```

**Common causes:**
- PVC not bound
- CSI driver not running
- Storage class not available

**Check driver logs**:
```bash
kubectl logs -l app=csi-hostpathplugin -c hostpath
```

### Issue: Authentication errors when using snapshot-metadata-lister

**Problem**: `snapshot-metadata-lister` fails with authentication errors.

**Solution**: Ensure you have proper RBAC:
```bash
# Check service account exists
kubectl get sa cbt-test-sa -n cbt-test

# Check role binding
kubectl get rolebinding snapshot-metadata-reader-binding -n cbt-test

# Use the service account token
kubectl create token cbt-test-sa -n cbt-test
```

### Issue: Block device errors in pod

**Problem**: Pod fails to mount block device.

**Check**:
1. Ensure `volumeMode: Block` in PVC
2. Use `volumeDevices` not `volumeMounts` in pod
3. Check pod security context

**Correct pod spec**:
```yaml
spec:
  containers:
  - name: app
    volumeDevices:      # NOT volumeMounts
    - name: storage
      devicePath: /dev/xvda
```

## Cleanup

Remove test resources:
```bash
kubectl delete namespace cbt-test
```

Remove hostpath driver (if needed):
```bash
cd csi-driver-host-path
./deploy/kubernetes-latest/destroy.sh
```

Remove CRD (if needed):
```bash
kubectl delete crd snapshotmetadataservices.cbt.storage.k8s.io
```

## Differences from Production Setup

| Aspect | This Test Setup | Production (ODF/Ceph) |
|--------|----------------|----------------------|
| Driver | hostpath (demo) | ceph-csi (production) |
| Storage | Local directory | Distributed Ceph cluster |
| Durability | None | Replicated |
| Performance | Single node | Distributed, scaled |
| Use Case | Learning/testing | Production workloads |
| Setup Complexity | Low | High |

## Next Steps

After successful installation:

1. ✅ **Run the test**: `./test-cbt.sh`
2. ✅ **Query changed blocks**: Use `snapshot-metadata-lister`
3. ✅ **Understand the API**: Read KEP-3314
4. ⬆️ **Try with ODF**: See `../cbt/` for production setup

## References

- [hostpath-csi-driver repository](https://github.com/kubernetes-csi/csi-driver-host-path)
- [external-snapshot-metadata repository](https://github.com/kubernetes-csi/external-snapshot-metadata)
- [KEP-3314: CSI Changed Block Tracking](https://github.com/kubernetes/enhancements/blob/master/keps/sig-storage/3314-csi-changed-block-tracking/README.md)
- [Kubernetes CBT Blog Post](https://kubernetes.io/blog/2025/09/25/csi-changed-block-tracking/)

---

**Last Updated**: October 6, 2025
