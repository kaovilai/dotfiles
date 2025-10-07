# CSI Changed Block Tracking (CBT) Investigation

Documentation of the investigation to enable Changed Block Tracking (CBT) in OpenShift Data Foundation for efficient incremental backups.

## Quick Summary

**Current Status** (October 6, 2025):

- ✅ OpenShift 4.20 deployed with CBT infrastructure
- ✅ ODF 4.20 successfully deployed from source
- ❌ CBT feature NOT available in ODF 4.20 release images
- 🔨 Workaround available: Build custom cephcsi-operator from release-4.20 branch

**Why CBT is Missing**: The cephcsi-operator image in ODF 4.20 (`quay.io/ocs-dev/cephcsi-operator:main-f73fca8`) was built 7 commits before the CBT feature was merged into the release-4.20 branch.

## Reading Guide

Read these documents in order to understand the full journey:

### 1. **What is CBT?** → `Changed-Block-Tracking.md`

Start here to understand what CBT is and why it matters:

- Feature overview and benefits (faster incremental backups)
- Technical architecture
- Initial test results from ODF 4.19.5
- Why we needed ODF 4.20

**Key Takeaway**: CBT requires both OpenShift 4.20 (for API) and ODF 4.20 (for RBD driver implementation)

---

### 2. **The Complete Journey** → `ODF-UNINSTALL-REINSTALL.md` ⭐ **START HERE FOR DETAILS**

This is the **primary document** with the complete investigation:

#### Part 1: Uninstall ODF 4.19.5

- Why uninstall was needed
- Step-by-step uninstall procedure
- Lessons learned

#### Part 2: Install ODF 4.20 from Source

- Building ODF operator from GitHub
- Cross-platform build issues (ARM64 → AMD64)
- All images built and pushed
- Deployment with custom CatalogSource

#### Part 3: CBT Investigation

- Why RBD controller only has 8 containers (expected 9)
- Finding the missing `external-snapshot-metadata` sidecar
- Commit timeline analysis
- Repository forensics

#### Part 4: Root Cause Analysis

- Confirmed CBT is implemented in `red-hat-storage/ceph-csi-operator` PR #274
- Image timeline: f73fca8a (deployed) vs 840b82eb (CBT merge)
- Quay registry only has images up to f73fca8a
- **Conclusion**: Need custom build to get CBT

#### Part 5: CBT Enablement Options

- Option 1: Wait for official release
- Option 2: Build custom cephcsi-operator (complete instructions)
- Manual setup steps for CBT (TLS, Service, SnapshotMetadataService CR)

#### Part 6: References

- All GitHub repositories and commits
- Official documentation links
- Build and deployment procedures

**Recommended**: Read this document completely to understand the investigation methodology and findings.

---

### 3. **Testing Resources** → `test-setup.yaml` and `test-commands.sh`

Kubernetes manifests and scripts for testing CBT **once it's enabled**:

- Test namespace and PVC
- VolumeSnapshot resources
- SnapshotMetadataService CR example
- Automated test commands

**Note**: Cannot use these until CBT is enabled via custom build.

---

### 4. **Deployment Artifacts** → `odf-4.20-catalogsource.yaml`, `odf-4.20-subscription.yaml`

YAML manifests used during ODF 4.20 installation:

- Custom CatalogSource pointing to ghcr.io/kaovilai images
- Subscription configuration
- Reference for reproducing the deployment

---

## TL;DR - What You Need to Know

1. **CBT is an alpha feature** for efficient incremental backups
2. **ODF 4.20 release images DON'T include CBT** (too old)
3. **Workaround exists**: Build cephcsi-operator from `red-hat-storage/ceph-csi-operator` branch `release-4.20`
4. **Complete build instructions** are in `ODF-UNINSTALL-REINSTALL.md` → Option 2
5. **Manual setup required** after deploying custom image (TLS certs, Service, CRs)

## Next Steps

To enable CBT on your cluster:

1. Read `ODF-UNINSTALL-REINSTALL.md` completely
2. Build custom cephcsi-operator following "Option 2: Build Custom Image"
3. Deploy custom image using one of the three methods
4. Follow the 8-step manual setup procedure
5. Verify with `test-setup.yaml` and `test-commands.sh`

## Current Status

**As of October 6, 2025**:

- ✅ OpenShift 4.20.0-rc.3 deployed
- ✅ ODF 4.20 deployed (11/11 CSVs Succeeded)
- ✅ StorageCluster healthy
- ❌ CBT not available in release images
- ⚠️ Custom build required for CBT testing
- 📖 Complete documentation ready

## References

- [KEP-3314: CSI Differential Snapshot](https://github.com/kubernetes/enhancements/issues/3314)
- [RHSTOR-6095: Changed Block Tracking for RBD](https://issues.redhat.com/browse/RHSTOR-6095)
- [external-snapshot-metadata](https://github.com/kubernetes-csi/external-snapshot-metadata)
