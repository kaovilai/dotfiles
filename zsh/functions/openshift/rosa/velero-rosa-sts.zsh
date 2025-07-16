#!/usr/bin/env zsh

# Helper function to get ROSA cluster name from current context
_get_rosa_cluster_name() {
    # Try method 1: Get from infrastructure name
    local INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null)
    if [[ -n "$INFRA_ID" ]]; then
        local CLUSTER_NAME=$(rosa list clusters -o json 2>/dev/null | jq -r ".[] | select(.infra_id == \"$INFRA_ID\") | .name" 2>/dev/null)
        if [[ -n "$CLUSTER_NAME" ]] && [[ "$CLUSTER_NAME" != "null" ]]; then
            echo "$CLUSTER_NAME"
            return 0
        fi
    fi
    
    # Try method 2: Match by API endpoint
    local API_URL=$(oc whoami --show-server 2>/dev/null)
    if [[ -n "$API_URL" ]]; then
        local API_DOMAIN=$(echo "$API_URL" | sed 's|https://api\.||' | sed 's|:.*||')
        CLUSTER_NAME=$(rosa list clusters -o json 2>/dev/null | jq -r ".[] | select(.api.url | contains(\"$API_DOMAIN\")) | .name" 2>/dev/null)
        if [[ -n "$CLUSTER_NAME" ]] && [[ "$CLUSTER_NAME" != "null" ]]; then
            echo "$CLUSTER_NAME"
            return 0
        fi
    fi
    
    # If both methods fail, return error
    echo "ERROR: Could not determine ROSA cluster name" >&2
    return 1
}

# Function to create Velero identity (IAM role and policy) for current ROSA cluster
# Run this after ROSA cluster creation to get vars for velero install for OADP
znap function create-velero-identity-for-rosa-cluster() {
    # Get ROSA cluster name
    local CLUSTER_NAME=$(_get_rosa_cluster_name)
    
    if [[ -z "$CLUSTER_NAME" ]]; then
        return 1
    fi
    
    echo "Creating Velero identity for ROSA cluster: $CLUSTER_NAME"
    
    # Verify this is a ROSA cluster
    if ! rosa describe cluster --cluster "$CLUSTER_NAME" &>/dev/null; then
        echo "ERROR: Cluster $CLUSTER_NAME not found. Is this a ROSA STS cluster?"
        return 1
    fi
    
    # Get cluster details
    local ROSA_CLUSTER_ID=$(rosa describe cluster -c "$CLUSTER_NAME" --output json | jq -r .id)
    local AWS_REGION=$(rosa describe cluster -c "$CLUSTER_NAME" --output json | jq -r .region.id)
    local OIDC_ENDPOINT=$(oc get authentication.config.openshift.io cluster -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|^https://||')
    local AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    local CLUSTER_VERSION=$(rosa describe cluster -c "$CLUSTER_NAME" -o json | jq -r .version.raw_id | cut -f -2 -d '.')
    
    echo "Using AWS Account: $AWS_ACCOUNT_ID"
    echo "Using Region: $AWS_REGION"
    echo "OIDC Endpoint: $OIDC_ENDPOINT"
    
    # Define role and policy names
    local ROLE_NAME="${CLUSTER_NAME}-openshift-oadp-aws-cloud-credentials"
    local POLICY_NAME="${CLUSTER_NAME}-velero-policy"
    
    # Check if policy already exists
    local POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='${POLICY_NAME}'].{ARN:Arn}" --output text)
    
    if [[ -z "$POLICY_ARN" ]]; then
        echo "Creating IAM policy: $POLICY_NAME"
        
        # Create policy document
        cat > /tmp/velero-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:CreateBucket",
                "s3:DeleteBucket",
                "s3:PutBucketTagging",
                "s3:GetBucketTagging",
                "s3:PutEncryptionConfiguration",
                "s3:GetEncryptionConfiguration",
                "s3:PutLifecycleConfiguration",
                "s3:GetLifecycleConfiguration",
                "s3:GetBucketLocation",
                "s3:ListBucket",
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucketMultipartUploads",
                "s3:AbortMultipartUpload",
                "s3:ListMultipartUploadParts",
                "ec2:DescribeSnapshots",
                "ec2:DescribeVolumes",
                "ec2:DescribeVolumeAttribute",
                "ec2:DescribeVolumesModifications",
                "ec2:DescribeVolumeStatus",
                "ec2:CreateTags",
                "ec2:CreateVolume",
                "ec2:CreateSnapshot",
                "ec2:DeleteSnapshot"
            ],
            "Resource": "*"
        }
    ]
}
EOF
        
        POLICY_ARN=$(aws iam create-policy \
            --policy-name "$POLICY_NAME" \
            --policy-document file:///tmp/velero-policy.json \
            --tags Key=rosa_cluster_id,Value=$ROSA_CLUSTER_ID Key=rosa_openshift_version,Value=$CLUSTER_VERSION Key=operator_namespace,Value=openshift-adp Key=operator_name,Value=velero \
            --query Policy.Arn --output text)
        
        rm -f /tmp/velero-policy.json
    else
        echo "IAM policy $POLICY_NAME already exists"
    fi
    
    # Check if role already exists
    local ROLE_EXISTS=false
    if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
        echo "IAM role $ROLE_NAME already exists"
        ROLE_EXISTS=true
        local ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)
    else
        echo "Creating IAM role: $ROLE_NAME"
        
        # Create trust policy for OIDC
        cat > /tmp/trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {
            "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ENDPOINT}"
        },
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
            "StringEquals": {
                "${OIDC_ENDPOINT}:sub": [
                    "system:serviceaccount:openshift-adp:openshift-adp-controller-manager",
                    "system:serviceaccount:openshift-adp:velero"
                ]
            }
        }
    }]
}
EOF
        
        ROLE_ARN=$(aws iam create-role \
            --role-name "$ROLE_NAME" \
            --assume-role-policy-document file:///tmp/trust-policy.json \
            --tags Key=rosa_cluster_id,Value=$ROSA_CLUSTER_ID Key=rosa_openshift_version,Value=$CLUSTER_VERSION Key=operator_namespace,Value=openshift-adp Key=operator_name,Value=velero \
            --query Role.Arn --output text)
        
        rm -f /tmp/trust-policy.json
    fi
    
    # Attach policy to role
    echo "Attaching policy to role..."
    aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
    
    echo ""
    echo "Velero identity setup complete!"
    echo ""
    echo "Identity Configuration Summary:"
    echo "  IAM Role Name: $ROLE_NAME"
    echo "  IAM Role ARN: $ROLE_ARN"
    echo "  IAM Policy Name: $POLICY_NAME"
    echo "  IAM Policy ARN: $POLICY_ARN"
    echo "  AWS Account ID: $AWS_ACCOUNT_ID"
    echo "  AWS Region: $AWS_REGION"
    echo ""
    echo "IAM role has been configured with:"
    echo "  ✓ S3 permissions (for backup storage)"
    echo "  ✓ EC2 permissions (for EBS volume snapshots)"
    echo "  ✓ OIDC trust policy for OpenShift workload identity"
    echo ""
    echo "Export these variables for the OADP Makefile:"
    echo "export AWS_ROLE_ARN=$ROLE_ARN"
    echo "export AWS_REGION=$AWS_REGION"
    echo "export OIDC_ENDPOINT=$OIDC_ENDPOINT"
    export AWS_ROLE_ARN=$ROLE_ARN
    export AWS_REGION=$AWS_REGION
    export OIDC_ENDPOINT=$OIDC_ENDPOINT
    echo ""
    echo "Next steps:"
    echo "1. Run 'create-velero-container-for-rosa-cluster' to create S3 bucket"
    echo "2. Deploy OADP operator with: make deploy-olm-stsflow-aws"
    echo "   (The AWS_ROLE_ARN is already exported for you)"
    echo "3. Create DataProtectionApplication with these credentials"
}

