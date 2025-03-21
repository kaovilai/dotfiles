# Miscellaneous aliases
alias occonsole='edge $(oc whoami --show-console)'
alias eks-create='aws eks create-cluster --name tkaovila-eks --role-arn=$(aws iam get-role --role-name tkaovila-eks --output yaml | yq .Role.Arn) --resources-vpc-config subnetIds=$(aws ec2 describe-subnets --output yaml | yq -r ".Subnets[] | select(.Tags[] | .Value == \"tkaovila-eks-subnet\") | .SubnetId"),$(aws ec2 describe-subnets --output yaml | yq -r ".Subnets[] | select(.Tags[] | .Value == \"tkaovila-eks-subnet2\") | .SubnetId")'
alias ollama-run='ollama run llama3.1:latest'
alias ollama-run-deepseek='ollama run deepseek-r1:8b'
alias ollama-pull='ollama pull llama3-gradient:latest && llama3.1:latest'
alias openwebui-docker='docker run -d -p 3000:8080 --add-host=host.docker.internal:host-gateway -v open-webui:/app/backend/data --name open-webui --restart always ghcr.io/open-webui/open-webui:main'
alias source-zshrc='source ~/.zshrc'
alias listening-ports='lsof -i -P | grep LISTEN'
alias go-install-kind='go install sigs.k8s.io/kind@latest'
