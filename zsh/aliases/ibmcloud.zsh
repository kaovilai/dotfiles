# IBM Cloud related aliases
alias ibmcloud-login='ibmcloud login --sso'
alias ibmcloud-vpcid='ibmcloud ks vpcs | grep -e "^tiger-vpc " | sed "s/  */ /g" | cut -d" " -f2'
alias ibmcloud-vpc-gen2zone='echo us-east-1'
alias ibmcloud-subnetid='ibmcloud ks subnets --provider vpc-gen2 --vpc-id $(ibmcloud-vpcid) --zone $(ibmcloud-vpc-gen2zone) --output json | jq --raw-output ".[0].id"'
alias ibmcloud-oc-latestversion='echo $(ibmcloud oc versions --show-version openshift --output json | jq ".openshift[-1].major").$(ibmcloud oc versions --show-version openshift --output json | jq ".openshift[-1].minor").$(ibmcloud oc versions --show-version openshift --output json | jq ".openshift[-1].patch")_openshift'
alias ibmcloud-cos-instance='echo \"$(ibmcloud resource service-instances --service-name cloud-object-storage --output json | grep tkaovila | cut -d":" -f2 | cut -d'"'"'"'"'"' -f2)\" | grep \" | sed "s/ /\\\ /g"'
alias ibmcloud-cos-instance-crn='ibmcloud resource service-instances --long --service-name cloud-object-storage --output json | jq --raw-output ".[] | select(.name==\"Cloud Object Storage-tkaovila-89\") | .id"'
alias ibmcloud-oc-cluster-create='ibmcloud oc cluster create vpc-gen2 --name tiger-2 --zone us-east-1 --vpc-id $(ibmcloud-vpcid) --subnet-id $(ibmcloud-subnetid) --flavor cx2.8x16 --workers 2 --cos-instance=$(ibmcloud-cos-instance-crn) --version $(ibmcloud-oc-latestversion)'
alias ibmcloud-oc-config='ibmcloud oc cluster config --admin -c tiger-2'