# Function to create S3 bucket for Velero backups
znap function create-velero-container-for-rosa-cluster() {
    # Get ROSA cluster name
    local CLUSTER_NAME=$(_get_rosa_cluster_name)
    
    if [[ -z "$CLUSTER_NAME" ]]; then
        return 1
    fi
    
    echo "Creating Velero S3 bucket for cluster: $CLUSTER_NAME"
    
    # Verify this is a ROSA cluster
    if ! rosa describe cluster --cluster "$CLUSTER_NAME" &>/dev/null; then
        echo "ERROR: Cluster $CLUSTER_NAME not found. Is this a ROSA STS cluster?"
        return 1
    fi
    
    # Get AWS region and account
    local AWS_REGION=$(rosa describe cluster -c "$CLUSTER_NAME" --output json | jq -r .region.id)
    local AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    
    echo "Using AWS Region: $AWS_REGION"
    echo "Using AWS Account: $AWS_ACCOUNT_ID"
    
    # S3 bucket name - must be globally unique
    local BUCKET_NAME="${CLUSTER_NAME}-oadp"
    
    # Check if bucket already exists
    if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        echo "S3 bucket $BUCKET_NAME already exists"
    else
        echo "Creating S3 bucket: $BUCKET_NAME"
        
        # Create bucket with proper region configuration
        if [[ "$AWS_REGION" == "us-east-1" ]]; then
            aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION"
        else
            aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
                --create-bucket-configuration LocationConstraint="$AWS_REGION"
        fi
        
        # Enable versioning
        echo "Enabling versioning on bucket..."
        aws s3api put-bucket-versioning --bucket "$BUCKET_NAME" \
            --versioning-configuration Status=Enabled
        
        # Enable encryption
        echo "Enabling encryption on bucket..."
        aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" \
            --server-side-encryption-configuration '{
                "Rules": [
                    {
                        "ApplyServerSideEncryptionByDefault": {
                            "SSEAlgorithm": "AES256"
                        }
                    }
                ]
            }'
        
        # Block public access
        echo "Blocking public access on bucket..."
        aws s3api put-public-access-block --bucket "$BUCKET_NAME" \
            --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
        
        # Add lifecycle policy to delete old backups after 30 days
        echo "Adding lifecycle policy..."
        cat > /tmp/lifecycle-policy.json << EOF
{
    "Rules": [
        {
            "ID": "DeleteOldBackups",
            "Status": "Enabled",
            "Prefix": "velero/",
            "NoncurrentVersionExpiration": {
                "NoncurrentDays": 30
            },
            "AbortIncompleteMultipartUpload": {
                "DaysAfterInitiation": 7
            }
        }
    ]
}
EOF
        
        aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET_NAME" \
            --lifecycle-configuration file:///tmp/lifecycle-policy.json
        
        rm -f /tmp/lifecycle-policy.json
        
        # Tag the bucket
        aws s3api put-bucket-tagging --bucket "$BUCKET_NAME" --tagging '{
            "TagSet": [
                {"Key": "rosa_cluster_name", "Value": "'"$CLUSTER_NAME"'"},
                {"Key": "purpose", "Value": "velero-backup"},
                {"Key": "operator", "Value": "oadp"}
            ]
        }'
    fi
    
    # Verify IAM role has access
    local ROLE_NAME="${CLUSTER_NAME}-openshift-oadp-aws-cloud-credentials"
    if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
        echo "✓ IAM role $ROLE_NAME exists and has S3 permissions"
    else
        echo "WARNING: IAM role $ROLE_NAME not found. Run 'create-velero-identity-for-rosa-cluster' first."
    fi
    
    echo ""
    echo "Velero S3 bucket setup complete!"
    echo ""
    echo "Bucket configuration:"
    echo "  Bucket Name: $BUCKET_NAME"
    echo "  Region: $AWS_REGION"
    echo "  Versioning: Enabled"
    echo "  Encryption: AES256"
    echo "  Public Access: Blocked"
    echo "  Lifecycle: 30-day cleanup for old versions"
    echo ""
    echo "To configure Velero with this bucket:"
    echo "1. Ensure you have run 'create-velero-identity-for-rosa-cluster' first"
    echo "2. Use the following in your BackupStorageLocation:"
    echo "   bucket: $BUCKET_NAME"
    echo "   region: $AWS_REGION"
    echo "   prefix: velero"
}

