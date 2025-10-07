# ODF 4.19.5 Uninstall and 4.20 Reinstall Log

**Date**: October 6, 2025
**Cluster**: migt2-82dx6 (Test cluster - OpenShift 4.20.0-rc.3)
**Goal**: Remove ODF 4.19.5 and install ODF 4.20 from source

## Pre-Uninstall State

### Current Installation
```bash
# ODF Version
$ oc get csv -n openshift-storage | grep odf-operator
odf-operator.v4.19.5-rhodf   OpenShift Data Foundation  4.19.5-rhodf  Failed

# All CSVs showing Failed status:
$ oc get csv -n openshift-storage
NAME                                    DISPLAY                            VERSION        PHASE
cephcsi-operator.v4.19.5-rhodf          CephCSI operator                   4.19.5-rhodf   Failed
mcg-operator.v4.19.5-rhodf              NooBaa Operator                    4.19.5-rhodf   Failed
ocs-client-operator.v4.19.5-rhodf       OpenShift Data Foundation Client   4.19.5-rhodf   Failed
ocs-operator.v4.19.5-rhodf              OpenShift Container Storage        4.19.5-rhodf   Failed
odf-csi-addons-operator.v4.19.5-rhodf   CSI Addons                         4.19.5-rhodf   Failed
odf-dependencies.v4.19.5-rhodf          Data Foundation Dependencies       4.19.5-rhodf   Failed
odf-operator.v4.19.5-rhodf              OpenShift Data Foundation          4.19.5-rhodf   Failed
odf-prometheus-operator.v4.19.5-rhodf   Prometheus Operator                4.19.5-rhodf   Failed
recipe.v4.19.5-rhodf                    Recipe                             4.19.5-rhodf   Failed
rook-ceph-operator.v4.19.5-rhodf        Rook-Ceph                          4.19.5-rhodf   Failed

# StorageCluster (appears healthy despite CSV failures)
$ oc get storagecluster -n openshift-storage
NAME                 AGE    PHASE   EXTERNAL   CREATED AT             VERSION
ocs-storagecluster   6d6h   Ready              2025-09-30T15:57:06Z   4.19.5

# Subscriptions
$ oc get subscription -n openshift-storage
NAME                                                                         PACKAGE                   SOURCE              CHANNEL
cephcsi-operator-stable-4.19-redhat-operators-openshift-marketplace          cephcsi-operator          redhat-operators    stable-4.19
ocs-client-operator-stable-4.19-redhat-operators-openshift-marketplace       ocs-client-operator       redhat-operators    stable-4.19
ocs-operator-stable-4.19-redhat-operators-openshift-marketplace              ocs-operator              redhat-operators    stable-4.19
ocs-subscription                                                             odf-operator              redhat-operators    stable-4.19
odf-csi-addons-operator-stable-4.19-redhat-operators-openshift-marketplace   odf-csi-addons-operator   redhat-operators    stable-4.19
odf-dependencies                                                             odf-dependencies          redhat-operators    stable-4.19
odf-operator                                                                 odf-operator              odf-catalogsource   alpha
odf-prometheus-operator-stable-4.19-redhat-operators-openshift-marketplace   odf-prometheus-operator   redhat-operators    stable-4.19
recipe-stable-4.19-redhat-operators-openshift-marketplace                    recipe                    redhat-operators    stable-4.19
rook-ceph-operator-stable-4.19-redhat-operators-openshift-marketplace        rook-ceph-operator        redhat-operators    stable-4.19

# CatalogSources
$ oc get catalogsource -n openshift-marketplace | grep odf
odf-catalogsource          OpenShift Data Foundation   grpc   Red Hat     2m47s

# Resources
- Pods: 46 running in openshift-storage
- PVs: 3 (local-pv-45b99be7, local-pv-a26d31d5, local-pv-c64bb5ea)
- Storage Classes: 4 (local-block-ocs, ocs-storagecluster-ceph-rbd, ocs-storagecluster-ceph-rgw, ocs-storagecluster-cephfs)
```

