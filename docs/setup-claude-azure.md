# Configuring OADP on Azure Red Hat OpenShift (ARO) with Workload Identity

## Overview

This tutorial explains how to configure OpenShift API for Data Protection (OADP) on Azure Red Hat OpenShift (ARO) clusters using Azure Workload Identity. This method uses federated credentials for enhanced security, eliminating the need for service principal secrets.

**Note**: This guide incorporates the new standardized authentication flow introduced in [OADP PR #1836](https://github.com/openshift/oadp-operator/pull/1836), which simplifies the credential configuration process.

## Prerequisites

Before you begin, ensure you have:

* An Azure Red Hat OpenShift (ARO) cluster with Workload Identity enabled
* Azure CLI (`az`) installed and configured
* OpenShift CLI (`oc`) installed and configured
* Access to the ARO cluster as a user with cluster-admin privileges
* Access to Azure subscription with appropriate permissions

## Procedure

### Step 1: Obtain Azure environment information

1. Set your Azure subscription information:
```bash
# Get Azure subscription ID
AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Get Azure tenant ID
AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)

# Get resource group where cluster resources exist
AZURE_RESOURCE_GROUP=<your-cluster-resource-group>

# Get OIDC issuer URL from cluster
OIDC_ISSUER=$(oc get authentication.config.openshift.io cluster -o json | jq -r .spec.serviceAccountIssuer)
```

### Step 2: Create Azure storage resources

1. Create a storage account for backups:
```bash
# Create storage account
STORAGE_ACCOUNT_NAME=velero$(openssl rand -hex 4)
az storage account create \
    --name $STORAGE_ACCOUNT_NAME \
    --resource-group $AZURE_RESOURCE_GROUP \
    --sku Standard_LRS \
    --encryption-services blob

# Create blob container
BLOB_CONTAINER=velero
az storage container create \
    --name $BLOB_CONTAINER \
    --account-name $STORAGE_ACCOUNT_NAME
```

2. Create a managed identity:
```bash
# Create managed identity
IDENTITY_NAME=velero-backup-identity
az identity create \
    --name $IDENTITY_NAME \
    --resource-group $AZURE_RESOURCE_GROUP

# Get identity details
IDENTITY_CLIENT_ID=$(az identity show \
    --name $IDENTITY_NAME \
    --resource-group $AZURE_RESOURCE_GROUP \
    --query clientId -o tsv)

IDENTITY_RESOURCE_ID=$(az identity show \
    --name $IDENTITY_NAME \
    --resource-group $AZURE_RESOURCE_GROUP \
    --query id -o tsv)
```

### Step 3: Configure Azure permissions

1. Grant the managed identity necessary permissions:

```bash
# Assign Storage Blob Data Contributor role to the storage account
az role assignment create \
    --assignee $IDENTITY_CLIENT_ID \
    --role "Storage Blob Data Contributor" \
    --scope /subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$AZURE_RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME

# Assign Contributor role to the resource group (for snapshots)
az role assignment create \
    --assignee $IDENTITY_CLIENT_ID \
    --role "Contributor" \
    --scope /subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$AZURE_RESOURCE_GROUP
```

### Step 4: Configure federated credentials

1. Create federated credentials for the managed identity:

```bash
az identity federated-credential create \
    --name velero-federated-credential \
    --identity-name $IDENTITY_NAME \
    --resource-group $AZURE_RESOURCE_GROUP \
    --issuer $OIDC_ISSUER \
    --subject "system:serviceaccount:openshift-adp:velero" \
    --audience "api://AzureADTokenExchange"
```

### Step 5: Install OADP Operator

With the new standardized authentication flow:

1. Navigate to OperatorHub in the OpenShift console
2. Search for "OADP Operator"
3. Click Install
4. During installation, append `&tokenizedAuth=Azure` to the subscription URL
   
   Example URL:
   ```
   https://console-openshift-console.apps.cluster.example.com/operatorhub/subscribe?pkg=oadp-operator&catalog=oadp-operator-catalog&catalogNamespace=openshift-adp&targetNamespace=openshift-adp&channel=stable&version=1.4.0&tokenizedAuth=Azure
   ```

5. You'll be prompted to enter:
   - Azure Client ID (Managed Identity Client ID)
   - Azure Tenant ID
   - Azure Subscription ID

The operator will automatically create the `cloud-credentials-azure` secret with the proper configuration.

### Step 6: Create Data Protection Application

1. Create a DataProtectionApplication custom resource:

```yaml
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: azure-wif-dpa
  namespace: openshift-adp
spec:
  backupLocations:
    - velero:
        provider: azure
        default: true
        credential:
          key: cloud
          name: cloud-credentials-azure
        objectStorage:
          bucket: ${BLOB_CONTAINER}
          prefix: ${BACKUP_PREFIX}
        config:
          resourceGroup: ${AZURE_RESOURCE_GROUP}
          storageAccount: ${STORAGE_ACCOUNT_NAME}
          subscriptionId: ${AZURE_SUBSCRIPTION_ID}
  configuration:
    velero:
      defaultPlugins:
        - openshift
        - azure
  snapshotLocations:
    - velero:
        provider: azure
        config:
          resourceGroup: ${AZURE_RESOURCE_GROUP}
          subscriptionId: ${AZURE_SUBSCRIPTION_ID}
```

### Step 7: Verify the installation

1. Check the backup storage location:

```bash
oc get backupstoragelocations -n openshift-adp
```

Expected output:
```
NAME              PHASE       LAST VALIDATED   AGE   DEFAULT
azure-wif-dpa-1   Available   10s              30s   true
```

### Step 8: Create a test backup

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

1. **Authentication failures**: Verify the federated credential configuration matches the OIDC issuer
2. **Permission denied**: Ensure the managed identity has correct role assignments
3. **Storage access issues**: Check storage account firewall rules and network configuration

### Debugging Commands

```bash
# Check Velero pod logs
oc logs -n openshift-adp deployment/velero

# Verify secret creation
oc get secret cloud-credentials-azure -n openshift-adp -o yaml

# Check service account annotation
oc get sa velero -n openshift-adp -o yaml

# Verify managed identity permissions
az role assignment list --assignee $IDENTITY_CLIENT_ID
```

## Additional configuration options

### Using private endpoints

If your storage account uses private endpoints:

```yaml
config:
  resourceGroup: ${AZURE_RESOURCE_GROUP}
  storageAccount: ${STORAGE_ACCOUNT_NAME}
  subscriptionId: ${AZURE_SUBSCRIPTION_ID}
  storageAccountURI: "https://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net"
```

### Custom snapshot resource group

To store snapshots in a different resource group:

```yaml
snapshotLocations:
  - velero:
      provider: azure
      config:
        resourceGroup: ${SNAPSHOT_RESOURCE_GROUP}
        subscriptionId: ${AZURE_SUBSCRIPTION_ID}
```

## Additional resources

* [OADP documentation](https://docs.openshift.com/container-platform/latest/backup_and_restore/application_backup_and_restore/oadp-intro.html)
* [Azure Red Hat OpenShift documentation](https://docs.microsoft.com/en-us/azure/openshift/)
* [OADP Operator GitHub repository](https://github.com/openshift/oadp-operator)
* [PR #1836 - Standardized authentication flow](https://github.com/openshift/oadp-operator/pull/1836)