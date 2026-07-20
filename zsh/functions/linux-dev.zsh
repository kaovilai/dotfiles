# Linux development environment utilities
# For when you need native Linux and podman on Mac is being weird
# All functions can run concurrently in separate shell sessions.

# Color codes for output — conditional so we don't overwrite user-defined values
: ${RED:=$'\033[0;31m'}
: ${GREEN:=$'\033[0;32m'}
: ${YELLOW:=$'\033[1;33m'}
: ${BLUE:=$'\033[0;34m'}
: ${NC:=$'\033[0m'}

# 1) Quick local container - runs current directory in a Fedora container via podman
podman-linux() {
    if ! command -v podman &>/dev/null; then
        echo "❌ podman not found. Install it with: brew install podman" >&2
        return 1
    fi

    local image="${1:-fedora:latest}"
    local shell="bash"

    # Use zsh if available in image, otherwise bash
    echo "Starting Linux container ($image) with $PWD mounted..."
    podman run --rm -it \
        -w "$PWD" \
        -v "$PWD:$PWD:z" \
        -v "$HOME/.gitconfig:/root/.gitconfig:ro" \
        -v "$HOME/.ssh:/root/.ssh:ro" \
        --hostname linux-dev \
        "$image" \
        "$shell"
}

# 2) EC2-based native Linux dev environment
#    Launches an EC2 instance, rsyncs your repo, SSHes in.
#    Instance auto-terminates when you exit the shell.
ec2-linux() {
    local region="${AWS_REGION:-us-east-1}"
    local instance_type=""
    local architecture="arm64"
    local key_name=""
    local sync_dir="$PWD"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --region)       region="$2"; shift 2 ;;
            --type)         instance_type="$2"; shift 2 ;;
            --arch)         architecture="$2"; shift 2 ;;
            --key-name)     key_name="$2"; shift 2 ;;
            --dir)          sync_dir="$2"; shift 2 ;;
            --help)
                echo "Usage: ec2-linux [OPTIONS]"
                echo ""
                echo "Launches an EC2 instance, rsyncs your repo, SSHes in."
                echo "Instance is terminated when you exit the SSH session."
                echo ""
                echo "Options:"
                echo "  --region REGION    AWS region (default: \$AWS_REGION or us-east-1)"
                echo "  --type TYPE        EC2 instance type (default: t4g.medium for arm64, t3.medium for amd64)"
                echo "  --arch ARCH        Architecture: arm64 (default) or amd64"
                echo "  --key-name NAME    EC2 key pair name (default: auto-creates a temporary one)"
                echo "  --dir PATH         Directory to sync (default: \$PWD)"
                echo "  --help             Show this help"
                return 0
                ;;
            *) echo "${RED}ERROR${NC}: Unknown option: $1" >&2; return 1 ;;
        esac
    done

    # Validate tools
    local cmd
    for cmd in aws curl jq rsync ssh ssh-keygen; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "${RED}ERROR${NC}: $cmd is required but not found" >&2
            return 1
        fi
    done

    # Check AWS credentials
    if ! aws sts get-caller-identity &>/dev/null; then
        echo "${RED}ERROR${NC}: AWS credentials not configured or invalid" >&2
        return 1
    fi

    # Set default instance type based on architecture
    if [[ -z "$instance_type" ]]; then
        case "$architecture" in
            arm64|aarch64) instance_type="t4g.medium" ;;
            amd64|x86_64)  instance_type="t3.medium" ;;
            *)
                echo "${RED}ERROR${NC}: Unknown architecture: $architecture (use arm64 or amd64)" >&2
                return 1
                ;;
        esac
    fi

    local ami_arch
    case "$architecture" in
        arm64|aarch64) ami_arch="arm64" ;;
        amd64|x86_64)  ami_arch="x86_64" ;;
        *) echo "${RED}ERROR${NC}: Unknown architecture: $architecture" >&2; return 1 ;;
    esac

    # --- Temporary SSH key ---
    local tmp_key_created=false
    local key_path=""
    if [[ -z "$key_name" ]]; then
        key_name="ec2-linux-tmp-${EPOCHSECONDS}-${RANDOM}"
        key_path="${TMPDIR:-/tmp}/${key_name}.pem"
        echo "${BLUE}INFO${NC}: Creating temporary key pair: $key_name"
        if ! aws ec2 create-key-pair --region "$region" \
            --key-name "$key_name" \
            --query 'KeyMaterial' --output text > "$key_path" 2>/dev/null; then
            rm -f "$key_path"
            echo "${RED}ERROR${NC}: Failed to create key pair" >&2
            return 1
        fi
        chmod 600 "$key_path"
        tmp_key_created=true
    else
        # Look for key in common locations
        local candidate
        for candidate in "$HOME/.ssh/${key_name}.pem" "$HOME/.ssh/${key_name}" "$HOME/${key_name}.pem"; do
            if [[ -f "$candidate" ]]; then
                key_path="$candidate"
                break
            fi
        done
        if [[ -z "$key_path" ]]; then
            echo "${RED}ERROR${NC}: Cannot find private key for '$key_name'" >&2
            echo "Looked in ~/.ssh/${key_name}.pem, ~/.ssh/${key_name}, ~/${key_name}.pem" >&2
            return 1
        fi
    fi

    # --- Cleanup function ---
    _ec2_linux_cleanup() {
        trap - INT TERM EXIT
        echo ""
        echo "${BLUE}INFO${NC}: Cleaning up EC2 resources..."
        if [[ -n "$instance_id" ]]; then
            echo "${BLUE}INFO${NC}: Terminating instance $instance_id..."
            aws ec2 terminate-instances --region "$region" --instance-ids "$instance_id" &>/dev/null
            aws ec2 wait instance-terminated --region "$region" --instance-ids "$instance_id" 2>/dev/null
            echo "${GREEN}OK${NC}: Instance terminated"
        fi
        if [[ -n "$sg_id" ]]; then
            # Wait a moment for ENI detachment
            sleep 5
            aws ec2 delete-security-group --region "$region" --group-id "$sg_id" &>/dev/null
            echo "${GREEN}OK${NC}: Security group deleted"
        fi
        if [[ "$tmp_key_created" == true ]]; then
            aws ec2 delete-key-pair --region "$region" --key-name "$key_name" &>/dev/null
            rm -f "$key_path"
            echo "${GREEN}OK${NC}: Temporary key pair deleted"
        fi
    }
    trap 'unfunction _ec2_linux_cleanup 2>/dev/null' RETURN
    trap '_ec2_linux_cleanup; return 1' INT TERM

    # --- VPC / Subnet ---
    echo "${BLUE}INFO${NC}: Finding default VPC..."
    local vpc_id
    vpc_id=$(aws ec2 describe-vpcs --region "$region" \
        --filters "Name=is-default,Values=true" \
        --query "Vpcs[0].VpcId" --output text 2>/dev/null)
    if [[ "$vpc_id" == "None" || -z "$vpc_id" ]]; then
        echo "${RED}ERROR${NC}: No default VPC found in $region" >&2
        [[ "$tmp_key_created" == true ]] && aws ec2 delete-key-pair --region "$region" --key-name "$key_name" &>/dev/null && rm -f "$key_path"
        return 1
    fi

    local subnet_id
    subnet_id=$(aws ec2 describe-subnets --region "$region" \
        --filters "Name=vpc-id,Values=$vpc_id" "Name=map-public-ip-on-launch,Values=true" \
        --query "Subnets[0].SubnetId" --output text 2>/dev/null)
    if [[ "$subnet_id" == "None" || -z "$subnet_id" ]]; then
        echo "${RED}ERROR${NC}: No public subnet found in VPC $vpc_id" >&2
        [[ "$tmp_key_created" == true ]] && aws ec2 delete-key-pair --region "$region" --key-name "$key_name" &>/dev/null && rm -f "$key_path"
        return 1
    fi

    # --- Security group (SSH only from my IP) ---
    local sg_name="ec2-linux-dev-${EPOCHSECONDS}-${RANDOM}"
    local sg_id
    sg_id=$(aws ec2 create-security-group \
        --region "$region" \
        --group-name "$sg_name" \
        --description "Temporary SG for ec2-linux dev session" \
        --vpc-id "$vpc_id" \
        --query "GroupId" --output text 2>/dev/null)
    if [[ -z "$sg_id" ]]; then
        echo "${RED}ERROR${NC}: Failed to create security group" >&2
        [[ "$tmp_key_created" == true ]] && aws ec2 delete-key-pair --region "$region" --key-name "$key_name" &>/dev/null && rm -f "$key_path"
        return 1
    fi

    local my_ip
    my_ip=$(curl -sf --connect-timeout 5 ifconfig.me)
    local cidr="0.0.0.0/0"
    if [[ -n "$my_ip" ]]; then
        cidr="${my_ip}/32"
        echo "${BLUE}INFO${NC}: SSH restricted to your IP: $my_ip"
    else
        echo "${YELLOW}WARN${NC}: Could not detect IP, SSH open to 0.0.0.0/0" >&2
    fi
    aws ec2 authorize-security-group-ingress --region "$region" \
        --group-id "$sg_id" --protocol tcp --port 22 --cidr "$cidr" &>/dev/null

    # --- AMI ---
    echo "${BLUE}INFO${NC}: Finding latest Amazon Linux 2023 AMI ($ami_arch)..."
    local ami_id
    ami_id=$(aws ec2 describe-images --region "$region" --owners amazon \
        --filters "Name=name,Values=al2023-ami-2023*-${ami_arch}" "Name=state,Values=available" \
        --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text 2>/dev/null)
    if [[ -z "$ami_id" || "$ami_id" == "None" ]]; then
        echo "${RED}ERROR${NC}: Could not find AMI" >&2
        _ec2_linux_cleanup
        return 1
    fi
    echo "${BLUE}INFO${NC}: Using AMI: $ami_id"

    # --- Launch ---
    local instance_id
    echo "${BLUE}INFO${NC}: Launching $instance_type ($ami_arch)..."
    local instance_info
    if ! instance_info=$(aws ec2 run-instances \
        --region "$region" \
        --image-id "$ami_id" \
        --count 1 \
        --instance-type "$instance_type" \
        --key-name "$key_name" \
        --security-group-ids "$sg_id" \
        --subnet-id "$subnet_id" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=ec2-linux-dev},{Key=Purpose,Value=dev-session}]" \
        --instance-initiated-shutdown-behavior terminate \
        --output json 2>/dev/null); then
        echo "${RED}ERROR${NC}: Failed to launch instance" >&2
        _ec2_linux_cleanup
        return 1
    fi

    instance_id=$(jq -r '.Instances[0].InstanceId' <<< "$instance_info")
    echo "${BLUE}INFO${NC}: Launched instance: $instance_id"

    echo "${BLUE}INFO${NC}: Waiting for instance to be running..."
    aws ec2 wait instance-running --region "$region" --instance-ids "$instance_id"

    local public_ip
    public_ip=$(aws ec2 describe-instances --region "$region" \
        --instance-ids "$instance_id" \
        --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

    if [[ -z "$public_ip" || "$public_ip" == "None" ]]; then
        echo "${RED}ERROR${NC}: Instance has no public IP" >&2
        _ec2_linux_cleanup
        return 1
    fi
    echo "${GREEN}OK${NC}: Instance running at $public_ip"

    # --- Wait for SSH ---
    echo "${BLUE}INFO${NC}: Waiting for SSH to be ready..."
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"
    local max_wait=60
    local waited=0
    while ! ssh $=ssh_opts -i "$key_path" "ec2-user@${public_ip}" "true" 2>/dev/null; do
        waited=$((waited + 3))
        if [[ $waited -ge $max_wait ]]; then
            echo "${RED}ERROR${NC}: SSH did not become ready within ${max_wait}s" >&2
            _ec2_linux_cleanup
            return 1
        fi
        sleep 3
    done
    echo "${GREEN}OK${NC}: SSH is ready"

    # --- Install dev tools on the instance ---
    echo "${BLUE}INFO${NC}: Installing dev tools..."
    ssh $=ssh_opts -i "$key_path" "ec2-user@${public_ip}" \
        "sudo dnf install -y git golang make gcc jq rsync tar 2>&1 | tail -1" 2>/dev/null

    # --- Rsync repo ---
    local remote_dir="/home/ec2-user/${sync_dir:t}"
    echo "${BLUE}INFO${NC}: Syncing ${sync_dir:t} to instance..."
    if ! rsync -az --delete \
        --exclude '.git/objects' \
        --exclude 'vendor/' \
        --exclude 'node_modules/' \
        --exclude '_output/' \
        -e "ssh $ssh_opts -i $key_path" \
        "$sync_dir/" "ec2-user@${public_ip}:${remote_dir}/" 2>/dev/null; then
        echo "${YELLOW}WARN${NC}: rsync failed, continuing with SSH anyway" >&2
    else
        echo "${GREEN}OK${NC}: Repo synced to $remote_dir"
    fi

    # --- SSH in ---
    echo "${GREEN}=== Connected to EC2 Linux dev environment ===${NC}"
    echo "${GREEN}  Instance: $instance_id ($instance_type, $ami_arch)${NC}"
    echo "${GREEN}  Repo at:  $remote_dir${NC}"
    echo "${GREEN}  Instance will be TERMINATED when you exit.${NC}"
    echo ""

    ssh $=ssh_opts -i "$key_path" "ec2-user@${public_ip}" \
        -t "cd \"$remote_dir\" && exec bash --login"

    # --- Sync back changes ---
    echo "${BLUE}INFO${NC}: Syncing changes back from instance..."
    if rsync -az \
        --exclude '.git/objects' \
        --exclude 'vendor/' \
        --exclude 'node_modules/' \
        --exclude '_output/' \
        -e "ssh $ssh_opts -i $key_path" \
        "ec2-user@${public_ip}:${remote_dir}/" "$sync_dir/" 2>/dev/null; then
        echo "${GREEN}OK${NC}: Changes synced back to $sync_dir"
    else
        echo "${YELLOW}WARN${NC}: Failed to sync changes back" >&2
    fi

    # --- Cleanup on exit ---
    _ec2_linux_cleanup
    trap - INT TERM
}

