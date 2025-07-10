# Miscellaneous aliases
alias occonsole='edge $(oc whoami --show-console)'
alias eks-create='aws eks create-cluster --name tkaovila-eks --role-arn=$(aws iam get-role --role-name tkaovila-eks --output yaml | yq .Role.Arn) --resources-vpc-config subnetIds=$(aws ec2 describe-subnets --output yaml | yq -r ".Subnets[] | select(.Tags[] | .Value == \"tkaovila-eks-subnet\") | .SubnetId"),$(aws ec2 describe-subnets --output yaml | yq -r ".Subnets[] | select(.Tags[] | .Value == \"tkaovila-eks-subnet2\") | .SubnetId")'
alias ollama-run='ollama run llama3.2:3b'
alias ollama-run-deepseek='ollama run deepseek-r1:8b'
alias ollama-pull='ollama pull llama3-gradient:latest && llama3.2:3b'
alias source-zshrc='source ~/.zshrc'
alias listening-ports='lsof -i -P | grep LISTEN'
alias go-install-kind='go install sigs.k8s.io/kind@latest'
alias open-webui-serve='podman run -d -p 3000:8080 -v open-webui:/app/backend/data --name open-webui --restart always ghcr.io/open-webui/open-webui:main'
alias open-webui-update='podman rm -f open-webui && podman pull ghcr.io/open-webui/open-webui:main && open-webui-serve'
alias dsstore-rmall='find . -name ".DS_Store" -exec rm {} \;'
alias ln-claude-home="ln -s $XDG_CONFIG_HOME/claude/ $HOME/.claude" # workaround https://github.com/anthropics/claude-code/issues/2299#issuecomment-2993762516
alias computer-use-claud='docker run \
    -e ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY \
    -v $HOME/.anthropic:/home/computeruse/.anthropic \
    -p 5900:5900 \
    -p 8501:8501 \
    -p 6080:6080 \
    -p 8080:8080 \
    -it ghcr.io/anthropics/anthropic-quickstarts:computer-use-demo-latest'
alias activepieces-start='podman compose -f ~/OneDrive/activepieces/docker-compose.activepiecestailscale.yml up -d'
alias activepieces-stop='podman compose -f ~/OneDrive/activepieces/docker-compose.activepiecestailscale.yml down'
alias activepieces-restart='
    # First bring down the containers
    podman compose -f ~/OneDrive/activepieces/docker-compose.activepiecestailscale.yml down
    
    # Clean up Tailscale machines if API key and tailnet are configured
    if [ -n "$TAILSCALE_API_KEY" ] && [ -n "$TAILSCALE_TAILNET" ]; then
        echo "Looking for activepieces machines in Tailscale..."
        
        # List all machines and find ones with activepieces in the name
        DEVICES_JSON=$(curl -s -H "Authorization: Bearer $TAILSCALE_API_KEY" \
                                 "https://api.tailscale.com/api/v2/tailnet/$TAILSCALE_TAILNET/devices")
        
        # Extract machine IDs with activepieces in the name
        MACHINE_IDS=$(echo "$DEVICES_JSON" | jq -r \
                                 ".devices[] | select(.hostname | contains(\"activepieces\")) | .id")
        
        if [ -n "$MACHINE_IDS" ]; then
            echo "Found activepieces machines to clean up"
            for ID in $MACHINE_IDS; do
                echo "Deleting Tailscale machine: $ID"
                curl -s -X DELETE -H "Authorization: Bearer $TAILSCALE_API_KEY" \
                         "https://api.tailscale.com/api/v2/device/$ID"
            done
        else
            echo "No activepieces machines found in Tailscale"
        fi
    else
        echo "Tailscale API credentials not configured, skipping machine cleanup"
    fi
    
    # Finally, bring up the containers again
    podman compose -f ~/OneDrive/activepieces/docker-compose.activepiecestailscale.yml up -d
'
alias makelintv2oadp='git checkout linterv2 Makefile .golangci.yaml && make lint-fix && git restore --staged Makefile .golangci.yaml && git restore Makefile .golangci.yaml'
alias term='open -Fna Terminal .'

znap function vid2gif(){
    local input="$1"
    local output="$HOME/Downloads/$(basename "${input%.*}").gif"
    
    if [[ ! -f "$input" ]]; then
        echo "Error: Input file '$input' not found"
        return 1
    fi
    
    if ! command -v ffmpeg &> /dev/null; then
        echo "Error: ffmpeg is not installed"
        return 1
    fi
    
    echo "Converting $input to $output..."
    ffmpeg -i "$input" -vf "fps=10,scale=480:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" "$output"
    
    if [[ $? -eq 0 ]]; then
        echo "Conversion complete: $output"
    fi
}
