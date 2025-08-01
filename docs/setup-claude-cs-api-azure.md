# Testing OADP Cloud Storage API for Azure

## Overview

This guide documents how to test the new Cloud Storage API functionality for Azure introduced in [OADP PR #1828](https://github.com/openshift/oadp-operator/pull/1828). The PR adds support for Azure Blob Storage as a CloudStorage provider using Azure Workload Identity authentication.

## Prerequisites

1. Azure OpenShift cluster with Workload Identity enabled (created using `create-ocp-azure-sts`)
2. Azure CLI installed and authenticated
3. OpenShift CLI (oc) installed
4. Access to the OADP operator PR branch
5. Velero CLI installed for testing

## Setup Instructions

### Step 1: Create Azure OpenShift Cluster with Workload Identity

```bash
# Create cluster using the existing function
create-ocp-azure-sts

# After cluster creation, switch to the cluster context
use-ocp-cluster azure-sts
```

### Step 2: Create Velero Identity and Storage Resources

```bash
# Create managed identity for Velero
create-velero-identity-for-azure-cluster

# Create storage container for backups
create-velero-container-for-azure-cluster
```

**Note**: The `create-velero-identity-for-azure-cluster` function automatically creates federated identity credentials for both:
- Velero service account (`system:serviceaccount:openshift-adp:velero`)
- OADP controller manager service account (`system:serviceaccount:openshift-adp:openshift-adp-controller-manager`)

### Step 3: Build and Deploy OADP Operator from PR Branch

```bash
# Clone the OADP operator repository
git clone https://github.com/openshift/oadp-operator.git
cd oadp-operator

# Fetch the PR branch
git fetch origin pull/1828/head:pr-1828-cloud-storage-api
git checkout pr-1828-cloud-storage-api

# Build and deploy the operator with Azure STS flow
# The environment variables should already be set by create-velero-identity-for-azure-cluster
make deploy-olm-stsflow-azure
```

### Step 4: Verify Secret Creation

```bash
# Check that the cloud-credentials-azure secret was created
oc get secret cloud-credentials-azure -n openshift-adp -o yaml

# Verify the secret contains the correct format
oc get secret cloud-credentials-azure -n openshift-adp -o jsonpath='{.data.azurekey}' | base64 -d
```

Expected output:
```
AZURE_SUBSCRIPTION_ID=<your-subscription-id>
AZURE_TENANT_ID=<your-tenant-id>
AZURE_CLIENT_ID=<your-client-id>
AZURE_CLOUD_NAME=AzurePublicCloud
```

### Step 5: Test Cloud Storage API with Azure

Create a test CloudStorage resource:

```bash
cat << EOF > test-azure-cloudstorage.yaml
apiVersion: oadp.openshift.io/v1alpha1
kind: CloudStorage
metadata:
  name: azure-test-storage
  namespace: openshift-adp
spec:
  name: velero
  provider: azure
  creationSecret:
    name: cloud-credentials-azure
  config:
    storageAccount: "$(echo "velero$(oc whoami --show-server | sed 's|https://api\.||' | sed 's|\..*||')" | tr -d '-' | tr '[:upper:]' '[:lower:]' | cut -c1-24)"
EOF

# Apply the CloudStorage resource
oc apply -f test-azure-cloudstorage.yaml

# Check the status
oc get cloudstorage azure-test-storage -n openshift-adp -o yaml
```

### Step 6: Create DataProtectionApplication with Azure Configuration

```bash
# Generate the DPA configuration
create-velero-dpa-for-azure-cluster

# Apply the DPA
oc apply -f velero-dpa-*.yaml

# Monitor the DPA status
oc get dpa dpa -n openshift-adp -w
```

### Step 7: Test Backup and Restore Operations

```bash
# Create a test namespace with some resources
oc create namespace test-backup
oc create deployment nginx --image=nginx -n test-backup
oc expose deployment nginx --port=80 -n test-backup

# Create a backup using the Azure storage
velero backup create test-azure-backup --include-namespaces=test-backup

# Monitor backup progress
velero backup describe test-azure-backup

# Delete the test namespace
oc delete namespace test-backup

# Restore from backup
velero restore create test-azure-restore --from-backup test-azure-backup

# Verify restoration
oc get all -n test-backup
```

### Step 8: Advanced Testing Scenarios

#### Test 1: Verify Azure Workload Identity Token Exchange

```bash
# Check Velero pod environment variables
oc get pods -n openshift-adp -l app.kubernetes.io/name=velero -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="AZURE_CLIENT_ID")]}' | jq .

# Check AZURE_FEDERATED_TOKEN_FILE environment variable
oc get pods -n openshift-adp -l app.kubernetes.io/name=velero -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="AZURE_FEDERATED_TOKEN_FILE")]}' | jq .

# Check service account annotations for both Velero and OADP controller
oc get sa velero -n openshift-adp -o jsonpath='{.metadata.annotations}' | jq .
oc get sa openshift-adp-controller-manager -n openshift-adp -o jsonpath='{.metadata.annotations}' | jq .

# Verify federated identity credentials exist for both service accounts
CLUSTER_NAME=$(oc whoami --show-server | sed 's|https://api\.||' | sed 's|\..*||')
az identity federated-credential list \
  --identity-name "velero-${CLUSTER_NAME}" \
  --resource-group "${CLUSTER_NAME}-rg" \
  --query "[].{name:name,subject:subject}" -o table
```

#### Test 2: Test Secret Update Flow

```bash
# Update the Azure credentials
export NEW_CLIENT_ID="<new-client-id>"
export NEW_TENANT_ID="<new-tenant-id>"
export NEW_SUBSCRIPTION_ID="<new-subscription-id>"

# Re-run the operator with new credentials
make deploy-olm-stsflow-azure \
  AZURE_CLIENT_ID=$NEW_CLIENT_ID \
  AZURE_TENANT_ID=$NEW_TENANT_ID \
  AZURE_SUBSCRIPTION_ID=$NEW_SUBSCRIPTION_ID

# Verify secret was updated
oc get secret cloud-credentials-azure -n openshift-adp -o jsonpath='{.data.azurekey}' | base64 -d
```

#### Test 3: Test BSL Configuration Auto-Patching

```bash
# Create a BSL with Azure configuration
cat << EOF > test-azure-bsl.yaml
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: azure-bsl-test
  namespace: openshift-adp
spec:
  provider: velero.io/azure
  objectStorage:
    bucket: velero
    prefix: test-prefix
  config:
    resourceGroup: $(oc whoami --show-server | sed 's|https://api\.||' | sed 's|\..*||')-rg
    storageAccount: $(echo "velero$(oc whoami --show-server | sed 's|https://api\.||' | sed 's|\..*||')" | tr -d '-' | tr '[:upper:]' '[:lower:]' | cut -c1-24)
    subscriptionId: $(az account show --query id -o tsv)
    useAAD: "true"
EOF

oc apply -f test-azure-bsl.yaml

# Verify BSL is available
oc get bsl azure-bsl-test -n openshift-adp
```

### Step 9: Validate Role Assignments

```bash
# Use the existing validation function
validate-velero-role-assignments-for-azure-cluster
```

## Troubleshooting

### Common Issues and Solutions

1. **Secret Not Created**
   ```bash
   # Check operator logs
   oc logs -n openshift-adp deployment/oadp-operator-controller-manager
   
   # Verify environment variables were passed
   oc get subscription oadp-operator -n openshift-adp -o yaml | grep -A 5 config
   ```

2. **Authentication Failures**
   ```bash
   # Check Velero logs for Azure authentication errors
   oc logs -n openshift-adp -l app.kubernetes.io/name=velero | grep -i "azure\|auth"
   
   # Check OADP operator controller logs for authentication issues
   oc logs -n openshift-adp deployment/oadp-operator-controller-manager | grep -i "azure\|auth"
   
   # Verify managed identity federated credentials for both service accounts
   CLUSTER_NAME=$(oc whoami --show-server | sed 's|https://api\.||' | sed 's|\..*||')
   az identity federated-credential list \
     --identity-name "velero-${CLUSTER_NAME}" \
     --resource-group "${CLUSTER_NAME}-rg" \
     --query "[].{name:name,subject:subject}" -o table
   
   # Verify both service accounts have correct annotations
   echo "Velero service account annotations:"
   oc get sa velero -n openshift-adp -o jsonpath='{.metadata.annotations}' | jq .
   echo "OADP controller service account annotations:"
   oc get sa openshift-adp-controller-manager -n openshift-adp -o jsonpath='{.metadata.annotations}' | jq .
   ```

3. **CloudStorage Resource Issues**
   ```bash
   # Check CloudStorage status
   oc describe cloudstorage azure-test-storage -n openshift-adp
   
   # Check operator reconciliation logs
   oc logs -n openshift-adp deployment/oadp-operator-controller-manager | grep -i cloudstorage
   ```

## Expected Results

When the Cloud Storage API is working correctly:

1. **Secret Creation**: The `cloud-credentials-azure` secret should be automatically created with proper Azure credentials
2. **CloudStorage Status**: The CloudStorage resource should show a ready/available status
3. **Backup Operations**: Backups should successfully upload to Azure Blob Storage
4. **Restore Operations**: Restores should successfully download from Azure Blob Storage
5. **Authentication**: No authentication errors in Velero logs

## Cleanup

```bash
# Delete test resources
oc delete namespace test-backup
velero backup delete test-azure-backup
velero restore delete test-azure-restore
oc delete cloudstorage azure-test-storage -n openshift-adp
oc delete -f test-azure-bsl.yaml

# Delete the entire OADP installation if needed
oc delete dpa dpa -n openshift-adp
oc delete subscription oadp-operator -n openshift-adp
oc delete namespace openshift-adp
```

## Additional Testing Considerations

1. **Multi-Cloud Testing**: If possible, test that AWS S3 and GCP functionality still work correctly
2. **Upgrade Testing**: Test upgrading from a previous OADP version to ensure backward compatibility
3. **Performance Testing**: Test backup/restore performance with large datasets
4. **Error Scenarios**: Test with invalid credentials, non-existent storage accounts, etc.

## References

- [OADP PR #1828](https://github.com/openshift/oadp-operator/pull/1828)
- [Azure Workload Identity Documentation](https://azure.github.io/azure-workload-identity/)
- [Velero Azure Plugin Documentation](https://github.com/vmware-tanzu/velero-plugin-for-microsoft-azure)
- [OpenShift Enhancement Proposal #1800](https://github.com/openshift/enhancements/pull/1800)