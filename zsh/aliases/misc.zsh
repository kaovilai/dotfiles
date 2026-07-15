# Miscellaneous aliases
alias copy-devcontainer-from-dotfiles='cp -r ~/git/dotfiles/.devcontainer .'
alias copy-devcontainer-from-dotfiles-excluded='cp -r ~/git/dotfiles/.devcontainer . && echo ".devcontainer/" >> .git/info/exclude'
alias exclude-claude-md='mkdir -p .git/info && echo "CLAUDE.md" >> .git/info/exclude && echo "Added CLAUDE.md to .git/info/exclude"'
alias occonsole='comet $(oc whoami --show-console)'
alias eks-create='aws eks create-cluster --name tkaovila-eks --role-arn=$(aws iam get-role --role-name tkaovila-eks --output yaml | yq .Role.Arn) --resources-vpc-config subnetIds=$(aws ec2 describe-subnets --output yaml | yq -r ".Subnets[] | select(.Tags[] | .Value == \"tkaovila-eks-subnet\") | .SubnetId"),$(aws ec2 describe-subnets --output yaml | yq -r ".Subnets[] | select(.Tags[] | .Value == \"tkaovila-eks-subnet2\") | .SubnetId")'
alias ollama-run='ollama run llama3.2:3b'
alias ollama-run-deepseek='ollama run deepseek-r1:8b'
alias ollama-pull='ollama pull llama3-gradient:latest && ollama pull llama3.2:3b'
alias source-zshrc='source ~/.zshrc'
alias sz='source-zshrc'
alias listening-ports='lsof -i -P | grep LISTEN'
alias go-install-kind='go install sigs.k8s.io/kind@latest'
alias open-webui-serve='podman run -d -p 3000:8080 -v open-webui:/app/backend/data --name open-webui --restart always ghcr.io/open-webui/open-webui:main'
alias open-webui-update='podman rm -f open-webui && podman pull ghcr.io/open-webui/open-webui:main && open-webui-serve'
alias dsstore-rmall='find . -name ".DS_Store" -exec rm {} \;'
# workaround https://github.com/anthropics/claude-code/issues/2299#issuecomment-2993762516
function ln-claude-home() {
    local src="${XDG_CONFIG_HOME:-$HOME/.config}/claude/"
    local dst="$HOME/.claude"
    if [[ -L "$dst" ]]; then
        echo "Symlink $dst already exists (→ $(readlink "$dst"))"
        return 0
    fi
    if [[ -e "$dst" ]]; then
        echo "❌ $dst already exists and is not a symlink. Remove it first." >&2
        return 1
    fi
    ln -s "$src" "$dst" || { echo "❌ Failed to create symlink: $dst → $src" >&2; return 1; }
    echo "Created symlink: $dst → $src"
}
computer-use-claude() {
    if ! command -v docker &>/dev/null; then
        echo "❌ docker not found. Install Docker Desktop from https://www.docker.com/products/docker-desktop/" >&2
        return 1
    fi
    if [[ -n "${CLOUD_ML_REGION}" ]] && [[ -n "${ANTHROPIC_VERTEX_PROJECT_ID}" ]]; then
        echo "Using Google Vertex AI (project: ${ANTHROPIC_VERTEX_PROJECT_ID}, region: ${CLOUD_ML_REGION})"
        docker run \
            -e API_PROVIDER=vertex \
            -e CLOUD_ML_REGION="${CLOUD_ML_REGION}" \
            -e ANTHROPIC_VERTEX_PROJECT_ID="${ANTHROPIC_VERTEX_PROJECT_ID}" \
            -v "${HOME}/.config/gcloud/application_default_credentials.json:/home/computeruse/.config/gcloud/application_default_credentials.json:ro" \
            -v "${HOME}/.anthropic:/home/computeruse/.anthropic" \
            -p 5900:5900 \
            -p 8501:8501 \
            -p 6080:6080 \
            -p 8080:8080 \
            -it ghcr.io/anthropics/anthropic-quickstarts:computer-use-demo-latest
    else
        if [[ -z "${ANTHROPIC_API_KEY}" ]]; then
            echo "❌ ANTHROPIC_API_KEY is not set. Set it or configure CLOUD_ML_REGION and ANTHROPIC_VERTEX_PROJECT_ID to use Vertex AI." >&2
            return 1
        fi
        echo "Using Anthropic API (set CLOUD_ML_REGION and ANTHROPIC_VERTEX_PROJECT_ID to use Vertex AI)"
        docker run \
            -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" \
            -v "${HOME}/.anthropic:/home/computeruse/.anthropic" \
            -p 5900:5900 \
            -p 8501:8501 \
            -p 6080:6080 \
            -p 8080:8080 \
            -it ghcr.io/anthropics/anthropic-quickstarts:computer-use-demo-latest
    fi
}
alias activepieces-start='podman compose -f ~/OneDrive/activepieces/docker-compose.activepiecestailscale.yml up -d'
alias activepieces-stop='podman compose -f ~/OneDrive/activepieces/docker-compose.activepiecestailscale.yml down'
activepieces-restart() {
    if ! command -v podman &>/dev/null; then
        echo "❌ podman not found. Install it with: brew install podman" >&2
        return 1
    fi
    # First bring down the containers
    podman compose -f ~/OneDrive/activepieces/docker-compose.activepiecestailscale.yml down

    # Clean up Tailscale machines if API key and tailnet are configured
    if [[ -n "$TAILSCALE_API_KEY" ]] && [[ -n "$TAILSCALE_TAILNET" ]]; then
        if ! command -v curl &>/dev/null; then
            echo "❌ curl not found. Install it with: brew install curl" >&2
            return 1
        fi
        if ! command -v jq &>/dev/null; then
            echo "❌ jq not found. Install it with: brew install jq" >&2
            return 1
        fi
        echo "Looking for activepieces machines in Tailscale..."

        local devices_json
        devices_json=$(curl -s --fail --connect-timeout 10 -H "Authorization: Bearer $TAILSCALE_API_KEY" \
            "https://api.tailscale.com/api/v2/tailnet/$TAILSCALE_TAILNET/devices") || {
            echo "❌ Failed to query Tailscale devices API (check TAILSCALE_API_KEY and TAILSCALE_TAILNET)" >&2
            return 1
        }

        local machine_ids
        machine_ids=$(jq -r \
            ".devices[] | select(.hostname | contains(\"activepieces\")) | .id" <<< "$devices_json")

        if [[ -n "$machine_ids" ]]; then
            echo "Found activepieces machines to clean up"
            local id
            for id in "${(@f)machine_ids}"; do
                echo "Deleting Tailscale machine: $id"
                curl -s --fail --connect-timeout 10 -X DELETE -H "Authorization: Bearer $TAILSCALE_API_KEY" \
                    "https://api.tailscale.com/api/v2/device/$id" || \
                    echo "⚠️  Failed to delete Tailscale machine: $id" >&2
            done
        else
            echo "No activepieces machines found in Tailscale"
        fi
    else
        echo "Tailscale API credentials not configured, skipping machine cleanup"
    fi

    # Finally, bring up the containers again
    podman compose -f ~/OneDrive/activepieces/docker-compose.activepiecestailscale.yml up -d
}
alias makelintv2oadp='git checkout linterv2 Makefile .golangci.yaml && make lint-fix && git restore --staged Makefile .golangci.yaml && git restore Makefile .golangci.yaml'
alias term='open -Fna Terminal .'
alias termc='osascript -e "tell app \"Terminal\" to do script \"cd $PWD && claude\""'
alias audio-desk='SwitchAudioSource -t all -s "FiiO USB DAC K1" && SwitchAudioSource -t input -s "HD Pro Webcam C920"'
alias audio-poly='SwitchAudioSource -t all -s "Poly V4320 Series"'
alias restart-dock='killall Dock'
c() {
    if [[ "$OSTYPE" != darwin* ]]; then
        echo "Error: c is only supported on macOS" >&2
        return 1
    fi
    if ! command -v happy &>/dev/null && ! whence -p claude &>/dev/null; then
        echo "❌ Neither happy nor claude binary found. Install Claude Code CLI." >&2
        return 1
    fi
    if [[ -n "$1" ]]; then
        osascript -e "tell app \"Terminal\" to do script \"cd $HOME/experiments/ && claude \\\"$1\\\"\""
    else
        osascript -e "tell app \"Terminal\" to do script \"cd $HOME/experiments/ && claude\""
    fi
}
alias ce='cd ~/experiments/ && claude'
# cec = copilot edition of ce (raw claude via copilot-api gateway; see claude-copilot.zsh)
# NOTE: cec previously launched the podman claude-container — that is now cecon.
alias cec='cd ~/experiments/ && claude-copilot'
# Builds -e flags to pass the host's active Anthropic/copilot-api gateway
# config into a container. ANTHROPIC_BASE_URL's host is rewritten from
# localhost/127.0.0.1 to host.containers.internal since the container's
# network namespace can't resolve the host's own loopback back to the host.
typeset -ga _claude_container_anthropic_env_args
_claude_container_anthropic_env_build() {
    _claude_container_anthropic_env_args=()
    if [[ -n "$ANTHROPIC_BASE_URL" ]]; then
        local url="$ANTHROPIC_BASE_URL"
        url="${url/localhost/host.containers.internal}"
        url="${url/127.0.0.1/host.containers.internal}"
        _claude_container_anthropic_env_args+=(-e "ANTHROPIC_BASE_URL=${url}")
    fi
    [[ -n "$ANTHROPIC_AUTH_TOKEN" ]] && _claude_container_anthropic_env_args+=(-e ANTHROPIC_AUTH_TOKEN)
    [[ -n "$ANTHROPIC_MODEL" ]] && _claude_container_anthropic_env_args+=(-e ANTHROPIC_MODEL)
    [[ -n "$ANTHROPIC_DEFAULT_OPUS_MODEL" ]] && _claude_container_anthropic_env_args+=(-e ANTHROPIC_DEFAULT_OPUS_MODEL)
    [[ -n "$ANTHROPIC_DEFAULT_SONNET_MODEL" ]] && _claude_container_anthropic_env_args+=(-e ANTHROPIC_DEFAULT_SONNET_MODEL)
    [[ -n "$ANTHROPIC_DEFAULT_HAIKU_MODEL" ]] && _claude_container_anthropic_env_args+=(-e ANTHROPIC_DEFAULT_HAIKU_MODEL)
}