# 3) Azure-based native Linux dev environment
#    Launches an Azure VM, rsyncs your repo, SSHes in.
#    VM and all resources auto-deleted when you exit the shell.
az-linux() {
    local location="${AZURE_LOCATION:-eastus}"
    local vm_size=""
    local architecture="arm64"
    local sync_dir="$PWD"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --location)     location="$2"; shift 2 ;;
            --size)         vm_size="$2"; shift 2 ;;
            --arch)         architecture="$2"; shift 2 ;;
            --dir)          sync_dir="$2"; shift 2 ;;
            --help)
                echo "Usage: az-linux [OPTIONS]"
                echo ""
                echo "Launches an Azure VM, rsyncs your repo, SSHes in."
                echo "VM and resource group are deleted when you exit the SSH session."
                echo ""
                echo "Options:"
                echo "  --location LOC     Azure location (default: \$AZURE_LOCATION or eastus)"
                echo "  --size SIZE        VM size (default: Standard_D2pds_v5 for arm64, Standard_D2ds_v5 for amd64)"
                echo "  --arch ARCH        Architecture: arm64 (default) or amd64"
                echo "  --dir PATH         Directory to sync (default: \$PWD)"
                echo "  --help             Show this help"
                return 0
                ;;
            *) echo "${RED}ERROR${NC}: Unknown option: $1" >&2; return 1 ;;
        esac
    done

    # Validate tools
    local cmd
    for cmd in az curl jq rsync ssh ssh-keygen; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "${RED}ERROR${NC}: $cmd is required but not found" >&2
            return 1
        fi
    done

    # Check Azure login
    if ! az account show &>/dev/null 2>&1; then
        echo "${RED}ERROR${NC}: Not logged into Azure. Run: az login" >&2
        return 1
    fi

    # Set default VM size based on architecture
    if [[ -z "$vm_size" ]]; then
        case "$architecture" in
            arm64|aarch64) vm_size="Standard_D2pds_v5" ;;
            amd64|x86_64)  vm_size="Standard_D2ds_v5" ;;
            *)
                echo "${RED}ERROR${NC}: Unknown architecture: $architecture (use arm64 or amd64)" >&2
                return 1
                ;;
        esac
    fi

    # Use a unique resource group so cleanup is just deleting the group
    local rg_name="az-linux-dev-${EPOCHSECONDS}-${RANDOM}"
    local vm_name="az-linux-dev"

    # --- Temporary SSH key ---
    local key_path="${TMPDIR:-/tmp}/${rg_name}"
    echo "${BLUE}INFO${NC}: Generating temporary SSH key..."
    if ! ssh-keygen -t ed25519 -f "$key_path" -N "" -q; then
        echo "${RED}ERROR${NC}: Failed to generate SSH key" >&2
        return 1
    fi

    # --- Cleanup function (deletes entire resource group) ---
    _az_linux_cleanup() {
        trap - INT TERM EXIT
        echo ""
        echo "${BLUE}INFO${NC}: Cleaning up Azure resources..."
        echo "${BLUE}INFO${NC}: Deleting resource group $rg_name (this takes a minute)..."
        az group delete --name "$rg_name" --yes --no-wait &>/dev/null
        echo "${GREEN}OK${NC}: Resource group deletion initiated"
        rm -f "$key_path" "${key_path}.pub"
        echo "${GREEN}OK${NC}: Temporary SSH key deleted"
    }
    trap 'unfunction _az_linux_cleanup 2>/dev/null' RETURN
    trap '_az_linux_cleanup; return 1' INT TERM

    # --- Create resource group ---
    echo "${BLUE}INFO${NC}: Creating resource group $rg_name in $location..."
    if ! az group create --name "$rg_name" --location "$location" --output none 2>/dev/null; then
        echo "${RED}ERROR${NC}: Failed to create resource group" >&2
        rm -f "$key_path" "${key_path}.pub"
        return 1
    fi

    # --- Determine image ---
    local image_urn
    case "$architecture" in
        arm64|aarch64) image_urn="Canonical:ubuntu-24_04-lts-arm64:server-arm64:latest" ;;
        amd64|x86_64)  image_urn="Canonical:ubuntu-24_04-lts:server:latest" ;;
        *) echo "${RED}ERROR${NC}: Unknown architecture: $architecture" >&2; return 1 ;;
    esac

    # --- Create VM ---
    echo "${BLUE}INFO${NC}: Creating VM $vm_name ($vm_size, $architecture)..."
    local vm_info
    if ! vm_info=$(az vm create \
        --resource-group "$rg_name" \
        --name "$vm_name" \
        --image "$image_urn" \
        --size "$vm_size" \
        --admin-username azureuser \
        --ssh-key-values "${key_path}.pub" \
        --public-ip-sku Standard \
        --output json 2>/dev/null); then
        echo "${RED}ERROR${NC}: Failed to create VM" >&2
        _az_linux_cleanup
        return 1
    fi

    local public_ip
    public_ip=$(jq -r '.publicIpAddress' <<< "$vm_info")
    if [[ -z "$public_ip" || "$public_ip" == "null" ]]; then
        echo "${RED}ERROR${NC}: VM has no public IP" >&2
        _az_linux_cleanup
        return 1
    fi
    echo "${GREEN}OK${NC}: VM running at $public_ip"

    # --- Wait for SSH ---
    echo "${BLUE}INFO${NC}: Waiting for SSH to be ready..."
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"
    local max_wait=90
    local waited=0
    while ! ssh $=ssh_opts -i "$key_path" "azureuser@${public_ip}" "true" 2>/dev/null; do
        waited=$((waited + 3))
        if [[ $waited -ge $max_wait ]]; then
            echo "${RED}ERROR${NC}: SSH did not become ready within ${max_wait}s" >&2
            _az_linux_cleanup
            return 1
        fi
        sleep 3
    done
    echo "${GREEN}OK${NC}: SSH is ready"

    # --- Install dev tools ---
    echo "${BLUE}INFO${NC}: Installing dev tools..."
    ssh $=ssh_opts -i "$key_path" "azureuser@${public_ip}" \
        "sudo apt-get update -qq && sudo apt-get install -y -qq git golang-go make gcc jq rsync 2>&1 | tail -1" 2>/dev/null

    # --- Rsync repo ---
    local remote_dir="/home/azureuser/${sync_dir:t}"
    echo "${BLUE}INFO${NC}: Syncing ${sync_dir:t} to VM..."
    if ! rsync -az --delete \
        --exclude '.git/objects' \
        --exclude 'vendor/' \
        --exclude 'node_modules/' \
        --exclude '_output/' \
        -e "ssh $ssh_opts -i $key_path" \
        "$sync_dir/" "azureuser@${public_ip}:${remote_dir}/" 2>/dev/null; then
        echo "${YELLOW}WARN${NC}: rsync failed, continuing with SSH anyway" >&2
    else
        echo "${GREEN}OK${NC}: Repo synced to $remote_dir"
    fi

    # --- SSH in ---
    echo "${GREEN}=== Connected to Azure Linux dev environment ===${NC}"
    echo "${GREEN}  VM:       $vm_name ($vm_size, $architecture)${NC}"
    echo "${GREEN}  Location: $location${NC}"
    echo "${GREEN}  Repo at:  $remote_dir${NC}"
    echo "${GREEN}  VM will be DELETED when you exit.${NC}"
    echo ""

    ssh $=ssh_opts -i "$key_path" "azureuser@${public_ip}" \
        -t "cd \"$remote_dir\" && exec bash --login"

    # --- Sync back changes ---
    echo "${BLUE}INFO${NC}: Syncing changes back from VM..."
    if rsync -az \
        --exclude '.git/objects' \
        --exclude 'vendor/' \
        --exclude 'node_modules/' \
        --exclude '_output/' \
        -e "ssh $ssh_opts -i $key_path" \
        "azureuser@${public_ip}:${remote_dir}/" "$sync_dir/" 2>/dev/null; then
        echo "${GREEN}OK${NC}: Changes synced back to $sync_dir"
    else
        echo "${YELLOW}WARN${NC}: Failed to sync changes back" >&2
    fi

    # --- Cleanup on exit ---
    _az_linux_cleanup
    trap - INT TERM
}

