# CSI Changed Block Tracking (CBT) - Test Results and Documentation

## Executive Summary

**Status**: ❌ **NOT AVAILABLE** (Requires ODF 4.20)
**OpenShift Version**: 4.20.0-rc.3 ✅
**ODF Version**: 4.19.5-rhodf ❌ (Need 4.20+)
**Kubernetes Version**: 1.33.5
**Date Tested**: October 6, 2025

CSI Changed Block Tracking **requires ODF 4.20** for the CephCSI implementation ([RHSTOR-6095](https://issues.redhat.com/browse/RHSTOR-6095)). While OpenShift 4.20 provides the generic CBT infrastructure ([STOR-2364](https://issues.redhat.com/browse/STOR-2364)), the actual RBD driver implementation is not available in ODF 4.19.5.

## Overview

CSI Changed Block Tracking (CBT) is a Kubernetes feature that enables efficient differential backups by identifying changed blocks between volume snapshots. It was proposed in [KEP-3314](https://github.com/kubernetes/enhancements/issues/3314) and introduces a new `SnapshotMetadataService` API.

### Expected Benefits
- Faster incremental backups by copying only changed blocks
- Reduced network bandwidth and storage consumption
- Improved backup/restore performance for large volumes
- Support for versioned replication

## Test Environment

### Cluster Configuration
```bash
Client Version: 4.18.16
Server Version: 4.20.0-rc.3
Kubernetes Version: v1.33.5
```

### ODF Components
```
cephcsi-operator.v4.19.5-rhodf
ocs-operator.v4.19.5-rhodf
odf-operator.v4.19.5-rhodf
rook-ceph-operator.v4.19.5-rhodf
```

### CephCSI Version
```
registry.redhat.io/odf4/cephcsi-rhel9@sha256:7fd1a528cd268be7ffc7d5b000d309526533f8036201e21c1684f3dc34dab75b
```

## What's Available

### 1. API Resources
The CBT API resources are registered in the cluster:

```bash
$ oc api-resources | grep -i snapshot
snapshotmetadataservices      sms        cbt.storage.k8s.io/v1alpha1                   false        SnapshotMetadataService
volumesnapshotclasses         vsclass    snapshot.storage.k8s.io/v1                    false        VolumeSnapshotClass
volumesnapshotcontents        vsc        snapshot.storage.k8s.io/v1                    false        VolumeSnapshotContent
volumesnapshots               vs         snapshot.storage.k8s.io/v1                    true         VolumeSnapshot
```

### 2. CRD Installed
```bash
$ oc get crd snapshotmetadataservices.cbt.storage.k8s.io
NAME                                         CREATED AT
snapshotmetadataservices.cbt.storage.k8s.io   2025-09-30T15:22:29Z
```

### 3. Feature Gate Enabled
```bash
$ oc get featuregate cluster -o yaml | grep ExternalSnapshotMetadata
    - name: ExternalSnapshotMetadata
```

### 4. SnapshotMetadataService API Schema
```bash
$ oc explain snapshotmetadataservice.spec
FIELD: spec <Object>

DESCRIPTION:
    Required.

FIELDS:
  address	<string> -required-
    The TCP endpoint address of the gRPC service.
    Required.

  audience	<string> -required-
    The audience string value expected in a client's authentication token.
    Required.

  caCert	<string> -required-
    Certificate authority bundle needed by the client to validate the service.
    Required.
```

## Version Requirements

### OpenShift 4.20 (STOR-2364) ✅
- Generic CSI CBT infrastructure
- API resources (`snapshotmetadataservices`)
- Feature gate (`ExternalSnapshotMetadata`)
- `external-snapshot-metadata` sidecar container image
- Status: **Available as DevPreview**

### ODF 4.20 (RHSTOR-6095) ❌
- CephCSI implementation of SnapshotMetadata gRPC service
- `rbd snap diff` integration
- Deployment of sidecars to RBD controller pods
- Creation of SnapshotMetadataService CRs
- Status: **Not available in 4.19.5** (requires 4.20+)

## What's Missing in ODF 4.19.5

### 1. No SnapshotMetadataService Instances
```bash
$ oc get snapshotmetadataservice -A
No resources found
```

### 2. Missing external-snapshot-metadata Sidecar
The RBD CSI controller pods contain only 8 containers:
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

**Expected**: A 9th container named `external-snapshot-metadata` should be present to implement the gRPC service.

### 3. No Service Endpoint

```bash
$ oc get svc -n openshift-storage | grep snapshot
# No results - no snapshot metadata service exists
```

### Why It's Not Available

**Two-part implementation:**

1. **Generic OpenShift Infrastructure (STOR-2364)** ✅ Available in OCP 4.20
   - API resources and CRDs
   - Feature gates (`DevPreviewNoUpgrade`)
   - Sidecar container images available
   - Status: **Complete** as of Sept 2025

2. **CephCSI Driver Implementation (RHSTOR-6095)** ❌ Requires ODF 4.20
   - SnapshotMetadata gRPC service in CephCSI
   - Deployment configuration for sidecars in RBD controller
   - SnapshotMetadataService CR auto-creation
   - Integration with `rbd snap diff`
   - Status: **Not available in ODF 4.19.5** (needs 4.20+)

**Conclusion**: Your cluster has the platform support (OpenShift 4.20) but lacks the driver implementation (needs ODF 4.20 upgrade).

## Test Procedure

### Test Setup

1. **Created test namespace**:
```bash
oc create namespace cbt-test
```

2. **Created test PVC**:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cbt-test-pvc
  namespace: cbt-test
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: ocs-storagecluster-ceph-rbd
```

3. **Wrote initial data (100MB)**:
```bash
oc exec cbt-test-pod -- dd if=/dev/urandom of=/data/file1.dat bs=1M count=100
```

4. **Created first snapshot**:
```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: cbt-test-snap1
  namespace: cbt-test
spec:
  volumeSnapshotClassName: ocs-storagecluster-rbdplugin-snapclass
  source:
    persistentVolumeClaimName: cbt-test-pvc
```

5. **Wrote additional data (50MB)**:
```bash
oc exec cbt-test-pod -- dd if=/dev/urandom of=/data/file2.dat bs=1M count=50
```

6. **Created second snapshot**:
```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: cbt-test-snap2
  namespace: cbt-test
spec:
  volumeSnapshotClassName: ocs-storagecluster-rbdplugin-snapclass
  source:
    persistentVolumeClaimName: cbt-test-pvc
```

### Test Results

#### Snapshot Creation: ✅ Success
Both snapshots were created successfully:
```bash
$ oc get volumesnapshot -n cbt-test
NAME              READYTOUSE   SOURCEPVC      RESTORESIZE   SNAPSHOTCLASS                              AGE
cbt-test-snap1    true         cbt-test-pvc   1Gi           ocs-storagecluster-rbdplugin-snapclass     2m
cbt-test-snap2    true         cbt-test-pvc   1Gi           ocs-storagecluster-rbdplugin-snapclass     1m
```

#### SnapshotMetadataService Creation: ⚠️ Partial
A `SnapshotMetadataService` CR can be created, but it's non-functional:
```yaml
apiVersion: cbt.storage.k8s.io/v1alpha1
kind: SnapshotMetadataService
metadata:
  name: test-rbd-snapshot-metadata
spec:
  address: "openshift-storage.rbd.csi.ceph.com-snapshot-metadata:50051"
  audience: "csi-rbd-snapshot-metadata"
  caCert: "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
```

```bash
$ oc get snapshotmetadataservice
NAME                         AGE
test-rbd-snapshot-metadata   1m
```

**Issue**: No backing service exists at the specified address.

#### CBT API Testing: ❌ Failed
No way to query changed blocks between snapshots because:
- No gRPC service endpoint exists
- No external-snapshot-metadata sidecar is deployed
- No implementation of the SnapshotMetadata gRPC service in CephCSI

## Architecture

### Expected CBT Architecture
```
┌─────────────────────────────────────────────────────────────┐
│ Backup Application (e.g., Velero)                           │
└─────────────────┬───────────────────────────────────────────┘
                  │
                  │ gRPC calls with auth token
                  ▼
┌─────────────────────────────────────────────────────────────┐
│ external-snapshot-metadata (sidecar)                         │
│ - Handles authentication                                     │
│ - Proxies requests to CSI driver                            │
└─────────────────┬───────────────────────────────────────────┘
                  │
                  │ Internal gRPC
                  ▼
┌─────────────────────────────────────────────────────────────┐
│ CephCSI RBD Plugin                                          │
│ - Implements SnapshotMetadata gRPC service                  │
│ - Calls rbd snap diff                                       │
└─────────────────┬───────────────────────────────────────────┘
                  │
                  │ rbd snap diff commands
                  ▼
┌─────────────────────────────────────────────────────────────┐
│ Ceph RBD                                                    │
│ - Provides block-level diff information                     │
└─────────────────────────────────────────────────────────────┘
```

### Current Architecture (Missing Components)
```
┌─────────────────────────────────────────────────────────────┐
│ VolumeSnapshot API (Working)                                │
└─────────────────┬───────────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────────┐
│ csi-snapshotter sidecar (Working)                           │
└─────────────────┬───────────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────────┐
│ CephCSI RBD Plugin (No CBT implementation)                  │
└─────────────────┬───────────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────────┐
│ Ceph RBD (rbd snap diff available)                          │
└─────────────────────────────────────────────────────────────┘

❌ Missing: external-snapshot-metadata sidecar
❌ Missing: SnapshotMetadata gRPC service in CephCSI
❌ Missing: SnapshotMetadataService deployment
```

## Implementation Status

### Based on [RHSTOR-6095](https://issues.redhat.com/browse/RHSTOR-6095) Epic

**Planned for**: ODF 4.18
**Current Status**: Not implemented in ODF 4.19.5

### Requirements for Full CBT Support

1. **CephCSI Changes**:
   - Implement `SnapshotMetadata` gRPC service
   - Add support for `GetMetadataAllocated` RPC (single snapshot allocated blocks)
   - Add support for `GetMetadataDelta` RPC (changed blocks between snapshots)
   - Handle flattened snapshots and snapshot limits

2. **Deployment Changes**:
   - Add `external-snapshot-metadata` sidecar to RBD controller deployment
   - Create and configure `SnapshotMetadataService` CR
   - Configure appropriate RBAC and authentication

3. **Ceph Requirements**:
   - Ceph version with `rbd snap diff` support for:
     - Snapshots in trash
     - Group snapshots
   - Image features: `layering,deep-flatten,exclusive-lock,object-map,fast-diff`

## Known Limitations (When Implemented)

### Snapshot Flattening Issues

CephCSI flattens snapshots in certain scenarios, which breaks CBT:

1. **Horizontal Limit**:
   - MinSnapshotOnImage: 250 snapshots (starts flattening)
   - MaxSnapshotOnImage: 450 snapshots (aggressive flattening)

2. **Vertical Limit**:
   - RbdHardMaxCloneDepth: 8 levels
   - RbdSoftMaxCloneDepth: 4 levels

3. **Scenarios That Trigger Flattening**:
   - Snapshot → Restore → Delete Snapshot (snapshot goes to trash)
   - Deep clone chains exceeding limits
   - Too many snapshots on a single parent image

### Workarounds (Proposed in Epic)

1. **Special VolumeSnapshotClass**:
   - Create snapshots that cannot be flattened
   - Block parent PVC deletion when such snapshots exist
   - Support ROX (ReadOnlyMany) restored PVCs

2. **Store Diffs in Snapshot Metadata**:
   - Store block diffs when flattening occurs
   - Traverse and merge diffs for CBT queries
   - Increases complexity and storage overhead

## Testing Commands

### Check CBT Availability
```bash
# Check if API resources exist
oc api-resources | grep snapshotmetadata

# Check if feature gate is enabled
oc get featuregate cluster -o yaml | grep ExternalSnapshotMetadata

# Check for deployed services
oc get snapshotmetadataservice -A

# Check RBD controller containers
oc get pod -n openshift-storage \
  -l app=csi-rbdplugin \
  -o jsonpath='{.items[0].spec.containers[*].name}'
```

### Create Test Snapshots
```bash
# See test-setup.yaml for complete manifests

# Create namespace
oc create namespace cbt-test

# Apply PVC
oc apply -f pvc.yaml

# Apply test pod
oc apply -f pod.yaml

# Create snapshots
oc apply -f snapshot1.yaml
oc apply -f snapshot2.yaml

# Check snapshot status
oc get volumesnapshot -n cbt-test
```

### Cleanup Test Resources
```bash
# Delete test namespace (removes all resources)
oc delete namespace cbt-test

# Delete test SnapshotMetadataService
oc delete snapshotmetadataservice test-rbd-snapshot-metadata
```

## Monitoring and Observability

When CBT is implemented, monitor:

### Metrics to Watch
- Number of `SnapshotMetadataService` instances
- gRPC call latency and success rates
- Snapshot flattening frequency
- Clone depth per volume

### Logs to Check
```bash
# CephCSI RBD controller logs
oc logs -n openshift-storage -l app=csi-rbdplugin -c csi-rbdplugin

# external-snapshot-metadata sidecar logs (when available)
oc logs -n openshift-storage -l app=csi-rbdplugin -c external-snapshot-metadata
```

## Use Cases

### When to Use CBT (Once Available)

1. **Frequent Backups**:
   - Daily or hourly backups of large volumes
   - Only changed blocks need to be backed up

2. **Disaster Recovery**:
   - Efficient replication to secondary sites
   - Versioned snapshots with minimal storage

3. **VM Backup**:
   - OpenShift Virtualization VM backups
   - Incremental disk image backups

4. **Database Backups**:
   - Large database volumes
   - Point-in-time recovery with minimal overhead

### When NOT to Use CBT

1. **Small Volumes**:
   - Overhead may exceed benefits for volumes < 10GB

2. **High Change Rate**:
   - If > 50% of blocks change between snapshots
   - Full backup may be more efficient

3. **Flattening Scenarios**:
   - Deep clone chains
   - Many snapshots on single parent
   - CBT breaks when snapshots are flattened

## Future Work

### Upstream Dependencies
- [kubernetes-csi/external-snapshot-metadata](https://github.com/kubernetes-csi/external-snapshot-metadata)
- [Ceph Tracker Issue #65720](https://tracker.ceph.com/issues/65720) - rbd snap diff for trash/group snapshots

### ODF Implementation Tasks
1. Integrate external-snapshot-metadata sidecar
2. Implement SnapshotMetadata gRPC service in CephCSI
3. Handle snapshot flattening scenarios
4. Deploy SnapshotMetadataService CRs automatically
5. Add support for ROX restored PVCs
6. Implement diff storage for flattened snapshots (optional)

### Testing Requirements
1. Functional testing of GetMetadataAllocated
2. Functional testing of GetMetadataDelta
3. Performance benchmarks vs full backups
4. Flattening scenario testing
5. Scale testing (100s of snapshots)

## References

- [KEP-3314: CSI Differential Snapshot](https://github.com/kubernetes/enhancements/issues/3314)
- [RHSTOR-6095: Changed Block Tracking for RBD](https://issues.redhat.com/browse/RHSTOR-6095)
- [external-snapshot-metadata GitHub](https://github.com/kubernetes-csi/external-snapshot-metadata)
- [Ceph rbd snap diff](https://docs.ceph.com/en/latest/rbd/rbd-snapshot/#snapshot-layering)

## Conclusion

While OpenShift 4.20 and ODF 4.19.5 have the **API infrastructure** for CSI Changed Block Tracking, the **actual implementation is missing**:

- ✅ CRDs installed
- ✅ Feature gates enabled
- ✅ API resources available
- ❌ No gRPC service implementation
- ❌ No external-snapshot-metadata sidecar
- ❌ No SnapshotMetadataService deployments

**Recommendation**: Upgrade to ODF 4.20 when available. The OpenShift 4.20 platform is ready, only the ODF driver implementation is pending.

### Related Issues
- [STOR-2364](https://issues.redhat.com/browse/STOR-2364) - OpenShift CBT infrastructure (✅ Complete in OCP 4.20)
- [RHSTOR-6095](https://issues.redhat.com/browse/RHSTOR-6095) - CephCSI CBT implementation (⏳ Requires ODF 4.20)

---

**Document Version**: 1.0
**Last Updated**: October 6, 2025
**Tested By**: Claude Code
**Cluster**: migt2-82dx6