# Function to create BackupStorageLocation YAML for Velero with ROSA STS
znap function create-velero-bsl-for-rosa-cluster() {
    # Get ROSA cluster name
    local CLUSTER_NAME=$(_get_rosa_cluster_name)
    
    if [[ -z "$CLUSTER_NAME" ]]; then
        return 1
    fi
    
    echo "Creating Velero BackupStorageLocation for cluster: $CLUSTER_NAME"
    
    # Get AWS details
    local AWS_REGION=$(rosa describe cluster -c "$CLUSTER_NAME" --output json | jq -r .region.id)
    local BUCKET_NAME="${CLUSTER_NAME}-oadp"
    
    # Check if bucket exists
    if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        echo "ERROR: S3 bucket $BUCKET_NAME not found"
        echo "Please run 'create-velero-container-for-rosa-cluster' first"
        return 1
    fi
    
    # Check if IAM role exists
    local ROLE_NAME="${CLUSTER_NAME}-openshift-oadp-aws-cloud-credentials"
    if ! aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
        echo "ERROR: IAM role $ROLE_NAME not found"
        echo "Please run 'create-velero-identity-for-rosa-cluster' first"
        return 1
    fi
    
    # Create BSL YAML file
    local BSL_FILE="velero-bsl-${CLUSTER_NAME}.yaml"
    
    echo "Creating BackupStorageLocation YAML: $BSL_FILE"
    
    cat > "$BSL_FILE" << EOF
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: default
  namespace: openshift-adp
spec:
  # AWS S3 provider
  provider: velero.io/aws
  
  objectStorage:
    # The S3 bucket where backups will be stored
    bucket: $BUCKET_NAME
    
    # The prefix within the bucket under which to store backups
    prefix: velero
  
  config:
    # AWS region where the bucket is located
    region: $AWS_REGION
    
    # Enable path style access for S3 (required for some S3-compatible services)
    # For AWS S3, this should be false (default)
    # s3ForcePathStyle: "false"
    
    # URL of S3 endpoint (only needed for S3-compatible services)
    # For AWS S3, this is not needed
    # s3Url: https://s3.amazonaws.com
EOF
    
    echo ""
    echo "BackupStorageLocation YAML created: $BSL_FILE"
    echo ""
    echo "Prerequisites checklist:"
    echo "✓ S3 bucket: $BUCKET_NAME (in region: $AWS_REGION)"
    echo "✓ IAM role: $ROLE_NAME"
    echo ""
    echo "To apply this BackupStorageLocation:"
    echo "  kubectl apply -f $BSL_FILE"
    echo ""
    echo "Make sure you have:"
    echo "1. OADP (OpenShift API for Data Protection) installed"
    echo "2. Cloud credentials secret created in 'openshift-adp' namespace"
    echo "3. DataProtectionApplication configured with AWS provider"
    echo ""
    echo "Note: This BSL is configured for the 'openshift-adp' namespace used by OADP"
}

# Function to create DataProtectionApplication YAML for OADP with ROSA STS
znap function create-velero-dpa-for-rosa-cluster() {
    # Get ROSA cluster name
    local CLUSTER_NAME=$(_get_rosa_cluster_name)
    
    if [[ -z "$CLUSTER_NAME" ]]; then
        return 1
    fi
    
    echo "Creating DataProtectionApplication for cluster: $CLUSTER_NAME"
    
    # Get AWS details
    local AWS_REGION=$(rosa describe cluster -c "$CLUSTER_NAME" --output json | jq -r .region.id)
    local BUCKET_NAME="${CLUSTER_NAME}-oadp"
    local ROLE_NAME="${CLUSTER_NAME}-openshift-oadp-aws-cloud-credentials"
    
    # Check prerequisites
    if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        echo "ERROR: S3 bucket $BUCKET_NAME not found"
        echo "Please run 'create-velero-container-for-rosa-cluster' first"
        return 1
    fi
    
    local ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text 2>/dev/null)
    if [[ -z "$ROLE_ARN" ]]; then
        echo "ERROR: IAM role $ROLE_NAME not found"
        echo "Please run 'create-velero-identity-for-rosa-cluster' first"
        return 1
    fi
    
    # Create DPA YAML file
    local DPA_FILE="velero-dpa-${CLUSTER_NAME}.yaml"
    
    echo "Creating DataProtectionApplication YAML: $DPA_FILE"
    
    cat > "$DPA_FILE" << EOF
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: ${CLUSTER_NAME}-dpa
  namespace: openshift-adp