## Uninstall Procedure

Based on Red Hat documentation for ODF 4.19+:
- Use `storagecluster` (not `storagesystem` from 4.18 and earlier)
- ODF 4.19+ requires cleaning OSD metadata
- Reference: https://access.redhat.com/articles/6525111

### Step 1: Delete StorageCluster

```bash
oc delete -n openshift-storage storagecluster --all --wait=true
```

This command:
- Deletes the StorageCluster CR
- Triggers graceful shutdown of Ceph cluster
- Removes storage resources
- Waits for complete deletion

### Step 2: Delete Subscriptions

```bash
oc delete subscription -n openshift-storage --all
```

### Step 3: Delete CSVs

```bash
oc delete csv -n openshift-storage --all
```

### Step 4: Delete Custom CatalogSource

```bash
oc delete catalogsource odf-catalogsource -n openshift-marketplace
```

### Step 5: Clean Up Namespace

```bash
# Check for remaining resources
oc get all -n openshift-storage

# Delete any remaining resources
oc delete all --all -n openshift-storage

# Note: Do NOT delete the namespace itself - OLM manages it
```

### Step 6: Clean Up Storage Classes (Optional)

```bash
# Only if planning fresh install
oc delete storageclass ocs-storagecluster-ceph-rbd
oc delete storageclass ocs-storagecluster-ceph-rgw
oc delete storageclass ocs-storagecluster-cephfs
```

### Step 7: Wait for Complete Cleanup

```bash
# Verify no ODF pods remain
oc get pods -n openshift-storage

# Verify CSVs are gone
oc get csv -n openshift-storage

# Verify PVs are released (may take time)
oc get pv | grep openshift-storage
```

## Install ODF 4.20 from Source

### Prerequisites

```bash
cd ~/git/odf-operator
git checkout release-4.20
git pull origin release-4.20
```

### Build Process

The Makefile provides `deploy-with-olm` target which:
1. Creates CatalogSource with your built images
2. Creates Namespace
3. Creates OperatorGroup
4. Creates Subscription

### Expected Steps

```bash
cd ~/git/odf-operator

# This will build and deploy via OLM
make deploy-with-olm
```

**Note**: This requires:
- Built images (docker-build, bundle-build, catalog-build)
- Images pushed to registry
- Correct image references in environment variables

## Execution Log

### Uninstall Execution

**Completed**: October 6, 2025

1. **Delete StorageCluster** ✓
   - Command: `oc delete -n openshift-storage storagecluster --all --wait=true`
   - Result: Took ~10 minutes, required finalizer removal due to operator pods deleted first
   - Fix applied: `oc patch storagecluster ocs-storagecluster -n openshift-storage --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'`

2. **Delete Subscriptions** ✓
   - All 10 subscriptions removed successfully

3. **Delete CSVs** ✓
   - All 10 CSVs deleted

4. **Delete CatalogSource** ✓
   - Custom odf-catalogsource removed

5. **Clean Up Resources** ✓
   - All pods terminated
   - PVCs deleted
   - Storage classes removed (except local-block-ocs for worker nodes)

### Install Execution

**Completed**: October 6, 2025 (23:37 UTC)

#### Build Architecture Issue

**Problem**: Initial build created ARM64 images (Mac architecture), but cluster requires AMD64.

**Solution**:
1. Cross-compiled Go binary: `GOOS=linux GOARCH=amd64 make go-build`
2. Rebuilt all images with `--platform linux/amd64` using podman (avoids QEMU issues)

#### Images Built and Pushed to ghcr.io/kaovilai

