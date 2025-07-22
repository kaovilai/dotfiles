# Configuring OADP on Red Hat OpenShift Service on AWS (ROSA) with STS

## Overview

This tutorial explains how to configure OpenShift API for Data Protection (OADP) on Red Hat OpenShift Service on AWS (ROSA) clusters using AWS Security Token Service (STS). ROSA clusters with STS use short-term credentials for enhanced security, eliminating the need for long-lived access keys.

**Note**: This guide incorporates the new standardized authentication flow introduced in [OADP PR #1836](https://github.com/openshift/oadp-operator/pull/1836), which simplifies the credential configuration process.

## Prerequisites

Before you begin, ensure you have:

* A ROSA cluster with STS enabled
* AWS CLI configured with appropriate permissions
* OpenShift CLI (`oc`) installed and configured
* Access to the ROSA cluster as a user with cluster-admin privileges
* An S3 bucket for storing backups

## Procedure

### Step 1: Obtain AWS account information

1. Set your AWS account ID as an environment variable:
   ```bash
   export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
   ```

2. Get your ROSA cluster name:
   ```bash
   export CLUSTER_NAME=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
   ```

3. Get the OIDC provider endpoint:
   ```bash
   export OIDC_ENDPOINT=$(oc get authentication.config.openshift.io cluster -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|https://||')
   ```

### Step 2: Create an S3 bucket for backups

If you haven't already created an S3 bucket for backups:

```bash
export BUCKET_NAME=oadp-backup-${CLUSTER_NAME}
export AWS_REGION=us-east-1  # Change to your desired region

aws s3api create-bucket \
    --bucket ${BUCKET_NAME} \
    --region ${AWS_REGION}
```

### Step 3: Create IAM policy for OADP

1. Create a policy document for OADP permissions:
   ```bash
   cat > oadp-policy.json <<EOF
   {
       "Version": "2012-10-17",
       "Statement": [
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
                   "arn:aws:s3:::${BUCKET_NAME}/*"
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
                   "arn:aws:s3:::${BUCKET_NAME}"
               ]
           },
           {
               "Effect": "Allow",
               "Action": [
                   "ec2:CreateSnapshot",
                   "ec2:CreateTags",
                   "ec2:CreateVolume",
                   "ec2:DeleteSnapshot",
                   "ec2:DescribeSnapshots",
                   "ec2:DescribeVolumes"
               ],
               "Resource": "*"
           }
       ]
   }
   EOF
   ```

2. Create the IAM policy:
   ```bash
   aws iam create-policy \
       --policy-name ${CLUSTER_NAME}-oadp-policy \
       --policy-document file://oadp-policy.json \
       --description "Policy for OADP operator on ROSA cluster ${CLUSTER_NAME}"
   
   export POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='${CLUSTER_NAME}-oadp-policy'].Arn" --output text)
   ```

### Step 4: Create IAM role with trust policy

1. Create a trust policy for the OADP service account:
   ```bash
   cat > trust-policy.json <<EOF
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
                   "${OIDC_ENDPOINT}:sub": "system:serviceaccount:openshift-adp:velero"
               }
           }
       }]
   }
   EOF
   ```

2. Create the IAM role:
   ```bash
   aws iam create-role \
       --role-name ${CLUSTER_NAME}-oadp-role \
       --assume-role-policy-document file://trust-policy.json \
       --description "Role for OADP operator on ROSA cluster ${CLUSTER_NAME}"
   
   export ROLE_ARN=$(aws iam get-role --role-name ${CLUSTER_NAME}-oadp-role --query 'Role.Arn' --output text)
   ```

3. Attach the policy to the role:
   ```bash
   aws iam attach-role-policy \
       --role-name ${CLUSTER_NAME}-oadp-role \
       --policy-arn ${POLICY_ARN}
   ```

### Step 5: Install OADP Operator

With the new standardized authentication flow:

1. Navigate to **Operators** → **OperatorHub** in the OpenShift web console

2. Search for **OADP Operator** and click on it

3. Click **Install**

4. Select the following options:
   * Update channel: **stable**
   * Installation mode: **A specific namespace on the cluster**
   * Installed Namespace: **openshift-adp** (this will be created automatically)
   * Update approval: **Automatic** or **Manual** based on your preference

5. During the installation process, when prompted for authentication configuration:
   * Select **AWS** as the cloud provider
   * Enter the Role ARN: `${ROLE_ARN}` (use the actual value from Step 4)
   
   The operator will automatically create the `cloud-credentials-aws` secret with the appropriate STS configuration.

6. Click **Install** and wait for the operator to be ready

### Step 6: Create Data Protection Application

1. Create a DataProtectionApplication custom resource:
   ```bash
   cat > dpa-aws-sts.yaml <<EOF
   apiVersion: oadp.openshift.io/v1alpha1
   kind: DataProtectionApplication
   metadata:
     name: dpa-aws-sts
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
             prefix: velero
           config:
             region: ${AWS_REGION}
     configuration:
       velero:
         defaultPlugins:
           - openshift
           - aws
         resourceTimeout: 10m
       restic:
         enable: true
     snapshotLocations:
       - velero:
           provider: aws
           config:
             region: ${AWS_REGION}
   EOF
   ```

2. Apply the configuration:
   ```bash
   oc apply -f dpa-aws-sts.yaml
   ```

### Step 7: Verify the installation

1. Check the DataProtectionApplication status:
   ```bash
   oc get dpa -n openshift-adp dpa-aws-sts -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}'
   ```
   
   The output should be `Complete` when the configuration is successful.

2. Verify the backup storage location:
   ```bash
   oc get backupstoragelocations -n openshift-adp
   ```
   
   Expected output:
   ```
   NAME              PHASE       LAST VALIDATED   AGE   DEFAULT
   dpa-aws-sts-1     Available   12s              30s   true
   ```

### Step 8: Create a test backup

1. Create a test application:
   ```bash
   oc create namespace test-backup
   oc create deployment hello-world --image=gcr.io/google-samples/hello-app:1.0 -n test-backup
   ```

2. Create a backup:
   ```bash
   cat > backup-test.yaml <<EOF
   apiVersion: velero.io/v1
   kind: Backup
   metadata:
     name: test-backup
     namespace: openshift-adp
   spec:
     includedNamespaces:
       - test-backup
     storageLocation: dpa-aws-sts-1
     ttl: 720h0m0s
   EOF
   
   oc apply -f backup-test.yaml
   ```

3. Monitor the backup progress:
   ```bash
   oc get backup -n openshift-adp test-backup -w
   ```

## Verification

To verify that your backup was successful:

1. Check the backup details:
   ```bash
   oc describe backup test-backup -n openshift-adp
   ```

2. List objects in your S3 bucket:
   ```bash
   aws s3 ls s3://${BUCKET_NAME}/velero/backups/
   ```

## Troubleshooting

### Authentication issues

If you encounter authentication errors:

1. Verify the service account annotation:
   ```bash
   oc get sa velero -n openshift-adp -o yaml
   ```
   
   The service account should have the annotation:
   ```yaml
   eks.amazonaws.com/role-arn: ${ROLE_ARN}
   ```

2. Check Velero pod logs:
   ```bash
   oc logs -n openshift-adp deployment/velero
   ```

### Backup failures

For backup failures:

1. Check the backup status:
   ```bash
   oc get backup -n openshift-adp test-backup -o yaml
   ```

2. Review events:
   ```bash
   oc get events -n openshift-adp --sort-by='.lastTimestamp'
   ```

## Additional resources

* [OADP documentation](https://docs.openshift.com/container-platform/latest/backup_and_restore/application_backup_and_restore/oadp-intro.html)
* [ROSA with STS documentation](https://docs.openshift.com/rosa/rosa_architecture/rosa-sts-about-iam-resources.html)
* [OADP Operator GitHub repository](https://github.com/openshift/oadp-operator)
* [PR #1836 - Standardized authentication flow](https://github.com/openshift/oadp-operator/pull/1836)