spec:
  configuration:
    velero:
      # Default plugins for OpenShift and AWS
      defaultPlugins:
        - openshift
        - aws
        - csi
      # Resource requests/limits for Velero pod
      resourceAllocations:
        limits:
          cpu: 1000m
          memory: 512Mi
        requests:
          cpu: 500m
          memory: 256Mi
    # Node agent configuration (formerly Restic)
    nodeAgent:
      enable: true
      uploaderType: kopia
      # Configure the DaemonSet node selector
      nodeSelector:
        node-role.kubernetes.io/worker: ""
  # Enable backup of images stored in internal registry
  backupImages: true
  backupLocations:
    - name: default
      velero:
        # AWS provider configuration
        provider: velero.io/aws
        default: true
        # Credential secret reference (created by STS flow)
        credential:
          name: cloud-credentials-aws
          key: cloud
        # Storage configuration
        objectStorage:
          bucket: $BUCKET_NAME
          prefix: velero
        config:
          region: $AWS_REGION
  # Volume snapshot locations for AWS EBS snapshots
  snapshotLocations:
    - name: default
      velero:
        provider: aws
        # Credential secret reference (created by STS flow)
        credential:
          name: cloud-credentials-aws
          key: cloud
        config:
          region: $AWS_REGION
EOF
    
    # Create credentials file for reference (not needed with STS flow)
    local CREDS_FILE="velero-credentials-${CLUSTER_NAME}-reference.txt"
    
    echo "Creating reference credentials file: $CREDS_FILE"
    echo "Note: With the STS flow, the operator creates the secret automatically"
    
    cat > "$CREDS_FILE" << EOF
# This is for reference only - the OADP operator STS flow creates the secret automatically
# The cloud-credentials-aws secret is created by the operator with these values:
[default]
role_arn = $ROLE_ARN
web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
region=$AWS_REGION
EOF
    
    echo ""
    echo "DataProtectionApplication YAML created: $DPA_FILE"
    echo "Credentials file created: $CREDS_FILE"
    echo ""
    echo "Prerequisites checklist:"
    echo "✓ S3 bucket: $BUCKET_NAME (in region: $AWS_REGION)"
    echo "✓ IAM role: $ROLE_NAME"
    echo "✓ IAM role ARN: $ROLE_ARN"
    echo ""
    echo "To deploy OADP with this configuration:"
    echo "1. Ensure OADP operator is installed with STS flow:"
    echo "   make deploy-olm-stsflow-aws AWS_ROLE_ARN=$ROLE_ARN"
    echo ""
    echo "2. Apply the DataProtectionApplication:"
    echo "   kubectl apply -f $DPA_FILE"
    echo ""
    echo "Make sure you have:"
    echo "1. OADP operator installed with STS flow (cloud-credentials-aws secret will be created automatically)"
    echo "2. The cluster configured with STS (which ROSA clusters are by default)"
    echo ""
    echo "After applying the DPA, check the status with:"
    echo "  kubectl get dpa ${CLUSTER_NAME}-dpa -n openshift-adp -o yaml"
    echo ""
    echo "Verify the deployment:"
    echo "  kubectl get pods -n openshift-adp"
    echo "  kubectl get backupstoragelocations -n openshift-adp"
    echo "  velero version"
}