cecon() {
    _claude_container_anthropic_env_build
    podman run --rm -it -v ~/experiments:/workspace:Z -v "$HOME/.config/claude-container:/claude" -v "$HOME/.config/gcloud:/home/node/.config/gcloud:ro" -e CLAUDE_CONFIG_DIR=/claude -e CLAUDE_CODE_USE_VERTEX -e ANTHROPIC_VERTEX_PROJECT_ID -e CLOUD_ML_REGION -e ANTHROPIC_VERTEX_BASE_URL "${_claude_container_anthropic_env_args[@]}" ghcr.io/kaovilai/claude-container:latest claude --enable-auto-mode --permission-mode auto
}
alias ced='cd ~/experiments/ && claude --dangerously-skip-permissions'
cedcon() {
    _claude_container_anthropic_env_build
    podman run --rm -it -v ~/experiments:/workspace:Z -v "$HOME/.config/claude-container:/claude" -v "$HOME/.config/gcloud:/home/node/.config/gcloud:ro" -e CLAUDE_CONFIG_DIR=/claude -e CLAUDE_CODE_USE_VERTEX -e ANTHROPIC_VERTEX_PROJECT_ID -e CLOUD_ML_REGION -e ANTHROPIC_VERTEX_BASE_URL "${_claude_container_anthropic_env_args[@]}" ghcr.io/kaovilai/claude-container:latest claude --enable-auto-mode --permission-mode auto --dangerously-skip-permissions
}
alias cedc='cedcon'   # backwards-compat after cedc→cedcon rename
claude-container() {
    _claude_container_anthropic_env_build
    podman run --rm -it -v "$PWD:/workspace:Z" -v "$HOME/.config/claude-container:/claude" -v "$HOME/.config/gcloud:/home/node/.config/gcloud:ro" -e CLAUDE_CONFIG_DIR=/claude -e CLAUDE_CODE_USE_VERTEX -e ANTHROPIC_VERTEX_PROJECT_ID -e CLOUD_ML_REGION -e ANTHROPIC_VERTEX_BASE_URL "${_claude_container_anthropic_env_args[@]}" ghcr.io/kaovilai/claude-container:latest claude --enable-auto-mode --permission-mode auto
}
claude-dangerously-container() {
    _claude_container_anthropic_env_build
    podman run --rm -it -v "$PWD:/workspace:Z" -v "$HOME/.config/claude-container:/claude" -v "$HOME/.config/gcloud:/home/node/.config/gcloud:ro" -e CLAUDE_CONFIG_DIR=/claude -e CLAUDE_CODE_USE_VERTEX -e ANTHROPIC_VERTEX_PROJECT_ID -e CLOUD_ML_REGION -e ANTHROPIC_VERTEX_BASE_URL "${_claude_container_anthropic_env_args[@]}" ghcr.io/kaovilai/claude-container:latest claude --enable-auto-mode --permission-mode auto --dangerously-skip-permissions
}
alias gcloud-token='gcloud auth print-access-token'
alias claude-agents='~/.local/bin/claude agents'
alias claude-install='~/.local/bin/claude install'
alias claude-local='~/.local/bin/claude'
# claude is a mode-dispatching function defined in claude-copilot.zsh (sourced
# after this file); switch backends with claude-mode [copilot|default].
alias claude-dangerously='claude --dangerously-skip-permissions'
alias claude-sonnet='claude --model sonnet'
alias claude-opus='claude --model opus'
alias claude-worktree='claude --worktree'
alias cwt='claude-worktree'
claude-review() {
    if [[ "$OSTYPE" != darwin* ]]; then
        echo "Error: claude-review is only supported on macOS" >&2
        return 1
    fi
    if [[ -z "$1" ]]; then
        echo "Usage: claude-review <topic>" >&2
        return 1
    fi
    if ! command -v happy &>/dev/null && ! whence -p claude &>/dev/null; then
        echo "❌ Neither happy nor claude binary found. Install Claude Code CLI." >&2
        return 1
    fi
    osascript -e "tell app \"Terminal\" to do script \"cd $HOME/experiments/ && claude \\\"/review $1\\\"\""
}
alias cr='claude-review'
gemini-review() {
    if [[ "$OSTYPE" != darwin* ]]; then
        echo "Error: gemini-review is only supported on macOS" >&2
        return 1
    fi
    if [[ -z "$1" ]]; then
        echo "Usage: gemini-review <topic>" >&2
        return 1
    fi
    if ! command -v gemini &>/dev/null; then
        echo "❌ gemini not found. Install Google Gemini CLI." >&2
        return 1
    fi
    osascript -e "tell app \"Terminal\" to do script \"cd $HOME/experiments/ && gemini -p \\\"/review $1\\\"\""
}
alias gr='gemini-review'
alias tailscale="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
# Find and kill orphaned zsh processes that are busy-spinning CPU.
# Detects: PPID=1 (parent died) + no TTY (lost terminal) + state R (busy-loop on closed fd)
# Relies on macOS-specific ps(1) output: "??" no-TTY marker and -o lstart.
kill-orphan-zsh(){
    if [[ "$OSTYPE" != darwin* ]]; then
        echo "Error: kill-orphan-zsh is only supported on macOS" >&2
        return 1
    fi
    local pids
    local pids_csv
    pids_csv=$(ps -eo pid,ppid,stat,tty,command | awk '$2 == 1 && $3 ~ /^R/ && $4 == "??" && /\/bin\/zsh -il/ {printf sep $1; sep=","}')
    if [[ -z "$pids_csv" ]]; then
        echo "No orphaned busy-spinning zsh processes found."
        return 0
    fi
    pids=${pids_csv//,/ }
    echo "Orphaned busy-spinning zsh processes (PPID=1, no TTY, state R):"
    ps -o pid,ppid,%cpu,stat,tty,lstart,command -p ${=pids} 2>/dev/null
    echo ""
    if [[ "$1" == "--dry-run" ]]; then
        echo "Dry run — no processes killed."
    elif [[ "$1" == "-f" ]]; then
        echo "Killing orphaned zsh processes..."
        kill ${=pids} 2>/dev/null || kill -9 ${=pids} 2>/dev/null
        echo "Done."
    else
        echo "Run 'kill-orphan-zsh -f' to kill, or '--dry-run' to preview only."
    fi
}
function ocr(){
    local input="$1"
    if [[ -z "$input" ]]; then
        echo "Usage: ocr <input-pdf>"
        return 1
    fi
    if [[ ! -f "$input" ]]; then
        echo "Error: Input file '$input' not found" >&2
        return 1
    fi
    if ! command -v ocrmypdf &> /dev/null; then
        echo "Error: ocrmypdf is not installed. Install with: brew install ocrmypdf" >&2
        return 1
    fi
    local ext="${input##*.}"
    local base="${input%.*}"
    local output="${base}-ocr.${ext}"
    ocrmypdf --force-ocr "$input" "$output" && { [[ "$OSTYPE" == darwin* ]] && open "$output" || echo "Output saved to: $output"; }
}
function vid2gif(){
    local input="$1"
    if [[ -z "$input" ]]; then
        echo "Usage: vid2gif <input-video>"
        return 1
    fi
    local output="$HOME/Downloads/${input:t:r}.gif"
    
    if [[ ! -f "$input" ]]; then
        echo "Error: Input file '$input' not found" >&2
        return 1
    fi
    
    if ! command -v ffmpeg &> /dev/null; then
        echo "Error: ffmpeg is not installed" >&2
        return 1
    fi
    
    echo "Converting $input to $output..."
    if ffmpeg -i "$input" -vf "fps=10,scale=480:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" "$output"; then
        echo "Conversion complete: $output"
    else
        echo "Error: Conversion failed" >&2
        return 1
    fi
}
