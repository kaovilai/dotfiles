# non os specific aliases
alias gfa='git fetch --all'
alias gfu='git fetch upstream'
alias gfo='git fetch origin'
alias gfop='git fetch openshift'
alias ghcr_tag='echo ghcr.io/kaovilai/$(basename $PWD):$(git branch --show-current)'
alias db='docker build'
alias dbt='docker build --tag'
alias dbr='docker build --tag $(ghcr_tag)'
alias dbrp='docker build --tag $(ghcr_tag) --push'
alias db_amd64='docker build --platform linux/amd64'
alias db_amd64t='docker build --platform linux/amd64 --tag'
alias db_amd64r='docker build --platform linux/amd64 --tag $(ghcr_tag)'
alias db_amd64rp='docker build --platform linux/amd64 --tag $(ghcr_tag) --push'
alias db_multi='docker buildx build --platform linux/amd64,linux/arm64'
alias db_multit='docker buildx build --platform linux/amd64,linux/arm64 --tag'
alias db_multir='docker buildx build --platform linux/amd64,linux/arm64 --tag $(ghcr_tag)'
alias db_multip='docker buildx build --platform linux/amd64,linux/arm64 --tag $(ghcr_tag) --push'
alias colima-restart='colima stop; colima start --arch aarch64 --vm-type=vz --vz-rosetta --cpu 8 --disk 100 --memory 8'
alias coadp='code ~/oadp-operator/'
alias cvelero='code ~/git/velero/'
alias cvelero-aws='code ~/git/velero-plugin-for-aws/'
alias cvelero-gcp='code ~/git/velero-plugin-for-gcp/'
alias cvelero-azure='code ~/git/velero-plugin-for-microsoft-azure/'
alias cvelero-ocp='code ~/git/openshift-velero-plugin/'
alias occonsole='edge $(oc whoami --show-console)'
alias changelog-not-required='gh pr comment --body "/kind changelog-not-required" && until (gh pr view --json labels | jq .labels | grep 'kind/changelog-not-required'); do sleep 1; done &&  git commit --amend --no-edit && git push --force'