# Configuring OADP on OpenShift with Google Cloud Platform Workload Identity

## Overview

This tutorial explains how to configure OpenShift API for Data Protection (OADP) on OpenShift clusters running on Google Cloud Platform (GCP) using Workload Identity Federation. This method eliminates the need for service account keys, providing enhanced security through short-lived tokens.

**Note**: This guide incorporates the new standardized authentication flow introduced in [OADP PR #1836](https://github.com/openshift/oadp-operator/pull/1836), which simplifies the credential configuration process.

## Prerequisites

Before you begin, ensure you have:

* An OpenShift cluster installed on GCP with Workload Identity configured
* Google Cloud CLI (`gcloud`) installed and configured
* OpenShift CLI (`oc`) installed and configured
* Access to the OpenShift cluster as a user with cluster-admin privileges
* Access to `ccoctl` CLI from the cluster installation
* GCP Project with appropriate permissions

## Procedure

### Step 1: Obtain GCP environment information

1. Collect the following information from your cluster:
```bash
# Get GCP Project Number
gcloud projects describe ${PROJECT_ID} --format="value(projectNumber)"

# Get workload identity pool and provider from cluster
oc get authentication.config.openshift.io cluster -o json | jq -r .spec.serviceAccountIssuer
```

You'll need:
- GCP Project Number
- Workload Identity Pool name
- Workload Identity Provider name

### Step 2: Create GCP service account

1. Create a service account with the required permissions:

```bash
# Create service account
gcloud iam service-accounts create velero-backup \
    --display-name="Velero Backup Service Account" \
    --project=${PROJECT_ID}

# Get the service account email
SA_EMAIL=velero-backup@${PROJECT_ID}.iam.gserviceaccount.com

# Grant required roles
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/compute.admin"

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/storage.admin"

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/iam.serviceAccountTokenCreator"
```

### Step 3: Configure Workload Identity Federation

1. Grant the Kubernetes service account permission to impersonate the GCP service account:

```bash
gcloud iam service-accounts add-iam-policy-binding ${SA_EMAIL} \
    --project=${PROJECT_ID} \
    --role=roles/iam.workloadIdentityUser \
    --member="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/subject/system:serviceaccount:openshift-adp:velero"
```

### Step 4: Install OADP Operator

With the new standardized authentication flow:

1. Navigate to OperatorHub in the OpenShift console
2. Search for "OADP Operator"
3. Click Install
4. During installation, append `&tokenizedAuth=GCP` to the subscription URL
   
   Example URL:
   ```
   https://console-openshift-console.apps.cluster.example.com/operatorhub/subscribe?pkg=oadp-operator&catalog=oadp-operator-catalog&catalogNamespace=openshift-adp&targetNamespace=openshift-adp&channel=stable&version=1.4.0&tokenizedAuth=GCP
   ```

5. You'll be prompted to enter:
   - Service Account Email (e.g., `velero-backup@${PROJECT_ID}.iam.gserviceaccount.com`)
   - GCP Project Number
   - Workload Identity Pool ID
   - Workload Identity Provider ID

The operator will automatically create the `cloud-credentials-gcp` secret with the proper configuration.

### Step 5: Create Data Protection Application

1. Create a DataProtectionApplication custom resource:

```yaml
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: gcp-wif-dpa
  namespace: openshift-adp
spec:
  backupLocations:
    - velero:
        provider: gcp
        default: true
        credential:
          key: service_account.json
          name: cloud-credentials-gcp 
        objectStorage:
          bucket: ${BUCKET_NAME}
          prefix: ${BACKUP_PREFIX}
  configuration:
    velero:
      defaultPlugins:
        - gcp
        - openshift
  snapshotLocations:
    - velero:
        provider: gcp
        config:
          project: ${PROJECT_ID}
```

### Step 6: Verify the installation

1. Check the backup storage location:

```bash
oc get backupstoragelocations -n openshift-adp
```

Expected output:
```
NAME           PHASE       LAST VALIDATED   AGE   DEFAULT
gcp-wif-dpa-1  Available   10s              30s   true
```

### Step 7: Create a test backup

1. Create a test backup:

```bash
velero backup create test-backup --include-namespaces=default
```

2. Monitor the backup progress:
```bash
velero backup describe test-backup
```

## Troubleshooting

### Authentication failures

1. **Authentication failures**: Verify the workload identity binding is correct
2. **Permission denied**: Ensure all required GCP roles are granted
3. **Service account not found**: Check the service account email is correct

### Debugging Commands

```bash
# Check Velero pod logs
oc logs -n openshift-adp deployment/velero

# Verify secret creation
oc get secret cloud-credentials-gcp -n openshift-adp -o yaml

# Check service account annotation
oc get sa velero -n openshift-adp -o yaml

# Verify workload identity binding
gcloud iam service-accounts get-iam-policy ${SA_EMAIL}
```

## Known limitations

* File System Backup is currently not supported with Workload Identity Federation
* Velero Built-in Data Mover is not supported with WIF
* VolumeSnapshotLocation requires additional configuration

## Additional resources

* [OADP documentation](https://docs.openshift.com/container-platform/latest/backup_and_restore/application_backup_and_restore/oadp-intro.html)
* [GCP Workload Identity documentation](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
* [OADP Operator GitHub repository](https://github.com/openshift/oadp-operator)
* [PR #1836 - Standardized authentication flow](https://github.com/openshift/oadp-operator/pull/1836)