```bash
# Operator
GOOS=linux GOARCH=amd64 make go-build
docker buildx build --platform linux/amd64 --push -f Dockerfile.amd64 -t ghcr.io/kaovilai/odf-operator:v4.20.0-test .

# Bundles (dependencies, cnsa, operator)
docker buildx build --platform linux/amd64 --push -f bundle.Dockerfile -t ghcr.io/kaovilai/odf-operator-bundle:v4.20.0-test .
docker buildx build --platform linux/amd64 --push -f dependencies.Dockerfile -t ghcr.io/kaovilai/odf-dependencies-bundle:v4.20.0-test .
docker buildx build --platform linux/amd64 --push -f cnsa-dependencies.Dockerfile -t ghcr.io/kaovilai/cnsa-dependencies-bundle:v4.20.0-test .

# Catalog
make catalog
docker buildx build --platform linux/amd64 --push -f catalog.Dockerfile -t ghcr.io/kaovilai/odf-operator-catalog:v4.20.0-test .
```

#### Deployment Steps

1. **Create CatalogSource** ✓
   - YAML: `docs/cbt/odf-4.20-catalogsource.yaml`
   - Image: `ghcr.io/kaovilai/odf-operator-catalog:v4.20.0-test`

2. **Create Subscription** ✓
   - YAML: `docs/cbt/odf-4.20-subscription.yaml`
   - Channel: alpha

3. **Fix OperatorGroup Conflict** ✓
   - Issue: Multiple OperatorGroups caused CSV failures
   - Fix: Deleted all, created single OperatorGroup for openshift-storage

4. **Create StorageCluster** ✓
   ```bash
   apiVersion: ocs.openshift.io/v1
   kind: StorageCluster
   metadata:
     name: ocs-storagecluster
     namespace: openshift-storage
   spec:
     storageDeviceSets:
     - count: 1
       dataPVCTemplate:
         spec:
           accessModes:
           - ReadWriteOnce
           resources:
             requests:
               storage: 70Gi
           storageClassName: local-block-ocs
           volumeMode: Block
       name: ocs-deviceset-0
       portable: true
       replica: 3
   ```

## Verification Results

### CSVs Status ✓

**All 11 CSVs in Succeeded state**:

```bash
cephcsi-operator.v4.20.0
csi-addons.v0.13.0
mcg-operator.v5.20.0
noobaa-operator.v5.20.0
ocs-client-operator.v4.20.0
ocs-operator.v4.20.0
odf-csi-addons-operator.v4.20.0
odf-external-snapshotter-operator.v4.20.0
odf-operator.v4.20.0
odf-prometheus-operator.v4.20.0
rook-ceph-operator.v4.20.0
```

### Operator Pods ✓

**All operators running successfully** (33 pods total in openshift-storage)

Key operators:
- cephcsi-operator: `quay.io/ocs-dev/cephcsi-operator:main-f73fca8`
- odf-external-snapshotter-operator: Running
- rook-ceph-operator: Running

### StorageCluster ✓

**Status**: Progressing (Ceph cluster deploying)

```yaml
phase: Progressing
conditions:
- message: 'CephCluster is creating: Configuring Ceph Mons'
  reason: ClusterStateCreating
  status: "True"
  type: Progressing
```

### CBT Investigation ❌

**RBD Controller Containers: 8 (not 9)**

```
csi-rbdplugin
csi-provisioner
csi-resizer
csi-attacher
csi-snapshotter
csi-addons
csi-omap-generator
log-rotator
```

**Missing**: `external-snapshot-metadata` sidecar

**SnapshotMetadataService**: No instances exist (CRD present)

**Root Cause**: CBT support requires manual configuration:

