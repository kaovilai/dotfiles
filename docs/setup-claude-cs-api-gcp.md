# Testing OADP Cloud Secret API on OpenShift with Google Cloud Platform

## Overview

This guide demonstrates how to test the new Cloud Secret API functionality introduced in [OADP PR #1828](https://github.com/openshift/oadp-operator/pull/1828) on OpenShift clusters running on Google Cloud Platform (GCP) with Workload Identity Federation.

The Cloud Secret API provides a standardized way to retrieve cloud credentials through the OADP operator's API service, eliminating the need to manually create and manage credential secrets.

## Prerequisites

* An OpenShift cluster installed on GCP with Workload Identity configured
* Google Cloud CLI (`gcloud`) installed and configured
* OpenShift CLI (`oc`) installed and configured
* Access to the OpenShift cluster as a user with cluster-admin privileges
* GCP Project with appropriate permissions
* OADP operator built from PR #1828 branch

## Key Features of PR #1828

The PR introduces:
- A new API service endpoint at `/api/v1/credentials/{credentialName}` 
- Support for fetching credentials for AWS, Azure, and GCP
- Automatic credential generation based on the cloud provider
- Integration with STS/Workload Identity flows

## Setup Procedure

### Step 1: Build and Deploy OADP from PR Branch

1. Clone the OADP operator repository and checkout the PR branch:

```bash
git clone https://github.com/openshift/oadp-operator.git
cd oadp-operator
git fetch origin pull/1828/head:pr-1828
git checkout pr-1828
```

2. Build and push the operator image:

```bash
# Build the operator image
make docker-build IMG=quay.io/${YOUR_QUAY_USERNAME}/oadp-operator:pr-1828

# Push to registry
make docker-push IMG=quay.io/${YOUR_QUAY_USERNAME}/oadp-operator:pr-1828
```

### Step 2: Create GCP Service Account and Configure Workload Identity

1. Set up environment variables:

```bash
export CLUSTER_NAME="your-cluster-name"
export GCP_PROJECT_ID="your-project-id"
export GCP_PROJECT_NUM=$(gcloud projects describe ${GCP_PROJECT_ID} --format="value(projectNumber)")
export SERVICE_ACCOUNT_NAME="velero-${CLUSTER_NAME}"
export SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
```

2. Create service account and grant permissions:

```bash
# Create service account
gcloud iam service-accounts create ${SERVICE_ACCOUNT_NAME} \
    --display-name="Velero Backup Service Account for Cloud Secret API" \
    --project=${GCP_PROJECT_ID}

# Grant required roles
for role in "roles/compute.storageAdmin" "roles/storage.admin" "roles/compute.admin"; do
    gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} \
        --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
        --role="${role}"
done
```

3. Get workload identity pool and provider from cluster:

```bash
# Get the OIDC issuer
export OIDC_ISSUER=$(oc get authentication.config.openshift.io cluster -o json | jq -r .spec.serviceAccountIssuer)

# Extract pool and provider IDs (assuming standard naming)
export POOL_ID="${CLUSTER_NAME}"
export PROVIDER_ID="${CLUSTER_NAME}"
```

4. Configure workload identity binding:

```bash
# Bind for Velero service account
gcloud iam service-accounts add-iam-policy-binding ${SERVICE_ACCOUNT_EMAIL} \
    --project=${GCP_PROJECT_ID} \
    --role="roles/iam.workloadIdentityUser" \
    --member="principal://iam.googleapis.com/projects/${GCP_PROJECT_NUM}/locations/global/workloadIdentityPools/${POOL_ID}/subject/system:serviceaccount:openshift-adp:velero"

# Bind for OADP operator controller manager service account
gcloud iam service-accounts add-iam-policy-binding ${SERVICE_ACCOUNT_EMAIL} \
    --project=${GCP_PROJECT_ID} \
    --role="roles/iam.workloadIdentityUser" \
    --member="principal://iam.googleapis.com/projects/${GCP_PROJECT_NUM}/locations/global/workloadIdentityPools/${POOL_ID}/subject/system:serviceaccount:openshift-adp:openshift-adp-controller-manager"
```

### Step 3: Deploy OADP Operator with Custom Image

1. Create the operator namespace:

```bash
oc create namespace openshift-adp
```

2. Create CatalogSource with custom image:

```yaml
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: oadp-pr-catalog
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: quay.io/${YOUR_QUAY_USERNAME}/oadp-operator-catalog:pr-1828
  displayName: OADP PR 1828 Catalog
EOF
```

3. Create Subscription:

```yaml
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: oadp-operator
  namespace: openshift-adp
spec:
  channel: stable-1.4
  name: oadp-operator
  source: oadp-pr-catalog
  sourceNamespace: openshift-marketplace
  env:
  - name: ENABLE_CLOUD_SECRET_API
    value: "true"
EOF
```

### Step 4: Configure OADP for Cloud Secret API

1. Create DataProtectionApplication without explicit credentials:

```yaml
cat <<EOF | oc apply -f -
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: dpa-cloud-secret-api
  namespace: openshift-adp
spec:
  configuration:
    velero:
      defaultPlugins:
        - gcp
        - openshift
        - csi
      # Enable cloud secret API
      cloudSecretAPI:
        enabled: true
  backupLocations:
    - name: default
      velero:
        provider: gcp
        default: true
        # No credential section - will use Cloud Secret API
        objectStorage:
          bucket: velero-${GCP_PROJECT_ID}-${CLUSTER_NAME}
          prefix: velero
  snapshotLocations:
    - name: default
      velero:
        provider: gcp
        config:
          project: ${GCP_PROJECT_ID}
          snapshotLocation: ${GCP_REGION:-us-central1}
EOF
```

### Step 5: Test Cloud Secret API

1. Check if the API service is running:

```bash
oc get pods -n openshift-adp -l app.kubernetes.io/name=oadp-api-service
```

1. Test credential retrieval via API:

```bash
# Get the API service route
export API_ROUTE=$(oc get route oadp-api -n openshift-adp -o jsonpath='{.spec.host}')

# Create service account token for authentication
oc create token velero -n openshift-adp > /tmp/velero-token

# Test the credentials endpoint
curl -H "Authorization: Bearer $(cat /tmp/velero-token)" \
     https://${API_ROUTE}/api/v1/credentials/cloud-credentials-gcp
```

Expected response should contain:
```json
{
  "kind": "Credentials",
  "spec": {
    "secretName": "cloud-credentials-gcp",
    "credentialData": {
      "service_account.json": "<base64-encoded-credential>"
    }
  }
}
```

1. Verify Velero is using the Cloud Secret API:

```bash
# Check Velero logs for Cloud Secret API usage
oc logs -n openshift-adp deployment/velero | grep -i "cloud.*secret.*api"

# Verify no manual secret exists
oc get secret cloud-credentials-gcp -n openshift-adp
# This should return "not found" since the secret is dynamically generated
```

### Step 6: Create Test Backup

1. Create a test backup to verify functionality:

```bash
velero backup create cloud-api-test --include-namespaces=default
```

1. Monitor the backup:

```bash
velero backup describe cloud-api-test
velero backup logs cloud-api-test
```

## Debugging Cloud Secret API

### Check API Service Logs

```bash
# Get API service pod logs
oc logs -n openshift-adp -l app.kubernetes.io/name=oadp-api-service

# Check for credential generation
oc logs -n openshift-adp deployment/oadp-operator | grep -i credential
```

### Verify Workload Identity Configuration

```bash
# Verify workload identity binding
gcloud iam service-accounts get-iam-policy ${SERVICE_ACCOUNT_EMAIL} \
    --flatten="bindings[].members" \
    --filter="bindings.members:principal://*"
```

### Test Manual Credential Generation

```bash
# Directly invoke the credential generation
oc exec -n openshift-adp deployment/oadp-operator -- \
    /manager credentials generate --provider=gcp --name=test
```

## Key Differences from Standard Setup

1. **No Manual Secret Creation**: The Cloud Secret API automatically generates credentials
2. **Dynamic Credential Retrieval**: Credentials are fetched on-demand via API
3. **No credential Section in DPA**: The DataProtectionApplication doesn't specify credential references
4. **API Service Dependency**: Requires the OADP API service to be running

## Troubleshooting

### API Service Not Running

If the API service pod is not running:
1. Check operator logs for deployment errors
2. Verify RBAC permissions are correctly configured
3. Ensure the `ENABLE_CLOUD_SECRET_API` environment variable is set

### Authentication Failures

1. Verify workload identity annotations are correct
2. Check GCP IAM bindings include the correct principal
3. Ensure the service account has required GCP permissions

### Credential Generation Errors

1. Check operator logs for detailed error messages
2. Verify GCP project configuration
3. Test workload identity token exchange manually

## Clean Up

To remove the test setup:

```bash
# Delete DPA
oc delete dpa dpa-cloud-secret-api -n openshift-adp

# Delete operator
oc delete subscription oadp-operator -n openshift-adp
oc delete catalogsource oadp-pr-catalog -n openshift-marketplace

# Delete GCP resources
gcloud iam service-accounts delete ${SERVICE_ACCOUNT_EMAIL} --quiet
gsutil rm -r gs://velero-${GCP_PROJECT_ID}-${CLUSTER_NAME}
```

## Additional Resources

* [PR #1828 - Cloud Secret API](https://github.com/openshift/oadp-operator/pull/1828)
* [OADP Documentation](https://docs.openshift.com/container-platform/latest/backup_and_restore/application_backup_and_restore/oadp-intro.html)
* [GCP Workload Identity Documentation](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)