# Function to validate IAM role assignments for Velero ROSA resources
znap function validate-velero-role-assignments-for-rosa-cluster() {
    # Check if connected to cluster
    if ! oc whoami --show-server &>/dev/null; then
        echo "ERROR: Not connected to an OpenShift cluster. Please login first."
        return 1
    fi
    
    # Get ROSA cluster name
    local CLUSTER_NAME=$(_get_rosa_cluster_name)
    
    if [[ -z "$CLUSTER_NAME" ]]; then
        return 1
    fi
    
    echo "Validating Velero IAM role assignments for cluster: $CLUSTER_NAME"
    echo "================================================================"
    
    # Get AWS details
    local AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    local AWS_REGION=$(rosa describe cluster -c "$CLUSTER_NAME" --output json 2>/dev/null | jq -r .region.id)
    
    if [[ -z "$AWS_REGION" ]]; then
        echo "ERROR: Could not get cluster region. Is this a ROSA cluster?"
        return 1
    fi
    
    echo "AWS Account: $AWS_ACCOUNT_ID"
    echo "AWS Region: $AWS_REGION"
    echo ""
    
    # Check S3 bucket
    local BUCKET_NAME="${CLUSTER_NAME}-oadp"
    
    echo "Checking S3 Bucket: $BUCKET_NAME"
    echo "----------------------------------------"
    
    if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        echo "✓ S3 bucket exists"
        
        # Check bucket configuration
        local VERSIONING=$(aws s3api get-bucket-versioning --bucket "$BUCKET_NAME" --query Status --output text 2>/dev/null)
        if [[ "$VERSIONING" == "Enabled" ]]; then
            echo "✓ Versioning enabled"
        else
            echo "⚠️  Versioning not enabled"
        fi
        
        local ENCRYPTION=$(aws s3api get-bucket-encryption --bucket "$BUCKET_NAME" 2>/dev/null)
        if [[ -n "$ENCRYPTION" ]]; then
            echo "✓ Encryption enabled"
        else
            echo "⚠️  Encryption not configured"
        fi
        
        local PUBLIC_BLOCK=$(aws s3api get-public-access-block --bucket "$BUCKET_NAME" 2>/dev/null)
        if [[ -n "$PUBLIC_BLOCK" ]]; then
            echo "✓ Public access blocked"
        else
            echo "⚠️  Public access block not configured"
        fi
    else
        echo "✗ S3 bucket not found"
        echo "  Run 'create-velero-container-for-rosa-cluster' to create it"
    fi
    
    echo ""
    
    # Check IAM role and policy
    local ROLE_NAME="${CLUSTER_NAME}-openshift-oadp-aws-cloud-credentials"
    local POLICY_NAME="${CLUSTER_NAME}-velero-policy"
    
    echo "Checking IAM Role: $ROLE_NAME"
    echo "----------------------------------------"
    
    local ROLE_INFO=$(aws iam get-role --role-name "$ROLE_NAME" 2>/dev/null)
    if [[ -n "$ROLE_INFO" ]]; then
        local ROLE_ARN=$(echo "$ROLE_INFO" | jq -r .Role.Arn)
        echo "✓ IAM role exists"
        echo "  Role ARN: $ROLE_ARN"
        
        # Check trust policy
        local TRUST_POLICY=$(echo "$ROLE_INFO" | jq -r .Role.AssumeRolePolicyDocument)
        local OIDC_ENDPOINT=$(oc get authentication.config.openshift.io cluster -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|^https://||')
        
        if echo "$TRUST_POLICY" | grep -q "$OIDC_ENDPOINT"; then
            echo "✓ Trust policy includes cluster OIDC endpoint"
        else
            echo "⚠️  Trust policy does not include cluster OIDC endpoint: $OIDC_ENDPOINT"
        fi
        
        # Check service accounts in trust policy
        if echo "$TRUST_POLICY" | grep -q "system:serviceaccount:openshift-adp:velero"; then
            echo "✓ Trust policy includes velero service account"
        else
            echo "⚠️  Trust policy missing velero service account"
        fi
        
        if echo "$TRUST_POLICY" | grep -q "system:serviceaccount:openshift-adp:openshift-adp-controller-manager"; then
            echo "✓ Trust policy includes OADP controller service account"
        else
            echo "⚠️  Trust policy missing OADP controller service account"
        fi
        
        # Check attached policies
        echo ""
        echo "Attached Policies:"
        local ATTACHED_POLICIES=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query AttachedPolicies --output json)
        echo "$ATTACHED_POLICIES" | jq -r '.[] | "  - \(.PolicyName) (\(.PolicyArn))"'
        
        # Check if velero policy is attached
        if echo "$ATTACHED_POLICIES" | grep -q "$POLICY_NAME"; then
            echo "✓ Velero policy is attached"
        else
            echo "⚠️  Velero policy not found or not attached"
        fi
    else
        echo "✗ IAM role not found"
        echo "  Run 'create-velero-identity-for-rosa-cluster' to create it"
    fi
    
    echo ""
    
    # Check IAM policy
    echo "Checking IAM Policy: $POLICY_NAME"
    echo "----------------------------------------"
    
    local POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='${POLICY_NAME}'].{ARN:Arn}" --output text)
    if [[ -n "$POLICY_ARN" ]]; then
        echo "✓ IAM policy exists"
        echo "  Policy ARN: $POLICY_ARN"
        
        # Get policy version
        local DEFAULT_VERSION=$(aws iam get-policy --policy-arn "$POLICY_ARN" --query Policy.DefaultVersionId --output text)
        local POLICY_DOC=$(aws iam get-policy-version --policy-arn "$POLICY_ARN" --version-id "$DEFAULT_VERSION" --query PolicyVersion.Document --output json)
        
        # Check for required permissions
        local REQUIRED_ACTIONS=("s3:CreateBucket" "s3:GetObject" "s3:PutObject" "ec2:CreateSnapshot" "ec2:DescribeSnapshots")
        echo ""
        echo "Required permissions check:"
        for action in "${REQUIRED_ACTIONS[@]}"; do
            if echo "$POLICY_DOC" | grep -q "\"$action\""; then
                echo "  ✓ $action"
            else
                echo "  ✗ $action missing"
            fi
        done
    else
        echo "✗ IAM policy not found"
        echo "  Run 'create-velero-identity-for-rosa-cluster' to create it"
    fi
    
    echo ""
    echo "================================================================"
    echo "Validation Summary:"
    echo ""
    
    # Summary checks
    local ISSUES=0
    
    # S3 bucket check
    if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        echo "⚠️  S3 bucket missing"
        ((ISSUES++))
    fi
    
    # IAM role check
    if [[ -z "$ROLE_INFO" ]]; then
        echo "⚠️  IAM role missing"
        ((ISSUES++))
    else
        # Check if policy is attached
        if ! echo "$ATTACHED_POLICIES" | grep -q "$POLICY_NAME"; then
            echo "⚠️  Velero policy not attached to role"
            ((ISSUES++))
        fi
    fi
    
    # IAM policy check
    if [[ -z "$POLICY_ARN" ]]; then
        echo "⚠️  IAM policy missing"
        ((ISSUES++))
    fi
    
    if [[ $ISSUES -eq 0 ]]; then
        echo "✅ All IAM role assignments appear to be correctly configured!"
    else
        echo ""
        echo "❌ Found $ISSUES issue(s) with IAM role assignments"
        echo ""
        echo "To fix these issues, run:"
        echo "  create-velero-identity-for-rosa-cluster"
        echo "  create-velero-container-for-rosa-cluster"
    fi
    
    echo ""
    echo "To see detailed IAM information:"
    echo "  # IAM role details:"
    echo "  aws iam get-role --role-name $ROLE_NAME"
    echo "  # IAM policy details:"
    echo "  aws iam get-policy --policy-arn $POLICY_ARN"
    echo "  # S3 bucket details:"
    echo "  aws s3api get-bucket-location --bucket $BUCKET_NAME"
}

