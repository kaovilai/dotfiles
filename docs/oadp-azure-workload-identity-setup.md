# OADP (OpenShift API for Data Protection) Setup with Azure AD Workload Identity

This guide provides step-by-step instructions for setting up OADP on Azure Red Hat OpenShift (ARO) or self-managed OpenShift on Azure using Azure AD workload identity for authentication.

## Prerequisites

- OpenShift cluster running on Azure (ARO or self-managed)
- Azure CLI (`az`) installed and authenticated
- OpenShift CLI (`oc`) installed and logged into your cluster
- Appropriate Azure permissions to create:
  - Resource groups
  - Storage accounts
  - Managed identities
  - Azure AD app registrations
  - Role assignments

## Step 1: Set Environment Variables

```bash
# Get cluster information
export API_URL=$(oc whoami --show-server)
export CLUSTER_NAME=$(echo "$API_URL" | sed 's|https://api\.||' | sed 's|\..*||')
export CLUSTER_RESOURCE_GROUP="${CLUSTER_NAME}-rg"

# Get Azure information
export AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)

# Set names for resources
export IDENTITY_NAME="velero"
export APP_NAME="velero-${CLUSTER_NAME}"
export STORAGE_ACCOUNT_NAME=$(echo "velero${CLUSTER_NAME}" | tr -d '-' | tr '[:upper:]' '[:lower:]' | cut -c1-24)
export CONTAINER_NAME="velero"

echo "Cluster: $CLUSTER_NAME"
echo "Resource Group: $CLUSTER_RESOURCE_GROUP"
echo "Storage Account: $STORAGE_ACCOUNT_NAME"
```

## Step 2: Create Azure Managed Identity

```bash
# Create managed identity
az identity create \
    --subscription "$AZURE_SUBSCRIPTION_ID" \
    --resource-group "$CLUSTER_RESOURCE_GROUP" \
    --name "$IDENTITY_NAME"

# Get identity details
export IDENTITY_CLIENT_ID=$(az identity show -g "$CLUSTER_RESOURCE_GROUP" -n "$IDENTITY_NAME" --query clientId -o tsv)
export IDENTITY_PRINCIPAL_ID=$(az identity show -g "$CLUSTER_RESOURCE_GROUP" -n "$IDENTITY_NAME" --query principalId -o tsv)

echo "Managed Identity Client ID: $IDENTITY_CLIENT_ID"
```

## Step 3: Create Azure AD App Registration

```bash
# Create Azure AD app
export APP_CREATE_RESULT=$(az ad app create --display-name "$APP_NAME" --sign-in-audience "AzureADMyOrg")
export APP_ID=$(echo "$APP_CREATE_RESULT" | jq -r '.appId')
export APP_OBJECT_ID=$(echo "$APP_CREATE_RESULT" | jq -r '.id')

echo "App ID: $APP_ID"
echo "App Object ID: $APP_OBJECT_ID"

# Create service principal for the app
az ad sp create --id "$APP_ID"

# Wait for propagation
sleep 30
```

## Step 4: Assign Azure Roles

### For Managed Identity

```bash
# Assign Contributor role
az role assignment create \
    --role "Contributor" \
    --assignee "$IDENTITY_PRINCIPAL_ID" \
    --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID"

# Assign Storage Blob Data Contributor role
az role assignment create \
    --assignee "$IDENTITY_PRINCIPAL_ID" \
    --role "Storage Blob Data Contributor" \
    --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID"

# Assign Disk Snapshot Contributor role
az role assignment create \
    --assignee "$IDENTITY_PRINCIPAL_ID" \
    --role "Disk Snapshot Contributor" \
    --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID"
```

### For Azure AD App

```bash
# Assign Storage Blob Data Contributor role
az role assignment create \
    --assignee "$APP_ID" \
    --role "Storage Blob Data Contributor" \
    --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID"

# Assign Disk Snapshot Contributor role
az role assignment create \
    --assignee "$APP_ID" \
    --role "Disk Snapshot Contributor" \
    --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID"
```

## Step 5: Configure Federated Credentials

### Get OpenShift OIDC Issuer URL

```bash
export SERVICE_ACCOUNT_ISSUER=$(oc get authentication.config.openshift.io cluster -o json | jq -r .spec.serviceAccountIssuer)
echo "OIDC Issuer: $SERVICE_ACCOUNT_ISSUER"
```

### Create Federated Credential for Managed Identity

```bash
az identity federated-credential create \
    --name "kubernetes-federated-credential" \
    --identity-name "$IDENTITY_NAME" \
    --resource-group "$CLUSTER_RESOURCE_GROUP" \
    --issuer "$SERVICE_ACCOUNT_ISSUER" \
    --subject "system:serviceaccount:openshift-adp:velero" \
    --audiences "openshift"
```

### Create Federated Credential for Azure AD App

```bash
# Create federated credential JSON
cat > federated-credential.json << EOF
{
    "name": "velero-kubernetes-credential",
    "issuer": "$SERVICE_ACCOUNT_ISSUER",
    "subject": "system:serviceaccount:openshift-adp:velero",
    "description": "Federated credential for Velero backup and restore operations",
    "audiences": ["openshift"]
}
EOF

# Apply federated credential to app
az ad app federated-credential create \
    --id "$APP_OBJECT_ID" \
    --parameters @federated-credential.json

# Clean up
rm federated-credential.json
```

## Step 6: Create Storage Account and Container

