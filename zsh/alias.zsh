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
alias gcaf='git commit --amend --no-edit && git push --force'
alias gcan='git commit --amend --no-edit'
alias terminal='open -a Terminal .'
alias recent-branches='git branch --sort=committerdate | tail -n 10'
alias code-lastcommitted='code $(git log --name-only --pretty=format: | head -n 1)'
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
alias pr-checkout-title='gh