# Function to setup complete Velero/OADP for current ROSA cluster
znap function setup-velero-oadp-for-rosa-cluster() {
    echo "Starting complete Velero/OADP setup for ROSA cluster..."
    echo "================================================================"
    
    # Check if connected to cluster
    if ! oc whoami --show-server &>/dev/null; then
        echo "ERROR: Not connected to an OpenShift cluster. Please login first."
        return 1
    fi
    
    # Get ROSA cluster name
    local CLUSTER_NAME=$(_get_rosa_cluster_name)
    
    if [[ -z "$CLUSTER_NAME" ]]; then
        return 1
    fi
    
    echo "Cluster: $CLUSTER_NAME"
    echo ""
    
    # Step 1: Create Velero identity
    echo "Step 1: Creating Velero IAM identity..."
    echo "---------------------------------------"
    if ! create-velero-identity-for-rosa-cluster; then
        echo "ERROR: Failed to create Velero IAM identity"
        return 1
    fi
    echo ""
    
    # Step 2: Create S3 bucket
    echo "Step 2: Creating Velero S3 bucket..."
    echo "------------------------------------"
    if ! create-velero-container-for-rosa-cluster; then
        echo "ERROR: Failed to create Velero S3 bucket"
        return 1
    fi
    echo ""
    
    # Step 3: Deploy OADP operator with STS flow
    echo "Step 3: Deploying OADP operator with STS flow..."
    echo "------------------------------------------------"
    
    # Get IAM role ARN
    local ROLE_NAME="${CLUSTER_NAME}-openshift-oadp-aws-cloud-credentials"
    local ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text 2>/dev/null)
    
    if [[ -z "$ROLE_ARN" ]]; then
        echo "ERROR: Could not find IAM role ARN"
        return 1
    fi
    
    # Check if we're in an OADP repo directory
    if [[ -f "Makefile" ]] && grep -q "deploy-olm-stsflow-aws" Makefile 2>/dev/null; then
        echo "Found OADP Makefile in current directory"
    else
        echo "WARNING: Not in OADP operator directory. Please ensure you're in the correct directory."
        echo "You can clone it with: git clone https://github.com/openshift/oadp-operator.git"
        echo ""
        echo "Would you like to continue anyway? (y/N)"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "Aborting setup"
            return 1
        fi
    fi
    
    # Export the role ARN for the Makefile
    export AWS_ROLE_ARN="$ROLE_ARN"
    
    echo "Running: make deploy-olm-stsflow-aws AWS_ROLE_ARN=$ROLE_ARN"
    if ! make deploy-olm-stsflow-aws AWS_ROLE_ARN="$ROLE_ARN"; then
        echo "ERROR: Failed to deploy OADP operator"
        echo "Please check the output above for errors"
        return 1
    fi
    
    # Wait for operator to be ready
    echo "Waiting for OADP operator to be ready..."
    local retries=60
    while [[ $retries -gt 0 ]]; do
        if oc get pods -n openshift-adp 2>/dev/null | grep -q "oadp-operator.*Running"; then
            echo "OADP operator is running"
            break
        fi
        echo -n "."
        sleep 5
        ((retries--))
    done
    
    if [[ $retries -eq 0 ]]; then
        echo ""
        echo "WARNING: OADP operator may not be fully ready yet"
    fi
    echo ""
    
    # Step 4: Wait for STS secret to be created
    echo "Step 4: Waiting for STS credentials to be configured..."
    echo "-------------------------------------------------------"
    
    # The STS flow should create the cloud-credentials secret automatically
    echo "Waiting for cloud-credentials secret to be created by OADP operator..."
    local secret_retries=30
    while [[ $secret_retries -gt 0 ]]; do
        if oc get secret cloud-credentials-aws -n openshift-adp &>/dev/null; then
            echo "✓ STS credentials secret created"
            break
        fi
        echo -n "."
        sleep 5
        ((secret_retries--))
    done
    
    if [[ $secret_retries -eq 0 ]]; then
        echo ""
        echo "WARNING: STS credentials secret not found. The operator should create this automatically."
        echo "Check the OADP operator logs for issues."
    fi
    echo ""
    
    # Step 5: Create CloudStorage resource
    echo "Step 5: Creating CloudStorage resource..."
    echo "----------------------------------------"
    
    local BUCKET_NAME="${CLUSTER_NAME}-oadp"
    
    cat << EOF | oc apply -f -
apiVersion: oadp.openshift.io/v1alpha1
kind: CloudStorage
metadata:
  name: ${CLUSTER_NAME}-oadp
  namespace: openshift-adp
spec:
  creationSecret:
    key: credentials
    name: cloud-credentials
  enableSharedConfig: true
  name: ${CLUSTER_NAME}-oadp
  provider: aws
  region: $AWS_REGION