# 4) GCP-based native Linux dev environment
#    Launches a GCE instance, rsyncs your repo, SSHes in.
#    Instance auto-deleted when you exit the shell.
gcp-linux() {
    local zone="${CLOUDSDK_COMPUTE_ZONE:-us-central1-a}"
    local project="${GOOGLE_CLOUD_PROJECT:-}"
    local machine_type=""
    local architecture="arm64"
    local sync_dir="$PWD"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --zone)         zone="$2"; shift 2 ;;
            --project)      project="$2"; shift 2 ;;
            --type)         machine_type="$2"; shift 2 ;;
            --arch)         architecture="$2"; shift 2 ;;
            --dir)          sync_dir="$2"; shift 2 ;;
            --help)
                echo "Usage: gcp-linux [OPTIONS]"
                echo ""
                echo "Launches a GCE instance, rsyncs your repo, SSHes in."
                echo "Instance is deleted when you exit the SSH session."
                echo ""
                echo "Options:"
                echo "  --zone ZONE        GCP zone (default: \$CLOUDSDK_COMPUTE_ZONE or us-central1-a)"
                echo "  --project PROJECT  GCP project (default: \$GOOGLE_CLOUD_PROJECT or gcloud config)"
                echo "  --type TYPE        Machine type (default: t2a-standard-2 for arm64, e2-medium for amd64)"
                echo "  --arch ARCH        Architecture: arm64 (default) or amd64"
                echo "  --dir PATH         Directory to sync (default: \$PWD)"
                echo "  --help             Show this help"
                return 0
                ;;
            *) echo "${RED}ERROR${NC}: Unknown option: $1" >&2; return 1 ;;
        esac
    done

    # Validate tools
    local cmd
    for cmd in gcloud curl jq rsync ssh ssh-keygen; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "${RED}ERROR${NC}: $cmd is required but not found" >&2
            return 1
        fi
    done

    # Defer gcloud config lookup until after tool validation
    [[ -z "$project" ]] && project="$(gcloud config get-value project 2>/dev/null)"

    if [[ -z "$project" ]]; then
        echo "${RED}ERROR${NC}: No GCP project set. Use --project or set GOOGLE_CLOUD_PROJECT" >&2
        return 1
    fi

    # Check gcloud auth
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 | grep -q .; then
        echo "${RED}ERROR${NC}: Not authenticated with gcloud. Run: gcloud auth login" >&2
        return 1
    fi

    # Set default machine type based on architecture
    if [[ -z "$machine_type" ]]; then
        case "$architecture" in
            arm64|aarch64) machine_type="t2a-standard-2" ;;
            amd64|x86_64)  machine_type="e2-medium" ;;
            *)
                echo "${RED}ERROR${NC}: Unknown architecture: $architecture (use arm64 or amd64)" >&2
                return 1
                ;;
        esac
    fi

    local instance_name="gcp-linux-dev-${EPOCHSECONDS}-${RANDOM}"

    # --- Temporary SSH key ---
    local key_path="${TMPDIR:-/tmp}/${instance_name}"
    echo "${BLUE}INFO${NC}: Generating temporary SSH key..."
    if ! ssh-keygen -t ed25519 -f "$key_path" -N "" -q -C "gcp-linux-dev"; then
        echo "${RED}ERROR${NC}: Failed to generate SSH key" >&2
        return 1
    fi

    # Format SSH key for GCP metadata
    local ssh_user="dev"
    local pub_key_content
    pub_key_content=$(< "${key_path}.pub")
    local gcp_ssh_key="${ssh_user}:${pub_key_content}"

    # --- Determine image ---
    local image_family image_project
    case "$architecture" in
        arm64|aarch64)
            image_family="ubuntu-2404-lts-arm64"
            image_project="ubuntu-os-cloud"
            ;;
        amd64|x86_64)
            image_family="ubuntu-2404-lts-amd64"
            image_project="ubuntu-os-cloud"
            ;;
    esac

    # --- Cleanup function ---
    _gcp_linux_cleanup() {
        trap - INT TERM EXIT
        echo ""
        echo "${BLUE}INFO${NC}: Cleaning up GCP resources..."
        echo "${BLUE}INFO${NC}: Deleting instance $instance_name..."
        gcloud compute instances delete "$instance_name" \
            --zone "$zone" --project "$project" --quiet &>/dev/null
        echo "${GREEN}OK${NC}: Instance deleted"
        # Delete the firewall rule
        gcloud compute firewall-rules delete "${instance_name}-ssh" \
            --project "$project" --quiet &>/dev/null
        echo "${GREEN}OK${NC}: Firewall rule deleted"
        rm -f "$key_path" "${key_path}.pub"
        echo "${GREEN}OK${NC}: Temporary SSH key deleted"
    }
    trap 'unfunction _gcp_linux_cleanup 2>/dev/null' RETURN
    trap '_gcp_linux_cleanup; return 1' INT TERM

    # --- Create firewall rule for SSH from my IP ---
    local my_ip
    my_ip=$(curl -sf --connect-timeout 5 ifconfig.me)
    local cidr="0.0.0.0/0"
    if [[ -n "$my_ip" ]]; then
        cidr="${my_ip}/32"
        echo "${BLUE}INFO${NC}: SSH restricted to your IP: $my_ip"
    else
        echo "${YELLOW}WARN${NC}: Could not detect IP, SSH open to 0.0.0.0/0" >&2
    fi

    echo "${BLUE}INFO${NC}: Creating firewall rule..."
    gcloud compute firewall-rules create "${instance_name}-ssh" \
        --project "$project" \
        --allow tcp:22 \
        --source-ranges "$cidr" \
        --target-tags "${instance_name}" \
        --quiet &>/dev/null

    # --- Create instance ---
    echo "${BLUE}INFO${NC}: Creating instance $instance_name ($machine_type, $architecture)..."
    if ! gcloud compute instances create "$instance_name" \
        --project "$project" \
        --zone "$zone" \
        --machine-type "$machine_type" \
        --image-family "$image_family" \
        --image-project "$image_project" \
        --metadata "ssh-keys=${gcp_ssh_key}" \
        --tags "${instance_name}" \
        --quiet &>/dev/null; then
        echo "${RED}ERROR${NC}: Failed to create instance" >&2
        _gcp_linux_cleanup
        return 1
    fi

    # Get public IP
    local public_ip
    public_ip=$(gcloud compute instances describe "$instance_name" \
        --zone "$zone" --project "$project" \
        --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null)

    if [[ -z "$public_ip" ]]; then
        echo "${RED}ERROR${NC}: Instance has no public IP" >&2
        _gcp_linux_cleanup
        return 1
    fi
    echo "${GREEN}OK${NC}: Instance running at $public_ip"

    # --- Wait for SSH ---
    echo "${BLUE}INFO${NC}: Waiting for SSH to be ready..."
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"
    local max_wait=90
    local waited=0
    while ! ssh $=ssh_opts -i "$key_path" "${ssh_user}@${public_ip}" "true" 2>/dev/null; do
        waited=$((waited + 3))
        if [[ $waited -ge $max_wait ]]; then
            echo "${RED}ERROR${NC}: SSH did not become ready within ${max_wait}s" >&2
            _gcp_linux_cleanup
            return 1
        fi
        sleep 3
    done
    echo "${GREEN}OK${NC}: SSH is ready"

    # --- Install dev tools ---
    echo "${BLUE}INFO${NC}: Installing dev tools..."
    ssh $=ssh_opts -i "$key_path" "${ssh_user}@${public_ip}" \
        "sudo apt-get update -qq && sudo apt-get install -y -qq git golang-go make gcc jq rsync 2>&1 | tail -1" 2>/dev/null

    # --- Rsync repo ---
    local remote_dir="/home/${ssh_user}/${sync_dir:t}"
    echo "${BLUE}INFO${NC}: Syncing ${sync_dir:t} to instance..."
    if ! rsync -az --delete \
        --exclude '.git/objects' \
        --exclude 'vendor/' \
        --exclude 'node_modules/' \
        --exclude '_output/' \
        -e "ssh $ssh_opts -i $key_path" \
        "$sync_dir/" "${ssh_user}@${public_ip}:${remote_dir}/" 2>/dev/null; then
        echo "${YELLOW}WARN${NC}: rsync failed, continuing with SSH anyway" >&2
    else
        echo "${GREEN}OK${NC}: Repo synced to $remote_dir"
    fi

    # --- SSH in ---
    echo "${GREEN}=== Connected to GCP Linux dev environment ===${NC}"
    echo "${GREEN}  Instance: $instance_name ($machine_type, $architecture)${NC}"
    echo "${GREEN}  Zone:     $zone${NC}"
    echo "${GREEN}  Repo at:  $remote_dir${NC}"
    echo "${GREEN}  Instance will be DELETED when you exit.${NC}"
    echo ""

    ssh $=ssh_opts -i "$key_path" "${ssh_user}@${public_ip}" \
        -t "cd \"$remote_dir\" && exec bash --login"

    # --- Sync back changes ---
    echo "${BLUE}INFO${NC}: Syncing changes back from instance..."
    if rsync -az \
        --exclude '.git/objects' \
        --exclude 'vendor/' \
        --exclude 'node_modules/' \
        --exclude '_output/' \
        -e "ssh $ssh_opts -i $key_path" \
        "${ssh_user}@${public_ip}:${remote_dir}/" "$sync_dir/" 2>/dev/null; then
        echo "${GREEN}OK${NC}: Changes synced back to $sync_dir"
    else
        echo "${YELLOW}WARN${NC}: Failed to sync changes back" >&2
    fi

    # --- Cleanup on exit ---
    _gcp_linux_cleanup
    trap - INT TERM
}