1. **PR Reference**: [ceph-csi-operator#274](https://github.com/ceph/ceph-csi-operator/pull/274)
   - Merged: July 29, 2025
   - Feature: Alpha RBD snapshot metadata sidecar
   - Implementation: KEP-3314

2. **Requirements for CBT Enablement**:
   - SnapshotMetadataService CR must exist with same name as Driver CR (`openshift-storage.rbd.csi.ceph.com`)
   - Service to expose RBD driver pod
   - TLS certificates provisioned
   - TLS secret volume configured in Driver CR spec

3. **Current State**:
   - Driver CR exists: `openshift-storage.rbd.csi.ceph.com`
   - Driver CR spec: Empty (`spec: {}`)
   - No SnapshotMetadataService CR
   - No TLS configuration

**Conclusion**: CBT is NOT available in ODF 4.20 as currently deployed.

**Version Analysis**:

- Red Hat fork: `red-hat-storage/ceph-csi-operator` branch `release-4.20`
- Deployed image commit: `f73fca8a` (too old, 7 commits before CBT)
- CBT merge commit: `840b82eb` (merged July 29, 2025, **7 commits AFTER f73fca8a**)
- Available images: [quay.io/ocs-dev/cephcsi-operator-bundle](https://quay.io/repository/ocs-dev/cephcsi-operator-bundle?tab=tags) only contains tags up to `main-f73fca8`
- CBT feature: ❌ **NOT in deployed image** (not yet in ODF 4.20 release images)

**Why CBT is Missing**: The cephcsi-operator image used in ODF 4.20 (`quay.io/ocs-dev/cephcsi-operator:main-f73fca8`) was built before the CBT feature was merged into release-4.20 branch.

## CBT Enablement Options

### Option 1: Wait for Official Release

Wait for Red Hat to publish updated ODF 4.20 images that include commit 840b82eb or later.

### Option 2: Build Custom Image (For Testing)

Build cephcsi-operator from `release-4.20` branch HEAD (commit cb3983dd, includes CBT merge 840b82eb).

#### Prerequisites

```bash
# Install required tools
brew install podman  # Recommended - avoids QEMU cross-compilation issues
# Or: brew install docker
```

#### Build Operator Image

```bash
# Clone the Red Hat fork
cd ~/git
git clone --branch release-4.20 https://github.com/red-hat-storage/ceph-csi-operator.git
cd ceph-csi-operator

# Verify we have CBT commit
git log --oneline --grep="snapshot.*metadata" | head -5
# Should show: 840b82eb Merge pull request #274 from iPraveenParihar/dev-preview/rbd-snapshot-metadata

# Set build variables
export IMAGE_REGISTRY=ghcr.io
export REGISTRY_NAMESPACE=kaovilai  # Change to your registry namespace
export IMAGE_TAG=release-4.20-cb3983dd
export IMG=${IMAGE_REGISTRY}/${REGISTRY_NAMESPACE}/ceph-csi-operator:${IMAGE_TAG}

# Build for AMD64 (OpenShift cluster architecture)
# Using podman (recommended - avoids QEMU emulation issues on Mac)
podman build \
  --platform linux/amd64 \
  -t ${IMG} .

# Push the image
podman push ${IMG}

# Verify the image was pushed
podman manifest inspect ${IMG}
```

#### Build Bundle Image (Optional)

If you need to create a complete catalog source:

```bash
# Build bundle
export BUNDLE_IMG=${IMAGE_REGISTRY}/${REGISTRY_NAMESPACE}/ceph-csi-operator-bundle:${IMAGE_TAG}

make bundle IMG=${IMG}
docker buildx build \
  --platform linux/amd64 \
  --push \
  -f bundle.Dockerfile \
  -t ${BUNDLE_IMG} .
```

#### Deploy Custom Operator Image

**Method 1: Patch Existing CSV**

```bash
# Get current CSV name
CSV_NAME=$(oc get csv -n openshift-storage -o name | grep cephcsi-operator)

# Patch the deployment image
oc patch ${CSV_NAME} -n openshift-storage \
  --type='json' \
  -p="[{
    \"op\": \"replace\",
    \"path\": \"/spec/install/spec/deployments/0/spec/template/spec/containers/0/image\",
    \"value\": \"${IMG}\"
  }]"

# Delete operator pod to force recreation with new image
oc delete pod -n openshift-storage -l app.kubernetes.io/name=ceph-csi-operator

# Verify new image is running
oc get pod -n openshift-storage -l app.kubernetes.io/name=ceph-csi-operator \
  -o jsonpath='{.items[0].spec.containers[0].image}'
```

**Method 2: Update Subscription (if using custom catalog)**

If you built a bundle and catalog source:

```bash
# Create new CatalogSource
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: cephcsi-operator-custom
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${CATALOG_IMG}
  displayName: Ceph CSI Operator (Custom - CBT)
  publisher: kaovilai
  updateStrategy:
    registryPoll:
      interval: 10m
EOF

# Update subscription to use new catalog
oc patch subscription cephcsi-operator-stable-4.20-redhat-operators-openshift-marketplace \
  -n openshift-storage \
  --type='merge' \
  -p '{"spec":{"source":"cephcsi-operator-custom","sourceNamespace":"openshift-marketplace"}}'
```

**Method 3: Direct Deployment Edit**

```bash
# Edit the deployment directly (not recommended - CSV will revert changes)
oc edit deployment -n openshift-storage ceph-csi-operator-controller-manager

# Change the image in:
# spec.template.spec.containers[0].image
```

#### Verify Custom Operator Deployment

```bash
# Check operator pod is running with new image
oc get pod -n openshift-storage -l app.kubernetes.io/name=ceph-csi-operator \
  -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'
# Should show: ghcr.io/kaovilai/ceph-csi-operator:release-4.20-cb3983dd

# Check operator logs for any errors
oc logs -n openshift-storage -l app.kubernetes.io/name=ceph-csi-operator --tail=50

# Verify SnapshotMetadataService CRD is available (included in operator)
oc get crd snapshotmetadataservices.cbt.storage.k8s.io
# Should show: snapshotmetadataservices.cbt.storage.k8s.io

# Check if operator recognizes the CRD
oc get snapshotmetadataservice -A
# Should show: No resources found (expected - we haven't created any yet)
```

> ⚠️ **Alpha Feature**: CBT is currently in alpha and should only be used for testing

---

## Part 7: CBT Deployment Execution (October 6, 2025 - Continued Session)

### Completed Steps

#### 1. Clone and Build Custom Operator ✅

```bash
# Cloned Red Hat fork
cd ~/git
git clone --branch release-4.20 https://github.com/red-hat-storage/ceph-csi-operator.git
cd ceph-csi-operator

# Verified CBT commit present
git log --oneline --grep="snapshot.*metadata" | head -5
# Output: 840b82eb Merge pull request #274 from iPraveenParihar/dev-preview/rbd-snapshot-metadata

# Built for AMD64 using podman (avoids QEMU issues on Mac)
podman build --platform linux/amd64 -t ghcr.io/kaovilai/ceph-csi-operator:release-4.20-cb3983dd .
# Build completed successfully after ~2 minutes

# Pushed to registry
podman push ghcr.io/kaovilai/ceph-csi-operator:release-4.20-cb3983dd
# Image made public via GitHub web interface
```

#### 2. Deploy Custom Operator ✅

```bash
# Patched CSV to use custom image
CSV_NAME=$(oc get csv -n openshift-storage -o name | grep cephcsi-operator)
oc patch ${CSV_NAME} -n openshift-storage --type='json' \
  -p='[{"op": "replace", "path": "/spec/install/spec/deployments/0/spec/template/spec/containers/0/image", "value": "ghcr.io/kaovilai/ceph-csi-operator:release-4.20-cb3983dd"}]'
# Output: clusterserviceversion.operators.coreos.com/cephcsi-operator.v4.20.0 patched

# Verified deployment
oc get pod -n openshift-storage ceph-csi-controller-manager-6f885c99b9-tg6kg \
  -o jsonpath='{.spec.containers[0].image}'
# Output: ghcr.io/kaovilai/ceph-csi-operator:release-4.20-cb3983dd
```

#### 3. Install SnapshotMetadataService CRD ✅

```bash
# Applied CRD from upstream
oc apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshot-metadata/main/client/config/crd/cbt.storage.k8s.io_snapshotmetadataservices.yaml
# Output: customresourcedefinition.apiextensions.k8s.io/snapshotmetadataservices.cbt.storage.k8s.io configured

# Verified CRD exists
oc get crd snapshotmetadataservices.cbt.storage.k8s.io
# Output: NAME                                              CREATED AT
#         snapshotmetadataservices.cbt.storage.k8s.io      2025-10-07T01:50:00Z
```

#### 4. Current State

**Operator Status**:
- Custom image deployed: `ghcr.io/kaovilai/ceph-csi-operator:release-4.20-cb3983dd`
- Pod ready: `ceph-csi-controller-manager-6f885c99b9-tg6kg` (1/1 Running)
- Operator recognizes SnapshotMetadataService CRD
- Operator logs show permission errors (expected - RBAC not configured yet)

**RBD Controller Status**:
- Current containers: 8 (not yet 9)
- Container list: csi-rbdplugin, csi-provisioner, csi-resizer, csi-attacher, csi-snapshotter, csi-addons, csi-omap-generator, log-rotator
- Missing: `external-snapshot-metadata` (will appear after completing manual setup)

**CRD Status**:
- SnapshotMetadataService CRD installed: ✅
- No SnapshotMetadataService instances yet: ✅ (expected)

### Remaining Steps

To enable CBT and get the 9th container:

1. **Grant RBAC permissions** - Service account needs permissions to manage SnapshotMetadataService resources
2. **Create Service** - Expose RBD driver endpoint for snapshot metadata
3. **Generate TLS certificates** - Required for secure communication
4. **Create SnapshotMetadataService CR** - Triggers deployment of external-snapshot-metadata sidecar
5. **Verify 9 containers** - Confirm CBT is fully operational

---

**Manual Setup Steps** (remaining tasks):

Based on [official documentation](https://github.com/red-hat-storage/ceph-csi-operator/blob/release-4.20/docs/features/rbd-snapshot-metadata.md):

### Step 1: Install SnapshotMetadataService CRD

```bash
kubectl create -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshot-metadata/refs/tags/v0.1.0/client/config/crd/cbt.storage.k8s.io_snapshotmetadataservices.yaml
```

### Step 2: Create Service for RBD Driver

```yaml
apiVersion: v1
kind: Service
metadata:
  name: openshift-storage-rbd-metadata
  namespace: openshift-storage
spec:
  ports:
  - name: snapshot-metadata-port
    port: 6443
    protocol: TCP
    targetPort: 50051  # Required: sidecar gRPC server port
  selector:
    app: openshift-storage.rbd.csi.ceph.com-ctrlplugin
  type: ClusterIP
```

### Step 3: Generate TLS Certificates

Certificates must be valid for the service domain: `openshift-storage-rbd-metadata.openshift-storage`

```bash
# Generate certificates (example using openssl)
# ... certificate generation commands ...

# Create TLS secret
kubectl create secret tls openshift-storage.rbd.csi.ceph.com \
  --namespace=openshift-storage \
  --cert=server-cert.pem \
  --key=server-key.pem
```

### Step 4: Create SnapshotMetadataService CR

**Critical**: CR name must match Driver CR name: `openshift-storage.rbd.csi.ceph.com`

```yaml
apiVersion: cbt.storage.k8s.io/v1alpha1
kind: SnapshotMetadataService
metadata:
  name: openshift-storage.rbd.csi.ceph.com
spec:
  address: openshift-storage-rbd-metadata.openshift-storage:6443
  audience: openshift-storage.rbd.csi.ceph.com
  caCert: <base64-encoded-ca-bundle>
```

### Step 5: Update Driver CR with TLS Volume

**Critical requirements**:
- Volume and mount name must be **exactly** `tls-key`
- Mount path must be **exactly** `/tmp/certificates`

```yaml
apiVersion: csi.ceph.io/v1
kind: Driver
metadata:
  name: openshift-storage.rbd.csi.ceph.com
  namespace: openshift-storage
spec:
  controllerPlugin:
    volumes:
    - mount:
        mountPath: /tmp/certificates  # Required path
        name: tls-key
      volume:
        name: tls-key  # Required name
        secret:
          secretName: openshift-storage.rbd.csi.ceph.com
```

### Step 6: Restart Operator (if needed)

> ⚠️ **Note**: If SnapshotMetadataService CR is created after adding volume configuration,
> manually restart ceph-csi-operator pod.

### Step 7: Verify Deployment

```bash
# Check RBD controller has 9 containers
oc get pod -n openshift-storage -l app=openshift-storage.rbd.csi.ceph.com-ctrlplugin -o jsonpath='{.items[0].spec.containers[*].name}'

# Expected containers:
# - csi-rbdplugin
# - csi-provisioner
# - csi-resizer
# - csi-attacher
# - csi-snapshotter
# - csi-addons
# - csi-omap-generator
# - log-rotator
# - external-snapshot-metadata  ← This should now be present
```

### Step 8: Run CBT Tests

```bash
# Run CBT test suite
# ... test commands ...
```

---

## Verification Checklist

- [x] CSVs in Succeeded state (11/11)
- [x] StorageCluster created
- [x] All operator pods Running
- [ ] Storage classes created (waiting for Ceph cluster ready)
- [ ] RBD controller has 9 containers (8/9 - missing external-snapshot-metadata)
- [ ] SnapshotMetadataService CR exists
- [ ] CBT configuration applied
- [ ] CBT test passes

## References

### Documentation

- [ODF Uninstall Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.19/html/deploying_openshift_data_foundation_on_any_platform/uninstalling_openshift_data_foundation)
- [Uninstalling ODF Internal Mode](https://access.redhat.com/articles/6525111)
- [KEP-3314: Changed Block Tracking](https://github.com/kubernetes/enhancements/blob/master/keps/sig-storage/3314-csi-changed-block-tracking/README.md)

### Repositories

- [ODF Operator (Red Hat)](https://github.com/red-hat-storage/odf-operator/tree/release-4.20)
- [Ceph CSI Operator (Red Hat)](https://github.com/red-hat-storage/ceph-csi-operator/tree/release-4.20) - Release branch
- [Ceph CSI Operator (Upstream)](https://github.com/ceph/ceph-csi-operator) - Original CBT implementation
- [ODF 4.20 Images (Quay)](https://quay.io/repository/ocs-dev/cephcsi-operator-bundle?tab=tags) - Only contains up to `main-f73fca8` (no CBT)

### Key Commits

- [cb3983dd](https://github.com/red-hat-storage/ceph-csi-operator/commit/cb3983dd) - Current HEAD of release-4.20 (includes CBT)
- [840b82eb](https://github.com/red-hat-storage/ceph-csi-operator/commit/840b82eb) - CBT Implementation (PR #274, July 29, 2025)
- [f73fca8a](https://github.com/red-hat-storage/ceph-csi-operator/commit/f73fca8a) - Deployed in ODF 4.20 (7 commits before CBT, no CBT)

### CBT Feature Documentation

- [RBD Snapshot Metadata Sidecar Guide](https://github.com/red-hat-storage/ceph-csi-operator/blob/release-4.20/docs/features/rbd-snapshot-metadata.md)
- [external-snapshot-metadata CRD](https://raw.githubusercontent.com/kubernetes-csi/external-snapshot-metadata/refs/tags/v0.1.0/client/config/crd/cbt.storage.k8s.io_snapshotmetadataservices.yaml)

---

**Document Version**: 4.0
**Status**: ODF 4.20 Deployed - CBT Custom Operator Deployed ✅ - Manual Setup In Progress (3/8 steps complete)
**Last Updated**: October 7, 2025 (continued session)