EOF
    
    echo ""
    
    # Step 6: Create and apply DataProtectionApplication
    echo "Step 6: Creating and applying DataProtectionApplication..."
    echo "---------------------------------------------------------"
    if ! create-velero-dpa-for-rosa-cluster; then
        echo "ERROR: Failed to create DataProtectionApplication YAML"
        return 1
    fi
    
    # Get the DPA file name
    local DPA_FILE="velero-dpa-${CLUSTER_NAME}.yaml"
    
    if [[ ! -f "$DPA_FILE" ]]; then
        echo "ERROR: DataProtectionApplication file not found: $DPA_FILE"
        return 1
    fi
    
    echo "Applying DataProtectionApplication..."
    if ! oc apply -f "$DPA_FILE"; then
        echo "ERROR: Failed to apply DataProtectionApplication"
        return 1
    fi
    echo ""
    
    # Step 7: Wait for Velero to be ready
    echo "Step 7: Waiting for Velero deployment to be ready..."
    echo "---------------------------------------------------"
    local velero_ready=false
    retries=60  # 5 minutes timeout
    
    while [[ $retries -gt 0 ]]; do
        if oc get pods -n openshift-adp -l app.kubernetes.io/name=velero 2>/dev/null | grep -q "velero.*Running"; then
            velero_ready=true
            break
        fi
        echo -n "."
        sleep 5
        ((retries--))
    done
    
    echo ""
    
    if [[ "$velero_ready" == "true" ]]; then
        echo "✓ Velero is running"
    else
        echo "⚠️  Velero may not be fully ready yet"
    fi
    
    # Step 8: Validate setup
    echo ""
    echo "Step 8: Validating Velero setup..."
    echo "----------------------------------"
    
    # Check Velero version
    if command -v velero &>/dev/null; then
        echo "Velero CLI version:"
        velero version --client-only
    else
        echo "Velero CLI not found. Install it from: https://velero.io/docs/main/basic-install/#install-the-cli"
    fi
    
    # Check DPA status
    echo ""
    echo "DataProtectionApplication status:"
    oc get dpa ${CLUSTER_NAME}-dpa -n openshift-adp -o jsonpath='{.status.conditions[?(@.type=="Reconciled")]}' | jq '.' 2>/dev/null || echo "Status not yet available"
    
    # Check pods
    echo ""
    echo "OADP/Velero pods:"
    oc get pods -n openshift-adp
    
    # Check backup storage location
    echo ""
    echo "Backup Storage Locations:"
    oc get backupstoragelocations -n openshift-adp
    
    # Final summary
    echo ""
    echo "================================================================"
    echo "Velero/OADP Setup Complete!"
    echo "================================================================"
    echo ""
    echo "Next steps:"
    echo "1. Verify the setup with: oc get all -n openshift-adp"
    echo "2. Check backup storage location: oc get backupstoragelocation -n openshift-adp"
    echo "3. Create your first backup: velero backup create test-backup --include-namespaces=<namespace>"
    echo ""
    echo "DataProtectionApplication file saved as: $DPA_FILE"
    echo ""
    echo "To create a backup of a namespace:"
    echo "  velero backup create <backup-name> --include-namespaces=<namespace-name>"
    echo ""
    echo "To restore from a backup:"
    echo "  velero restore create --from-backup <backup-name>"
    echo ""
    echo "To troubleshoot issues:"
    echo "- Check DPA status: oc describe dpa ${CLUSTER_NAME}-dpa -n openshift-adp"
    echo "- Check Velero logs: oc logs -n openshift-adp -l app.kubernetes.io/name=velero"
    echo "- Validate IAM assignments: validate-velero-role-assignments-for-rosa-cluster"
}