```bash
# Create storage account
az storage account create \
    --name "$STORAGE_ACCOUNT_NAME" \
    --resource-group "$CLUSTER_RESOURCE_GROUP" \
    --sku Standard_LRS \
    --encryption-services blob \
    --https-only true \
    --kind StorageV2 \
    --access-tier Hot

# Get storage account key
export STORAGE_ACCOUNT_KEY=$(az storage account keys list \
    --account-name "$STORAGE_ACCOUNT_NAME" \
    --resource-group "$CLUSTER_RESOURCE_GROUP" \
    --query "[0].value" -o tsv)

# Create container
az storage container create \
    --name "$CONTAINER_NAME" \
    --account-name "$STORAGE_ACCOUNT_NAME" \
    --account-key "$STORAGE_ACCOUNT_KEY" \
    --public-access off

# Grant both managed identity and app access to storage account
export STORAGE_ACCOUNT_ID=$(az storage account show \
    --name "$STORAGE_ACCOUNT_NAME" \
    --resource-group "$CLUSTER_RESOURCE_GROUP" \
    --query id -o tsv)

# Grant access to managed identity
az role assignment create \
    --assignee "$IDENTITY_CLIENT_ID" \
    --role "Storage Blob Data Contributor" \
    --scope "$STORAGE_ACCOUNT_ID"

# Grant access to Azure AD app
az role assignment create \
    --assignee "$APP_ID" \
    --role "Storage Blob Data Contributor" \
    --scope "$STORAGE_ACCOUNT_ID"
```

## Step 7: Install OADP Operator

```bash
# Create namespace
oc create namespace openshift-adp

# Install OADP operator (adjust channel as needed)
cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: redhat-oadp-operator
  namespace: openshift-adp
spec:
  channel: stable-1.4
  name: redhat-oadp-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for operator to be ready
oc wait --for=condition=Ready pod -l name=oadp-operator -n openshift-adp --timeout=300s
```

## Step 8: Annotate Service Account

```bash
# Wait for velero service account to be created by the operator
until oc get sa velero -n openshift-adp &>/dev/null; do
  echo "Waiting for velero service account..."
  sleep 5
done

# Annotate with Azure AD app client ID
oc annotate serviceaccount velero \
    -n openshift-adp \
    azure.workload.identity/client-id="$APP_ID" \
    --overwrite
```

## Step 9: Create DataProtectionApplication

```bash
cat << EOF | oc apply -f -
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: dpa
  namespace: openshift-adp
spec:
  configuration:
    velero:
      defaultPlugins:
        - openshift
        - azure
        - csi
      resourceAllocations:
        limits:
          cpu: 1000m
          memory: 512Mi
        requests:
          cpu: 500m
          memory: 256Mi
      podConfig:
        labels:
          azure.workload.identity/use: "true"
    nodeAgent:
      enable: true
      uploaderType: kopia
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      podConfig:
        labels:
          azure.workload.identity/use: "true"
  backupImages: false
  backupLocations:
    - name: default
      velero:
        provider: velero.io/azure
        default: true
        credential:
          name: cloud-credentials-azure
          key: azurekey
        objectStorage:
          bucket: $CONTAINER_NAME
          prefix: $CLUSTER_NAME
        config:
          resourceGroup: $CLUSTER_RESOURCE_GROUP
          storageAccount: $STORAGE_ACCOUNT_NAME
          subscriptionId: $AZURE_SUBSCRIPTION_ID
          useAAD: "true"
  snapshotLocations:
    - name: default
      velero:
        provider: azure
        credential:
          name: cloud-credentials-azure
          key: azurekey
        config:
          resourceGroup: $CLUSTER_RESOURCE_GROUP
          subscriptionId: $AZURE_SUBSCRIPTION_ID
EOF
```

## Step 10: Verify Installation

```bash
# Check DPA status
oc get dpa dpa -n openshift-adp -o yaml

# Check if pods are running
oc get pods -n openshift-adp

# Check velero deployment
oc get deployment velero -n openshift-adp

# Verify velero is ready
velero version
```

## Step 11: Create a Test Backup

```bash
# Create a test namespace
oc create namespace backup-test
oc create deployment nginx --image=nginx -n backup-test

# Create a backup
velero backup create test-backup --include-namespaces backup-test

# Check backup status
velero backup describe test-backup
velero backup logs test-backup
```

## Troubleshooting

### Check Velero Logs

```bash
oc logs deployment/velero -n openshift-adp
```

### Verify Service Account Annotation

```bash
oc get sa velero -n openshift-adp -o yaml | grep azure.workload.identity
```

### Check Azure Permissions

```bash
# List role assignments for the app
az role assignment list --assignee "$APP_ID" --all

# Verify federated credential
az ad app federated-credential list --id "$APP_OBJECT_ID"
```

### Common Issues

1. **Authentication Failures**: Ensure the service account is annotated with the correct Azure AD app ID
2. **Storage Access Denied**: Verify the app has Storage Blob Data Contributor role on the storage account
3. **Snapshot Failures**: Check that Disk Snapshot Contributor role is assigned
4. **Federated Credential Issues**: Ensure the OIDC issuer URL matches exactly and the subject is correct

## Cleanup (Optional)

```bash
# Delete OADP resources
oc delete dpa dpa -n openshift-adp
oc delete subscription redhat-oadp-operator -n openshift-adp

# Delete Azure resources
az storage account delete --name "$STORAGE_ACCOUNT_NAME" --resource-group "$CLUSTER_RESOURCE_GROUP" --yes
az identity delete --name "$IDENTITY_NAME" --resource-group "$CLUSTER_RESOURCE_GROUP"
az ad app delete --id "$APP_ID"
```

## Summary

This setup provides:
- Azure AD workload identity authentication for Velero
- Secure access to Azure storage for backups
- Disk snapshot capabilities for persistent volumes
- No need to manage credentials or secrets

The Azure AD app registration with federated credentials provides enhanced permissions and better integration with Azure's permission model compared to using managed identity alone.
