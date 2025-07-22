# Configuring OADP on OpenShift with AWS STS Authentication

## Overview

This tutorial explains how to configure OpenShift API for Data Protection (OADP) on OpenShift clusters using AWS Security Token Service (STS). This method uses short-term credentials for enhanced security, eliminating the need for long-lived access keys.

**Note**: This guide incorporates the new standardized authentication flow introduced in [OADP PR #1836](https://github.com/openshift/oadp-operator/pull/1836), which simplifies the credential configuration process.

## Prerequisites

Before you begin, ensure you have:

* An OpenShift cluster installed on AWS with STS configured
* AWS CLI configured with appropriate permissions
* OpenShift CLI (`oc`) installed and configured
* Access to the OpenShift cluster as a user with cluster-admin privileges
* AWS IAM permissions to create roles and policies
* An S3 bucket for storing backups

## Procedure

### Step 1: Create IAM policy for OADP

1. Create an IAM policy with the required permissions for OADP operations:

```bash
cat > velero-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:DescribeVolumes",
                "ec2:DescribeSnapshots",
                "ec2:CreateTags",
                "ec2:CreateVolume",
                "ec2:CreateSnapshot",
                "ec2:DeleteSnapshot"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:DeleteObject",
                "s3:PutObject",
                "s3:AbortMultipartUpload",
                "s3:ListMultipartUploadParts"
            ],
            "Resource": [
                "arn:aws:s3:::${BUCKET}/*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetBucketLocation",
                "s3:ListBucketMultipartUploads"
            ],
            "Resource": [
                "arn:aws:s3:::${BUCKET}"
            ]
        }
    ]
}
EOF

# Create the policy
aws iam create-policy \
    --policy-name VeleroAccessPolicy \
    --policy-document file://velero-policy.json
```

### Step 2: Create IAM role with trust policy

1. Create an IAM role that trusts the OpenShift cluster's OIDC provider:

```bash
# Get your cluster's OIDC provider
OIDC_PROVIDER=$(oc get authentication.config.openshift.io cluster -o json | jq -r .spec.serviceAccountIssuer | sed 's|https://||')

# Create trust policy
cat > trust-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {
            "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
        },
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
            "StringEquals": {
                "${OIDC_PROVIDER}:sub": "system:serviceaccount:openshift-adp:velero"
            }
        }
    }]
}
EOF

# Create the role
aws iam create-role \
    --role-name VeleroRole \
    --assume-role-policy-document file://trust-policy.json

# Attach the policy to the role
aws iam attach-role-policy \
    --role-name VeleroRole \
    --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/VeleroAccessPolicy
```

### Step 3: Install OADP Operator

With the new standardized authentication flow:

1. Navigate to OperatorHub in the OpenShift console
2. Search for "OADP Operator"
3. Click Install
4. During installation, you'll see the tokenized authentication option
5. Select "AWS" for the authentication method
6. You'll be prompted to enter:
   * Role ARN (e.g., `arn:aws:iam::123456789012:role/VeleroRole`)

The operator will automatically create the necessary secret with the STS configuration.

### Step 4: Create Data Protection Application

1. Create a DataProtectionApplication custom resource:

```yaml
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: aws-sts-dpa
  namespace: openshift-adp
spec:
  backupLocations:
    - velero:
        provider: aws
        default: true
        credential:
          key: cloud
          name: cloud-credentials-aws
        objectStorage:
          bucket: ${BUCKET_NAME}
          prefix: ${BACKUP_PREFIX}
        config:
          region: ${AWS_REGION}
  configuration:
    velero:
      defaultPlugins:
        - openshift
        - aws
  snapshotLocations:
    - velero:
        provider: aws
        config:
          region: ${AWS_REGION}
```

### Step 5: Verify the installation

1. Check the backup storage location:

```bash
oc get backupstoragelocations -n openshift-adp
```

Expected output:

```
NAME            PHASE       LAST VALIDATED   AGE   DEFAULT
aws-sts-dpa-1   Available   12s              30s   true
```

### Step 6: Create a test backup

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

1. **Authentication failures**: Ensure the trust policy correctly references your OIDC provider
2. **Permission denied errors**: Verify the IAM policy includes all necessary permissions
3. **Bucket access issues**: Check that the bucket name and region are correct

### Debugging commands

```bash
# Check Velero pod logs
oc logs -n openshift-adp deployment/velero

# Verify secret creation
oc get secret cloud-credentials-aws -n openshift-adp -o yaml

# Check service account annotation
oc get sa velero -n openshift-adp -o yaml
```

## Additional resources

* [OADP documentation](https://docs.openshift.com/container-platform/latest/backup_and_restore/application_backup_and_restore/oadp-intro.html)
* [AWS STS documentation](https://docs.aws.amazon.com/STS/latest/APIReference/welcome.html)
* [OADP Operator GitHub repository](https://github.com/openshift/oadp-operator)
* [PR #1836 - Standardized authentication flow](https://github.com/openshift/oadp-operator/pull/1836)