# Function to cleanup Velero resources for ROSA cluster
znap function cleanup-velero-rosa-resources() {
    # Check if connected to cluster
    if ! oc whoami --show-server &>/dev/null; then
        echo "ERROR: Not connected to an OpenShift cluster. Please login first."
        return 1
    fi
    
    # Get ROSA cluster name
    local CLUSTER_NAME=$(_get_rosa_cluster_name)
    
    if [[ -z "$CLUSTER_NAME" ]]; then
        return 1
    fi
    
    echo "WARNING: This will delete all Velero/OADP resources for cluster: $CLUSTER_NAME"
    echo "This includes:"
    echo "  - All backups and restores"
    echo "  - S3 bucket and its contents"
    echo "  - IAM role and policy"
    echo "  - OADP operator and resources"
    echo ""
    echo -n "Are you sure you want to continue? (yes/no): "
    read -r response
    
    if [[ "$response" != "yes" ]]; then
        echo "Cleanup cancelled"
        return 0
    fi
    
    echo ""
    echo "Starting cleanup..."
    echo ""
    
    # Step 1: Delete backups and restores
    echo "Step 1: Deleting Velero backups and restores..."
    echo "-----------------------------------------------"
    
    if command -v velero &>/dev/null; then
        # Get all backups
        local backups=$(velero backup get -o json 2>/dev/null | jq -r '.items[].metadata.name' 2>/dev/null)
        if [[ -n "$backups" ]]; then
            echo "Deleting backups:"
            while IFS= read -r backup; do
                echo "  - $backup"
                velero backup delete "$backup" --confirm
            done <<< "$backups"
        else
            echo "No backups found"
        fi
        
        # Get all restores
        local restores=$(velero restore get -o json 2>/dev/null | jq -r '.items[].metadata.name' 2>/dev/null)
        if [[ -n "$restores" ]]; then
            echo "Deleting restores:"
            while IFS= read -r restore; do
                echo "  - $restore"
                velero restore delete "$restore" --confirm
            done <<< "$restores"
        else
            echo "No restores found"
        fi
    else
        echo "Velero CLI not found, skipping backup/restore deletion"
    fi
    echo ""
    
    # Step 2: Delete DataProtectionApplication
    echo "Step 2: Deleting DataProtectionApplication..."
    echo "--------------------------------------------"
    if oc get dpa ${CLUSTER_NAME}-dpa -n openshift-adp &>/dev/null; then
        oc delete dpa ${CLUSTER_NAME}-dpa -n openshift-adp
    else
        echo "DataProtectionApplication not found"
    fi
    echo ""
    
    # Step 3: Delete CloudStorage
    echo "Step 3: Deleting CloudStorage..."
    echo "--------------------------------"
    if oc get cloudstorage ${CLUSTER_NAME}-oadp -n openshift-adp &>/dev/null; then
        oc delete cloudstorage ${CLUSTER_NAME}-oadp -n openshift-adp
        
        # If deletion hangs, remove finalizer
        if oc get cloudstorage ${CLUSTER_NAME}-oadp -n openshift-adp &>/dev/null; then
            echo "Removing finalizer..."
            oc patch cloudstorage ${CLUSTER_NAME}-oadp -n openshift-adp -p '{"metadata":{"finalizers":null}}' --type=merge
        fi
    else
        echo "CloudStorage not found"
    fi
    echo ""
    
    # Step 4: Delete S3 bucket
    echo "Step 4: Deleting S3 bucket..."
    echo "-----------------------------"
    local BUCKET_NAME="${CLUSTER_NAME}-oadp"
    
    if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        echo "Deleting bucket contents..."
        aws s3 rm s3://${BUCKET_NAME} --recursive
        
        echo "Deleting bucket..."
        aws s3api delete-bucket --bucket ${BUCKET_NAME}
    else
        echo "S3 bucket not found"
    fi
    echo ""
    
    # Step 5: Delete IAM resources
    echo "Step 5: Deleting IAM resources..."
    echo "---------------------------------"
    local ROLE_NAME="${CLUSTER_NAME}-openshift-oadp-aws-cloud-credentials"
    local POLICY_NAME="${CLUSTER_NAME}-velero-policy"
    
    # Get policy ARN
    local POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='${POLICY_NAME}'].{ARN:Arn}" --output text)
    
    # Detach policy from role
    if [[ -n "$POLICY_ARN" ]] && aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
        echo "Detaching policy from role..."
        aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
    fi
    
    # Delete role
    if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
        echo "Deleting IAM role..."
        aws iam delete-role --role-name "$ROLE_NAME"
    else
        echo "IAM role not found"
    fi
    
    # Delete policy
    if [[ -n "$POLICY_ARN" ]]; then
        echo "Deleting IAM policy..."
        aws iam delete-policy --policy-arn "$POLICY_ARN"
    else
        echo "IAM policy not found"
    fi
    echo ""
    
    # Step 6: Delete OADP operator (optional)
    echo "Step 6: Delete OADP operator?"
    echo "------------------------------"
    echo -n "Do you want to delete the OADP operator? (yes/no): "
    read -r delete_operator
    
    if [[ "$delete_operator" == "yes" ]]; then
        # Delete subscription
        if oc get subscription redhat-oadp-operator -n openshift-adp &>/dev/null; then
            echo "Deleting OADP subscription..."
            oc delete subscription redhat-oadp-operator -n openshift-adp
        fi
        
        # Delete operator group
        if oc get operatorgroup oadp -n openshift-adp &>/dev/null; then
            echo "Deleting operator group..."
            oc delete operatorgroup oadp -n openshift-adp
        fi
        
        # Delete namespace
        echo -n "Delete the openshift-adp namespace? (yes/no): "
        read -r delete_namespace
        
        if [[ "$delete_namespace" == "yes" ]]; then
            echo "Deleting namespace..."
            oc delete namespace openshift-adp
        fi
        
        # Delete CRDs
        echo -n "Delete OADP CRDs? (yes/no): "
        read -r delete_crds
        
        if [[ "$delete_crds" == "yes" ]]; then
            echo "Deleting Velero CRDs..."
            for CRD in $(oc get crds | grep velero | awk '{print $1}'); do
                oc delete crd $CRD
            done
            
            echo "Deleting OADP CRDs..."
            for CRD in $(oc get crds | grep -i oadp | awk '{print $1}'); do
                oc delete crd $CRD
            done
        fi
    fi
    
    # Clean up local files
    echo ""
    echo "Step 7: Cleaning up local files..."
    echo "----------------------------------"
    local files_to_delete=(
        "velero-bsl-${CLUSTER_NAME}.yaml"
        "velero-dpa-${CLUSTER_NAME}.yaml"
        "velero-credentials-${CLUSTER_NAME}"
    )
    
    for file in "${files_to_delete[@]}"; do
        if [[ -f "$file" ]]; then
            echo "Deleting $file"
            rm -f "$file"
        fi
    done
    
    echo ""
    echo "================================================================"
    echo "Velero/OADP Cleanup Complete!"
    echo "================================================================"
    echo ""
    echo "All Velero/OADP resources have been removed for cluster: $CLUSTER_NAME"
    echo ""
    echo "Removed:"
    echo "✓ Velero backups and restores"
    echo "✓ DataProtectionApplication and CloudStorage resources"
    echo "✓ S3 bucket: $BUCKET_NAME"
    echo "✓ IAM role: $ROLE_NAME"
    echo "✓ IAM policy: $POLICY_NAME"
    if [[ "$delete_operator" == "yes" ]]; then
        echo "✓ OADP operator"
    fi
    echo ""
    echo "To reinstall Velero/OADP, run: setup-velero-oadp-for-rosa-cluster"
}