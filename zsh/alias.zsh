# non os specific aliases
alias db='docker build'
alias dbt='docker build --tag'
alias dbr='docker build --tag $(ghcr_tag)'
alias dbrp='docker build --tag $(ghcr_tag) --push'
alias db_amd64='docker build --platform linux/amd64'
alias db_amd64t='docker build --platform linux/amd64 --tag'
alias db_amd64r='docker build --platform linux/amd64 --tag $(ghcr_tag)'
alias db_amd64rp='docker build --platform linux/amd64 --tag $(ghcr_tag) --push'
alias multiarch='echo linux/amd64,linux/arm64'
alias single_arch='echo linux/amd64'
alias db_single='docker build --platform linux/amd64'
alias db_multi='docker buildx build --platform linux/amd64,linux/arm64'
alias db_multit='docker buildx build --platform linux/amd64,linux/arm64 --tag'
alias db_multir='docker buildx build --platform linux/amd64,linux/arm64 --tag $(ghcr_tag)'
alias db_multip='docker buildx build --platform linux/amd64,linux/arm64 --tag $(ghcr_tag) --push'
alias dbubi_multi='docker buildx build --platform=linux/amd64,linux/arm64 -t $(ghcr_tag) -f Dockerfile.ubi .'
alias dbubi_multip='docker buildx build --platform=linux/amd64,linux/arm64 -t $(ghcr_tag) -f Dockerfile.ubi --push .'
alias docker-crc='eval $(crc podman-env)'
docker-crc
alias podman='~/.crc/bin/podman/podman'
alias docker-buildx-crc='docker buildx rm crc; crc start; oc --kubeconfig ~/.crc/machines/crc/kubeconfig create ns docker-driver > /dev/null 2>&1; oc --kubeconfig ~/.crc/machines/crc/kubeconfig create role docker-driver --verb use --resource scc --resource-name privileged -n docker-driver; oc --kubeconfig ~/.crc/machines/crc/kubeconfig create sa -n docker-driver docker-driver; oc --kubeconfig ~/.crc/machines/crc/kubeconfig create rolebinding docker-driver-rolebinding --role docker-driver --serviceaccount docker-driver:docker-driver -n docker-driver; KUBECONFIG=~/.crc/machines/crc/kubeconfig docker buildx create --name crc --driver kubernetes --driver-opt=namespace=docker-driver,qemu.install=true,annotations=openshift.io/required-scc=privileged,serviceaccount=docker-driver --use --bootstrap && docker-crc'
alias colima-restart='colima stop; colima start --arch aarch64 --vm-type=vz --vz-rosetta --cpu 8 --disk 30 --memory 3; colima-multiplat'
alias colima-multiplat='docker buildx rm colima-multiplat; docker buildx create --name colima-multiplat --platform=linux/amd64,linux/arm64,linux/ppc64le,linux/s390x; docker buildx use colima-multiplat'
alias coadp='code ~/oadp-operator/'
alias cvelero='code ~/git/velero/'
alias cvelero-aws='code ~/git/velero-plugin-for-aws/'
alias cvelero-gcp='code ~/git/velero-plugin-for-gcp/'
alias cvelero-azure='code ~/git/velero-plugin-for-microsoft-azure/'
alias cvelero-ocp='code ~/git/openshift-velero-plugin/'
alias cvelero-lvp='code ~/git/local-volume-provider/'
alias clvp='code ~/git/local-volume-provider/'
alias cluster-arch="kubectl get nodes -o jsonpath='{range .items[0]}{.status.nodeInfo.operatingSystem}{\"/\"}{.status.nodeInfo.architecture}{end}'"
# without linux/
alias cluster-arch-only="kubectl get nodes -o jsonpath='{range .items[0]}{.status.nodeInfo.architecture}{end}'"
alias occonsole='edge $(oc whoami --show-console)'
alias changelog-not-required='((gh pr view --json labels | jq .labels | grep -q "kind/changelog-not-required") || (gh pr comment --body "/kind changelog-not-required" && until (gh pr view --json labels | jq .labels | grep "kind/changelog-not-required"); do sleep 1; done && gh pr close $(gh pr view --json number | jq .number) && gh pr reopen $(gh pr view --json number | jq .number)))'
alias dco='git rebase HEAD~$(gh pr view --json commits -q ".commits | length") --signoff'
alias dco-push='dco && git push --force'
alias gr='grep'
alias gcaf='git commit --amend --no-edit && git push --force'
alias gcan='git commit --amend --no-edit'
alias gca='git commit --amend'
alias gcas='git commit --amend --no-edit --signoff'
alias gcasf='git commit --amend --no-edit --signoff && git push --force'
alias gcu_master='git checkout upstream/master'
alias gcu_master_nb='git checkout upstream/master && git checkout -b'
alias gcu_main='git checkout upstream/main'
alias gcu_main_nb='git checkout upstream/main && git checkout -b'
alias grumaster='git rebase upstream/master'
alias grumain='git rebase upstream/main'
alias gfa='git fetch --all'
alias gfu='git fetch upstream'
alias gfum='git fetch upstream main'
alias gfumas='git fetch upstream master'
alias gfo='git fetch origin'
alias gfop='git fetch openshift'
alias gfopm='git fetch openshift master'
alias gfopk='git fetch openshift konveyor-dev'
alias gpf='git push  --force'
alias gpl='git pull'
alias gpo='git push'
alias current-branch='git branch --show-current'
alias ghcr_tag='echo ghcr.io/kaovilai/$(basename $PWD):$(current-branch)'
alias ghcr_notag='echo ghcr.io/kaovilai/$(basename $PWD)'
alias ghcr_tag-web='edge https://$(ghcr_tag)'
alias ocregistry_tag='echo $(oc-registry-route)/$(basename $PWD):$(current-branch)'
alias ocregistry_notag='echo $(oc-registry-route)/$(basename $PWD)'
alias dockerplatforms-amdarm='echo linux/amd64,linux/arm64'
alias dockerplatforms-amdarmibm='echo linux/amd64,linux/arm64,linux/s390x,linux/ppc64le'
alias recent-branches='git branch --sort=committerdate | tail -n 10'
alias rev-sha-short='git rev-parse --short HEAD'
alias code-lastcommitted='code $(git log --name-only --pretty=format: | head -n 1)'
alias gh-pr-view='gh pr view --web'
alias pr-view='gh pr view --web'
alias pr-comment='gh pr comment --body'
alias pr-label='gh pr label --add'
alias pr-unlabel='gh pr label --remove'
alias pr-close='gh pr close'
alias pr-reopen='gh pr reopen'
alias pr-merge='gh pr merge --merge-method squash'
alias pr-merge-rebase='gh pr merge --merge-method rebase'
alias pr-merge-squash='gh pr merge --merge-method squash'
alias pr-create='gh pr create'
alias pr-create-draft='gh pr create --draft'
alias pr-create-title='gh pr create --title'
alias pr-create-body='gh pr create --body'
alias pr-create-assignee='gh pr create --assignee'
alias pr-create-reviewer='gh pr create --reviewer'
alias pr-create-label='gh pr create --label'
alias pr-create-milestone='gh pr create --milestone'
alias pr-create-project='gh pr create --project'
alias pr-create-branch='gh pr create --branch'
alias pr-create-head='gh pr create --head'
alias pr-create-base='gh pr create --base'
alias pr-create-target='gh pr create --target'
alias pr-create-draft-title='gh pr create --draft --title'
alias pr-create-draft-body='gh pr create --draft --body'
alias pr-checkout='gh pr checkout'
alias pr-checkout-branch='gh pr checkout --branch'
alias pr-checkout-head='gh pr checkout --head'
alias pr-checkout-base='gh pr checkout --base'
alias pr-checkout-target='gh pr checkout --target'
alias pr-checkout-draft='gh pr checkout --draft'
alias pr-checkout-draft-title='gh pr checkout --draft --title'
alias pr-checkout-draft-body='gh pr checkout --draft --body'
alias pr-checkout-draft-branch='gh pr checkout --draft --branch'
alias pr-checkout-draft-head='gh pr checkout --draft --head'
alias pr-checkout-draft-base='gh pr checkout --draft --base'
alias pr-checkout-draft-target='gh pr checkout --draft --target'
alias pr-checkout-title='gh pr checkout --title'
alias pr-checkout-body='gh pr checkout --body'
alias pr-checkout-branch='gh pr checkout --branch'
alias pr-checkout-head='gh pr checkout --head'
alias pr-checkout-base='gh pr checkout --base'
alias pr-checkout-target='gh pr checkout --target'
alias pr-checkout-assignee='gh pr checkout --assignee'
alias pr-checkout-reviewer='gh pr checkout --reviewer'
alias pr-checkout-label='gh pr checkout --label'
alias pr-checkout-milestone='gh pr checkout --milestone'
alias pr-checkout-project='gh pr checkout --project'
alias pr-checkout-draft-assignee='gh pr checkout --draft --assignee'
alias pr-checkout-draft-reviewer='gh pr checkout --draft --reviewer'
alias pr-checkout-draft-label='gh pr checkout --draft --label'
alias pr-checkout-draft-milestone='gh pr checkout --draft --milestone'
alias pr-checkout-draft-project='gh pr checkout --draft --project'
alias pr-checkout-draft-branch='gh pr checkout --draft --branch'
alias pr-checkout-draft-head='gh pr checkout --draft --head'
alias pr-checkout-draft-base='gh pr checkout --draft --base'
alias pr-checkout-draft-target='gh pr checkout --draft --target'
alias ibmcloud-login='ibmcloud login --sso'
alias ibmcloud-vpcid='ibmcloud ks vpcs | grep -e "^tiger-vpc " | sed "s/  */ /g" | cut -d" " -f2'
alias ibmcloud-vpc-gen2zone='echo us-east-1'
alias ibmcloud-subnetid='ibmcloud ks subnets --provider vpc-gen2 --vpc-id $(ibmcloud-vpcid) --zone $(ibmcloud-vpc-gen2zone) --output json | jq --raw-output ".[0].id"'
alias ibmcloud-oc-latestversion='echo $(ibmcloud oc versions --show-version openshift --output json | jq ".openshift[-1].major").$(ibmcloud oc versions --show-version openshift --output json | jq ".openshift[-1].minor").$(ibmcloud oc versions --show-version openshift --output json | jq ".openshift[-1].patch")_openshift'
alias ibmcloud-cos-instance='echo \"$(ibmcloud resource service-instances --service-name cloud-object-storage --output json | grep tkaovila | cut -d":" -f2 | cut -d'"'"'"'"'"' -f2)\" | grep \" | sed "s/ /\\\ /g"'
alias ibmcloud-cos-instance-crn='ibmcloud resource service-instances --long --service-name cloud-object-storage --output json | jq --raw-output ".[] | select(.name==\"Cloud Object Storage-tkaovila-89\") | .id"'
alias ibmcloud-oc-cluster-create='ibmcloud oc cluster create vpc-gen2 --name tiger-2 --zone us-east-1 --vpc-id $(ibmcloud-vpcid) --subnet-id $(ibmcloud-subnetid) --flavor cx2.8x16 --workers 2 --cos-instance=$(ibmcloud-cos-instance-crn) --version $(ibmcloud-oc-latestversion)'
alias ibmcloud-oc-config='ibmcloud oc cluster config --admin -c tiger-2'
alias ollama-run='ollama run llama3.1:latest'
alias ollama-pull='ollama pull llama3-gradient:latest && llama3.1:latest'
alias openwebui-docker='docker run -d -p 3000:8080 --add-host=host.docker.internal:host-gateway -v open-webui:/app/backend/data --name open-webui --restart always ghcr.io/open-webui/open-webui:main'
# opencommit with signoff
alias ocos='oco && gcas'
alias ocosp='oco && gcas && gpf'
alias oco-signoff='oco && gcas'
alias oco-signoff-push-force='oco && gcas && gpf'
alias oco-confirm-signoff-push-force='oco -y && gcas && gpf'
alias crelease='code ~/git/release'
alias velero-goruninstall='velero-makecontainer-cluster-arch && go run cmd/velero/velero.go install --image=$(ghcr_notag):$(current-branch)-$(rev-sha-short)-$(cluster-arch-only) --provider aws --bucket $AWS_BUCKET --prefix velero --plugins velero/velero-plugin-for-aws:latest --secret-file $AWS_SECRET_FILE'
alias velero-goruninstall-node-agent='velero-makecontainer-cluster-arch && go run cmd/velero/velero.go install --use-node-agent --image=$(ghcr_notag):$(current-branch)-$(rev-sha-short)-$(cluster-arch-only) --provider aws --bucket $AWS_BUCKET --prefix velero --plugins velero/velero-plugin-for-aws:latest --secret-file $AWS_SECRET_FILE'
alias velero-makecontainer-cluster-arch='make container IMAGE=$(ghcr_notag) VERSION=$(current-branch)-$(rev-sha-short)-$(cluster-arch-only) && docker push $(ghcr_notag):$(current-branch)-$(rev-sha-short)-$(cluster-arch-only) && echo $(ghcr_notag):$(current-branch)-$(rev-sha-short)-$(cluster-arch-only)'
alias velero-makecontainer-velero-restore-helper-cluster-arch='make container IMAGE=$(ghcr_notag) VERSION=velero-restore-helper-$(current-branch)-$(rev-sha-short)-$(cluster-arch-only) && docker push $(ghcr_notag):velero-restore-helper-$(current-branch)-$(rev-sha-short)-$(cluster-arch-only) && echo $(ghcr_notag):velero-restore-helper-$(current-branch)-$(rev-sha-short)-$(cluster-arch-only)'
alias source-zshrc='source ~/.zshrc'
alias listening-ports='lsof -i -P | grep LISTEN'
alias go-install-kind='go install sigs.k8s.io/kind@latest'
export VELERO_NS=openshift-adp
alias kubectl-patch-velero-debug="kubectl patch -n \$VELERO_NS deployment.apps/velero --type=json -p=\"[{\"op\": \"add\", \"path\": \"/spec/template/spec/containers/0/args/-\", \"value\": \"--log-level=debug\"}]\""
