# AWS-specific MinIO deployment functions

znap function create-minio-aws() {
    local name=""
    local region="${AWS_REGION:-us-east-1}"
    local instance_type=""
    local architecture="arm64"
    local key_name=""
    local vpc_id=""
    local subnet_id=""
    local data_dir="/minio/data"
    local bucket_name="default-bucket"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name)
                name="$2"
                shift 2
                ;;
            --region)
                region="$2"
                shift 2
                ;;
            --instance-type)
                instance_type="$2"
                shift 2
                ;;
            --arch|--architecture)
                architecture="$2"
                shift 2
                ;;
            --key-name)
                key_name="$2"
                shift 2
                ;;
            --vpc-id)
                vpc_id="$2"
                shift 2
                ;;
            --subnet-id)
                subnet_id="$2"
                shift 2
                ;;
            --data-dir)
                data_dir="$2"
                shift 2
                ;;
            --bucket-name)
                bucket_name="$2"
                shift 2
                ;;
            --help)
                echo "Usage: create-minio-aws [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --name NAME              Name for the MinIO deployment (required)"
                echo "  --region REGION          AWS region (default: us-east-1)"
                echo "  --instance-type TYPE     EC2 instance type (default: architecture-specific)"
                echo "  --arch ARCH              Architecture: arm64 (default) or amd64"
                echo "  --key-name NAME          EC2 key pair name for SSH access"
                echo "  --vpc-id ID              VPC ID to deploy in (auto-detected if not provided)"
                echo "  --subnet-id ID           Subnet ID to deploy in (auto-detected if not provided)"
                echo "  --data-dir PATH          MinIO data directory (default: /minio/data)"
                echo "  --bucket-name NAME       Initial bucket name (default: default-bucket)"
                echo "  --help                   Show this help message"
                return 0
                ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                fi
                shift
                ;;
        esac
    done
    
    if [[ -z "$name" ]]; then
        echo -e "${RED}ERROR${NC}: MinIO deployment name is required"
        echo "Usage: create-minio-aws --name <deployment-name> [OPTIONS]"
        return 1
    fi
    
    # Set default instance type based on architecture
    if [[ -z "$instance_type" ]]; then
        case "$architecture" in
            "arm64"|"aarch64")
                instance_type="t4g.medium"
                ;;
            "amd64"|"x86_64")
                instance_type="t3.medium"
                ;;
            *)
                echo -e "${RED}ERROR${NC}: Unknown architecture: $architecture"
                echo "Supported architectures: arm64, amd64"
                return 1
                ;;
        esac
    fi
    
    # Check if deployment already exists
    if [[ -f "$MINIO_DEPLOYMENTS_DIR/${name}.json" ]]; then
        echo -e "${RED}ERROR${NC}: MinIO deployment '$name' already exists"
        echo "Use: delete-minio-aws --name $name # to delete existing deployment"
        return 1
    fi
    
    echo -e "${BLUE}INFO${NC}: Creating MinIO deployment '$name' in AWS region $region"
    
    # Check AWS CLI availability
    if ! command -v aws &> /dev/null; then
        echo -e "${RED}ERROR${NC}: AWS CLI is not installed or not in PATH"
        return 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        echo -e "${RED}ERROR${NC}: AWS credentials not configured or invalid"
        echo "Please run: aws configure"
        return 1
    fi
    
    # Auto-detect VPC and subnet if not provided
    if [[ -z "$vpc_id" ]]; then
        echo -e "${BLUE}INFO${NC}: Auto-detecting default VPC..."
        vpc_id=$(aws ec2 describe-vpcs --region "$region" --filters "Name=is-default,Values=true" --query "Vpcs[0].VpcId" --output text 2>/dev/null)
        if [[ "$vpc_id" == "None" || -z "$vpc_id" ]]; then
            echo -e "${RED}ERROR${NC}: No default VPC found in region $region"
            echo "Please specify --vpc-id"
            return 1
        fi
        echo -e "${BLUE}INFO${NC}: Using default VPC: $vpc_id"
    fi
    
    if [[ -z "$subnet_id" ]]; then
        echo -e "${BLUE}INFO${NC}: Auto-detecting public subnet..."
        subnet_id=$(aws ec2 describe-subnets --region "$region" --filters "Name=vpc-id,Values=$vpc_id" "Name=map-public-ip-on-launch,Values=true" --query "Subnets[0].SubnetId" --output text 2>/dev/null)
        if [[ "$subnet_id" == "None" || -z "$subnet_id" ]]; then
            echo -e "${RED}ERROR${NC}: No public subnet found in VPC $vpc_id"
            echo "Please specify --subnet-id"
            return 1
        fi
        echo -e "${BLUE}INFO${NC}: Using subnet: $subnet_id"
    fi
    
    # Create security group
    local sg_name="minio-${name}-sg"
    echo -e "${BLUE}INFO${NC}: Creating security group: $sg_name"
    local sg_id=$(aws ec2 create-security-group \
        --region "$region" \
        --group-name "$sg_name" \
        --description "Security group for MinIO deployment $name" \
        --vpc-id "$vpc_id" \
        --query "GroupId" --output text 2>/dev/null)
    
    if [[ $? -ne 0 || -z "$sg_id" ]]; then
        echo -e "${RED}ERROR${NC}: Failed to create security group"
        return 1
    fi
    
    echo -e "${BLUE}INFO${NC}: Created security group: $sg_id"
    
    # Add security group rules
    echo -e "${BLUE}INFO${NC}: Configuring security group rules..."
    
    # MinIO API port (9000)
    aws ec2 authorize-security-group-ingress \
        --region "$region" \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 9000 \
        --cidr 0.0.0.0/0 &>/dev/null
    
    # MinIO Console port (9001)
    aws ec2 authorize-security-group-ingress \
        --region "$region" \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 9001 \
        --cidr 0.0.0.0/0 &>/dev/null
    
    # SSH port (22) - restrict to your IP if possible
    local my_ip=$(curl -s ifconfig.me)
    if [[ -n "$my_ip" ]]; then
        aws ec2 authorize-security-group-ingress \
            --region "$region" \
            --group-id "$sg_id" \
            --protocol tcp \
            --port 22 \
            --cidr "${my_ip}/32" &>/dev/null
        echo -e "${BLUE}INFO${NC}: SSH access restricted to your IP: $my_ip"
    else
        aws ec2 authorize-security-group-ingress \
            --region "$region" \
            --group-id "$sg_id" \
            --protocol tcp \
            --port 22 \
            --cidr 0.0.0.0/0 &>/dev/null
        echo -e "${YELLOW}WARN${NC}: Could not detect your IP, SSH open to all (0.0.0.0/0)"
    fi
    
    # Get the latest Amazon Linux 2 AMI for the specified architecture
    local ami_arch
    case "$architecture" in
        "arm64"|"aarch64")
            ami_arch="arm64"
            ;;
        "amd64"|"x86_64")
            ami_arch="x86_64"
            ;;
    esac
    
    echo -e "${BLUE}INFO${NC}: Finding latest Amazon Linux 2 AMI for $ami_arch..."
    local ami_id=$(aws ec2 describe-images \
        --region "$region" \
        --owners amazon \
        --filters "Name=name,Values=amzn2-ami-hvm-*-${ami_arch}-gp2" \
        --query "sort_by(Images, &CreationDate)[-1].ImageId" \
        --output text 2>/dev/null)
    
    if [[ -z "$ami_id" || "$ami_id" == "None" ]]; then
        echo -e "${RED}ERROR${NC}: Failed to find Amazon Linux 2 AMI"
        # Cleanup security group
        aws ec2 delete-security-group --region "$region" --group-id "$sg_id" &>/dev/null
        return 1
    fi
    
    echo -e "${BLUE}INFO${NC}: Using AMI: $ami_id"
    
    # Generate MinIO root credentials
    local minio_root_user="minioadmin"
    local minio_root_password=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    
    # Create user data script for MinIO installation using Docker
    local user_data=$(cat << 'EOF'
#!/bin/bash
set -e

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/minio-setup.log
}

log "Starting MinIO setup..."

# Update and install Docker
log "Installing Docker..."
yum update -y
amazon-linux-extras install docker -y

# Start Docker
systemctl start docker
systemctl enable docker
usermod -a -G docker ec2-user

# Create directories for MinIO data and certificates
log "Creating directories..."
mkdir -p /minio/data
mkdir -p /minio/certs

# Get instance metadata
PUBLIC_DNS=$(curl -s http://169.254.169.254/latest/meta-data/public-hostname)
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
log "Public DNS: $PUBLIC_DNS"
log "Public IP: $PUBLIC_IP"

# Generate self-signed certificate
log "Generating self-signed certificate..."
cat > /tmp/minio-cert.conf << EOL
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
CN=$PUBLIC_DNS

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = $PUBLIC_DNS
DNS.2 = localhost
DNS.3 = minio
IP.1 = $PUBLIC_IP
IP.2 = 127.0.0.1
EOL

# Generate certificate and key
openssl req -new -x509 -days 365 -nodes \
    -keyout /minio/certs/private.key \
    -out /minio/certs/public.crt \
    -config /tmp/minio-cert.conf \
    -extensions v3_req

# Set proper permissions
chmod 644 /minio/certs/public.crt
chmod 600 /minio/certs/private.key

# Copy certificate for download
cp /minio/certs/public.crt /home/ec2-user/minio-cert.pem
chown ec2-user:ec2-user /home/ec2-user/minio-cert.pem

# Clean up
rm /tmp/minio-cert.conf

# Set MinIO credentials
MINIO_ROOT_USER="minioadmin"
MINIO_ROOT_PASSWORD="REPLACE_PASSWORD"

# Pull and run MinIO container
log "Starting MinIO container..."
docker pull minio/minio:latest

# Run MinIO with HTTPS enabled
docker run -d \
    --name minio \
    --restart unless-stopped \
    -p 9000:9000 \
    -p 9001:9001 \
    -v /minio/data:/data \
    -v /minio/certs:/root/.minio/certs \
    -e "MINIO_ROOT_USER=$MINIO_ROOT_USER" \
    -e "MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD" \
    minio/minio server /data --console-address ":9001"

# Wait for MinIO to be ready
log "Waiting for MinIO to start..."
for i in {1..30}; do
    if curl -k -s --connect-timeout 5 "https://localhost:9000/minio/health/ready" >/dev/null 2>&1; then
        log "MinIO is ready after $((i*5)) seconds"
        break
    fi
    if [ $i -eq 30 ]; then
        log "ERROR: MinIO failed to start after 150 seconds"
        docker logs minio >> /var/log/minio-setup.log 2>&1
        exit 1
    fi
    log "MinIO not ready yet, waiting... (attempt $i/30)"
    sleep 5
done

# Install MinIO client
log "Installing MinIO client..."
MC_ARCH=$(uname -m | sed 's/aarch64/arm64/' | sed 's/x86_64/amd64/')
wget -q https://dl.min.io/client/mc/release/linux-$MC_ARCH/mc
chmod +x mc
mv mc /usr/local/bin/

# Configure mc and create default bucket
log "Configuring MinIO client..."
export MC_HOST_local="https://$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD@localhost:9000"

# Create default bucket
BUCKET_NAME="REPLACE_BUCKET_NAME"
log "Creating bucket '$BUCKET_NAME'..."
for i in {1..5}; do
    if /usr/local/bin/mc --insecure mb local/$BUCKET_NAME 2>/dev/null; then
        log "Successfully created bucket '$BUCKET_NAME'"
        break
    elif /usr/local/bin/mc --insecure ls local/$BUCKET_NAME 2>/dev/null; then
        log "Bucket '$BUCKET_NAME' already exists"
        break
    fi
    if [ $i -eq 5 ]; then
        log "WARNING: Could not create bucket '$BUCKET_NAME' after 5 attempts"
    else
        log "Retrying bucket creation... (attempt $i/5)"
        sleep 5
    fi
done

log "MinIO setup completed successfully!"
log "Endpoint: https://$PUBLIC_DNS:9000"
log "Console: https://$PUBLIC_DNS:9001"
EOF
)
    
    # Replace variables in user data
    user_data=${user_data//REPLACE_PASSWORD/$minio_root_password}
    user_data=${user_data//REPLACE_BUCKET_NAME/$bucket_name}
    
    # Encode user data for EC2
    local encoded_user_data=$(echo "$user_data" | base64 -w 0)
    
    # Launch EC2 instance
    echo -e "${BLUE}INFO${NC}: Launching EC2 instance..."
    
    local launch_cmd="aws ec2 run-instances \
        --region '$region' \
        --image-id '$ami_id' \
        --count 1 \
        --instance-type '$instance_type' \
        --security-group-ids '$sg_id' \
        --subnet-id '$subnet_id' \
        --user-data '$encoded_user_data' \
        --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=minio-$name},{Key=Purpose,Value=MinIO-Storage}]'"
    
    if [[ -n "$key_name" ]]; then
        launch_cmd="$launch_cmd --key-name '$key_name'"
    fi
    
    local instance_info=$(eval "$launch_cmd" 2>/dev/null)
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}ERROR${NC}: Failed to launch EC2 instance"
        # Cleanup security group
        aws ec2 delete-security-group --region "$region" --group-id "$sg_id" &>/dev/null
        return 1
    fi
    
    local instance_id=$(echo "$instance_info" | jq -r '.Instances[0].InstanceId')
    echo -e "${BLUE}INFO${NC}: Launched instance: $instance_id"
    
    # Wait for instance to be running
    echo -e "${BLUE}INFO${NC}: Waiting for instance to be running..."
    aws ec2 wait instance-running --region "$region" --instance-ids "$instance_id"
    
    # Get public DNS and IP
    local instance_details=$(aws ec2 describe-instances \
        --region "$region" \
        --instance-ids "$instance_id" \
        --query "Reservations[0].Instances[0]" \
        --output json)
    
    local public_dns=$(echo "$instance_details" | jq -r '.PublicDnsName // ""')
    local public_ip=$(echo "$instance_details" | jq -r '.PublicIpAddress // ""')
    
    if [[ -z "$public_dns" || "$public_dns" == "null" ]]; then
        echo -e "${RED}ERROR${NC}: Instance does not have a public DNS name"
        echo "This usually means the subnet is not configured for public IPs"
        # Cleanup
        aws ec2 terminate-instances --region "$region" --instance-ids "$instance_id" &>/dev/null
        aws ec2 delete-security-group --region "$region" --group-id "$sg_id" &>/dev/null
        return 1
    fi
    
    local endpoint="https://${public_dns}:9000"
    
    echo -e "${BLUE}INFO${NC}: Instance is running"
    echo -e "  Public DNS: $public_dns"
    echo -e "  Public IP:  $public_ip"
    echo -e "  Endpoint:   $endpoint"
    
    # Download certificate from EC2 instance
    echo -e "${BLUE}INFO${NC}: Waiting for MinIO setup to complete..."
    echo -e "${YELLOW}NOTE${NC}: Initial setup takes 2-3 minutes for certificate generation and service startup"
    sleep 120  # Give more time for user-data to complete and generate certificates

    local cert_dir="$MINIO_DEPLOYMENTS_DIR/$name"
    local cert_file="$cert_dir/minio-cert.pem"
    mkdir -p "$cert_dir"

    # Download certificate from the EC2 instance
    echo -e "${BLUE}INFO${NC}: Attempting to download certificate from EC2 instance..."
    local max_attempts=15  # Increased from 10 to 15
    local attempt=1
    local cert_downloaded=false

    while [[ $attempt -le $max_attempts && "$cert_downloaded" == false ]]; do
        echo -e "${BLUE}INFO${NC}: Attempt $attempt/$max_attempts to download certificate..."

        # First check if HTTPS is responding (indicates certificates are ready)
        if curl -k -s --connect-timeout 10 --max-time 15 "https://${public_dns}:9000/minio/health/ready" &>/dev/null; then
            echo -e "${BLUE}INFO${NC}: HTTPS is responding, attempting to download certificate..."

            # Try to get the certificate file via SCP if key is available
            if [[ -n "$key_name" ]]; then
                local key_path=""
                # Check common key locations
                if [[ -f ~/.ssh/${key_name}.pem ]]; then
                    key_path="~/.ssh/${key_name}.pem"
                elif [[ -f ~/.ssh/${key_name} ]]; then
                    key_path="~/.ssh/${key_name}"
                elif [[ -f ${key_name} ]]; then
                    key_path="${key_name}"
                fi

                if [[ -n "$key_path" ]]; then
                    # Use SCP to download the certificate
                    echo -e "${BLUE}INFO${NC}: Using SSH key at $key_path to download certificate..."
                    scp -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "$key_path" "ec2-user@${public_dns}:/home/ec2-user/minio-cert.pem" "$cert_file" 2>/dev/null
                    if [[ $? -eq 0 && -s "$cert_file" ]]; then
                        cert_downloaded=true
                        echo -e "${GREEN}SUCCESS${NC}: Certificate downloaded via SCP"
                    else
                        echo -e "${YELLOW}WARN${NC}: SCP failed, trying alternative method..."
                    fi
                else
                    echo -e "${YELLOW}WARN${NC}: SSH key not found at expected locations"
                fi
            fi

            # If SCP failed or no key, extract certificate from HTTPS connection
            if [[ "$cert_downloaded" == false ]]; then
                echo -e "${BLUE}INFO${NC}: Extracting certificate from HTTPS connection..."
                # Use openssl with built-in timeout instead of external timeout command
                echo | openssl s_client -servername "$public_dns" -connect "${public_dns}:9000" -showcerts 2>/dev/null | \
                    openssl x509 -outform PEM > "$cert_file" 2>/dev/null
                if [[ $? -eq 0 && -s "$cert_file" ]]; then
                    # Verify the certificate is valid
                    if openssl x509 -in "$cert_file" -text -noout &>/dev/null; then
                        cert_downloaded=true
                        echo -e "${GREEN}SUCCESS${NC}: Certificate extracted from HTTPS connection"
                    else
                        echo -e "${YELLOW}WARN${NC}: Extracted file is not a valid certificate"
                        rm -f "$cert_file"
                    fi
                fi
            fi
        else
            # HTTPS not ready yet, check if HTTP is responding (service is starting)
            if curl -s --connect-timeout 5 --max-time 10 "http://${public_dns}:9000/minio/health/ready" &>/dev/null; then
                echo -e "${BLUE}INFO${NC}: MinIO is starting (HTTP responding), waiting for HTTPS..."
            else
                echo -e "${BLUE}INFO${NC}: MinIO service is still initializing..."
            fi
        fi

        if [[ "$cert_downloaded" == false ]]; then
            if [[ $attempt -lt $max_attempts ]]; then
                echo -e "${YELLOW}WARN${NC}: Certificate download attempt $attempt failed, retrying in 30 seconds..."
                sleep 30
            fi
        fi

        attempt=$((attempt + 1))
    done
    
    if [[ "$cert_downloaded" == false ]]; then
        echo -e "${YELLOW}WARN${NC}: Could not download certificate automatically"
        echo -e "${YELLOW}WARN${NC}: You may need to download it manually later"
        # Create a placeholder file
        touch "$cert_file"
    fi
    
    # Save deployment configuration
    local config_data=$(jq -n \
        --arg name "$name" \
        --arg provider "aws" \
        --arg region "$region" \
        --arg instance_id "$instance_id" \
        --arg instance_type "$instance_type" \
        --arg security_group_id "$sg_id" \
        --arg public_dns "$public_dns" \
        --arg public_ip "$public_ip" \
        --arg endpoint "$endpoint" \
        --arg access_key "$minio_root_user" \
        --arg secret_key "$minio_root_password" \
        --arg cert_file "$cert_file" \
        --arg bucket_name "$bucket_name" \
        --arg status "running" \
        --arg created_at "$(date -Iseconds)" \
        '{
            name: $name,
            provider: $provider,
            region: $region,
            instance_id: $instance_id,
            instance_type: $instance_type,
            security_group_id: $security_group_id,
            public_dns: $public_dns,
            public_ip: $public_ip,
            endpoint: $endpoint,
            access_key: $access_key,
            secret_key: $secret_key,
            cert_file: $cert_file,
            bucket_name: $bucket_name,
            status: $status,
            created_at: $created_at
        }')
    
    save_minio_config "$name" "$config_data"
    
    echo -e "${GREEN}SUCCESS${NC}: MinIO deployment '$name' created successfully!"
    echo -e ""
    echo -e "${BLUE}Connection Details:${NC}"
    echo -e "  Endpoint:    $endpoint"
    echo -e "  Access Key:  $minio_root_user"
    echo -e "  Secret Key:  $minio_root_password"
    echo -e "  Certificate: $cert_file"
    echo -e "  Initial Bucket: $bucket_name"
    echo -e ""
    echo -e "${BLUE}AWS CLI Configuration:${NC}"
    echo -e "  export AWS_ACCESS_KEY_ID=\"$minio_root_user\""
    echo -e "  export AWS_SECRET_ACCESS_KEY=\"$minio_root_password\""
    echo -e ""
    echo -e "${YELLOW}NOTE${NC}: MinIO is configured with HTTPS using self-signed certificates."
    echo -e "${YELLOW}NOTE${NC}: It may take 3-5 minutes for MinIO to be fully ready with HTTPS."
    echo -e "${YELLOW}NOTE${NC}: The certificate is self-signed and needs to be trusted for SSL verification."
    echo -e ""
    echo -e "${BLUE}Next steps:${NC}"
    if [[ "$cert_downloaded" == true ]]; then
        echo -e "  1. Trust the certificate: trust_certificate_in_system $cert_file"
        echo -e "  2. Test connection: test_minio_connection $name"
    else
        echo -e "  1. Wait a few minutes for setup to complete"
        echo -e "  2. Download certificate: download-minio-certificate $name"
        echo -e "  3. Test connection: aws s3 ls --endpoint-url $endpoint --no-verify-ssl"
    fi
    if [[ "$cert_downloaded" == true ]]; then
        echo -e "  3. Get connection info: get-minio-connection-info --name $name"
    else
        echo -e "  4. Get connection info: get-minio-connection-info --name $name"
    fi
    
    # Verify bucket creation if certificate was downloaded successfully
    if [[ "$cert_downloaded" == true ]]; then
        echo -e ""
        echo -e "${BLUE}INFO${NC}: Verifying bucket creation..."
        
        # Set credentials for AWS CLI
        export AWS_ACCESS_KEY_ID="$minio_root_user"
        export AWS_SECRET_ACCESS_KEY="$minio_root_password"
        
        # Wait a bit more for bucket creation script to complete
        sleep 30
        
        # Try to verify/create bucket
        if ensure_default_bucket "$name" "$bucket_name"; then
            echo -e "${GREEN}SUCCESS${NC}: Default bucket '$bucket_name' is ready!"
        else
            echo -e "${YELLOW}WARN${NC}: Default bucket verification failed, but you can create it manually later"
            echo -e "${YELLOW}HINT${NC}: Run 'ensure_default_bucket $name' once MinIO is fully started"
        fi
        
        # Clean up credentials from environment
        unset AWS_ACCESS_KEY_ID
        unset AWS_SECRET_ACCESS_KEY
    fi
    
    return 0
}

znap function delete-minio-aws() {
    local name=""
    local force=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name)
                name="$2"
                shift 2
                ;;
            --force)
                force=true
                shift
                ;;
            --help)
                echo "Usage: delete-minio-aws [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --name NAME      Name of the MinIO deployment to delete (required)"
                echo "  --force          Delete without confirmation"
                echo "  --help           Show this help message"
                return 0
                ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                fi
                shift
                ;;
        esac
    done
    
    if [[ -z "$name" ]]; then
        echo -e "${RED}ERROR${NC}: MinIO deployment name is required"
        echo "Usage: delete-minio-aws --name <deployment-name>"
        return 1
    fi
    
    local config=$(load_minio_config "$name")
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    local provider=$(echo "$config" | jq -r '.provider')
    if [[ "$provider" != "aws" ]]; then
        echo -e "${RED}ERROR${NC}: Deployment '$name' is not an AWS deployment (provider: $provider)"
        return 1
    fi
    
    local instance_id=$(echo "$config" | jq -r '.instance_id')
    local security_group_id=$(echo "$config" | jq -r '.security_group_id')
    local region=$(echo "$config" | jq -r '.region')
    local cert_file=$(echo "$config" | jq -r '.cert_file // ""')
    local endpoint=$(echo "$config" | jq -r '.endpoint')
    
    if [[ "$force" == false ]]; then
        echo -e "${YELLOW}WARNING${NC}: This will delete the MinIO deployment '$name' and all its data!"
        echo -e "  Instance ID: $instance_id"
        echo -e "  Region: $region"
        echo -e "  Endpoint: $endpoint"
        echo -e ""
        echo -n "Are you sure you want to continue? (yes/no): "
        read confirmation
        
        if [[ "$confirmation" != "yes" && "$confirmation" != "y" ]]; then
            echo -e "${BLUE}INFO${NC}: Deletion cancelled"
            return 0
        fi
    fi
    
    echo -e "${BLUE}INFO${NC}: Deleting MinIO deployment '$name'..."
    
    # Terminate EC2 instance
    echo -e "${BLUE}INFO${NC}: Terminating EC2 instance: $instance_id"
    aws ec2 terminate-instances --region "$region" --instance-ids "$instance_id" &>/dev/null
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}SUCCESS${NC}: Instance termination initiated"
        
        # Wait for instance to terminate (optional, can be slow)
        echo -e "${BLUE}INFO${NC}: Waiting for instance to terminate (this may take a few minutes)..."
        aws ec2 wait instance-terminated --region "$region" --instance-ids "$instance_id"
        
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}SUCCESS${NC}: Instance terminated successfully"
        else
            echo -e "${YELLOW}WARN${NC}: Instance termination may still be in progress"
        fi
    else
        echo -e "${YELLOW}WARN${NC}: Failed to terminate instance (it may already be terminated)"
    fi
    
    # Delete security group
    echo -e "${BLUE}INFO${NC}: Deleting security group: $security_group_id"
    # Wait a bit for the instance to fully terminate before deleting security group
    sleep 10
    
    aws ec2 delete-security-group --region "$region" --group-id "$security_group_id" &>/dev/null
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}SUCCESS${NC}: Security group deleted"
    else
        echo -e "${YELLOW}WARN${NC}: Failed to delete security group (it may still be in use)"
    fi
    
    # Remove certificate from system trust store
    if [[ -n "$cert_file" && "$cert_file" != "null" && -f "$cert_file" ]]; then
        echo -e "${BLUE}INFO${NC}: Removing certificate from system trust store"
        remove_certificate_from_system "$cert_file"
        
        # Remove certificate files
        local cert_dir=$(dirname "$cert_file")
        if [[ -d "$cert_dir" ]]; then
            rm -rf "$cert_dir"
            echo -e "${GREEN}SUCCESS${NC}: Certificate files removed"
        fi
    fi
    
    # Remove configuration
    remove_minio_config "$name"
    
    echo -e "${GREEN}SUCCESS${NC}: MinIO deployment '$name' deleted successfully!"
}

znap function configure-minio-cluster-access() {
    local minio_name=""
    local cluster_name=""
    local namespace="default"
    local secret_name="minio-credentials"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --minio)
                minio_name="$2"
                shift 2
                ;;
            --cluster)
                cluster_name="$2"
                shift 2
                ;;
            --namespace)
                namespace="$2"
                shift 2
                ;;
            --secret-name)
                secret_name="$2"
                shift 2
                ;;
            --help)
                echo "Usage: configure-minio-cluster-access [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --minio NAME         MinIO deployment name (required)"
                echo "  --cluster NAME       OpenShift cluster name (required)"
                echo "  --namespace NAME     Kubernetes namespace (default: default)"
                echo "  --secret-name NAME   Name of the secret to create (default: minio-credentials)"
                echo "  --help               Show this help message"
                return 0
                ;;
            *)
                if [[ -z "$minio_name" ]]; then
                    minio_name="$1"
                elif [[ -z "$cluster_name" ]]; then
                    cluster_name="$1"
                fi
                shift
                ;;
        esac
    done
    
    if [[ -z "$minio_name" || -z "$cluster_name" ]]; then
        echo -e "${RED}ERROR${NC}: Both MinIO deployment name and cluster name are required"
        echo "Usage: configure-minio-cluster-access --minio <minio-name> --cluster <cluster-name>"
        return 1
    fi
    
    # Load MinIO config
    local config=$(load_minio_config "$minio_name")
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    local endpoint=$(echo "$config" | jq -r '.endpoint')
    local access_key=$(echo "$config" | jq -r '.access_key')
    local secret_key=$(echo "$config" | jq -r '.secret_key')
    local cert_file=$(echo "$config" | jq -r '.cert_file // ""')
    
    # Switch to cluster
    echo -e "${BLUE}INFO${NC}: Switching to cluster: $cluster_name"
    if ! use-ocp-cluster "$cluster_name" &>/dev/null; then
        echo -e "${RED}ERROR${NC}: Failed to switch to cluster '$cluster_name'"
        return 1
    fi
    
    # Verify cluster connection
    if ! oc whoami &>/dev/null; then
        echo -e "${RED}ERROR${NC}: Not connected to OpenShift cluster"
        return 1
    fi
    
    echo -e "${BLUE}INFO${NC}: Connected to cluster: $(oc whoami --show-server)"
    
    # Create namespace if it doesn't exist
    if [[ "$namespace" != "default" ]]; then
        oc create namespace "$namespace" &>/dev/null || true
    fi
    
    # Add certificate to cluster's trusted CAs if certificate exists
    if [[ -n "$cert_file" && "$cert_file" != "null" && -f "$cert_file" ]]; then
        echo -e "${BLUE}INFO${NC}: Adding MinIO certificate to cluster's trusted CAs"
        
        local ca_config_map_name="minio-ca-${minio_name}"
        
        # Create ConfigMap with the certificate
        oc create configmap "$ca_config_map_name" \
            --from-file="ca-bundle.crt=$cert_file" \
            -n openshift-config &>/dev/null || \
        oc set data configmap/"$ca_config_map_name" \
            --from-file="ca-bundle.crt=$cert_file" \
            -n openshift-config
        
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}SUCCESS${NC}: Certificate added to cluster as ConfigMap: $ca_config_map_name"
            
            # Patch the cluster proxy configuration to trust the certificate
            # Note: This requires cluster-admin privileges
            local current_trusted_ca=$(oc get proxy/cluster -o jsonpath='{.spec.trustedCA.name}' 2>/dev/null)
            if [[ -z "$current_trusted_ca" ]]; then
                oc patch proxy/cluster --type merge -p "{\"spec\":{\"trustedCA\":{\"name\":\"$ca_config_map_name\"}}}" &>/dev/null
            else
                echo -e "${YELLOW}WARN${NC}: Cluster already has a trusted CA configured: $current_trusted_ca"
                echo -e "${YELLOW}WARN${NC}: You may need to manually merge the certificates"
            fi
        else
            echo -e "${YELLOW}WARN${NC}: Could not add certificate to cluster (may need cluster-admin privileges)"
        fi
    fi
    
    # Create secret with MinIO credentials
    echo -e "${BLUE}INFO${NC}: Creating secret '$secret_name' with MinIO credentials"
    oc create secret generic "$secret_name" \
        --from-literal="MINIO_ENDPOINT=$endpoint" \
        --from-literal="MINIO_ACCESS_KEY=$access_key" \
        --from-literal="MINIO_SECRET_KEY=$secret_key" \
        -n "$namespace" &>/dev/null || \
    oc set data secret/"$secret_name" \
        --from-literal="MINIO_ENDPOINT=$endpoint" \
        --from-literal="MINIO_ACCESS_KEY=$access_key" \
        --from-literal="MINIO_SECRET_KEY=$secret_key" \
        -n "$namespace"
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}SUCCESS${NC}: Secret '$secret_name' created/updated in namespace '$namespace'"
    else
        echo -e "${RED}ERROR${NC}: Failed to create secret"
        return 1
    fi
    
    # Test connectivity from cluster
    echo -e "${BLUE}INFO${NC}: Testing connectivity from cluster to MinIO..."
    
    local test_pod_name="minio-test-$(date +%s)"
    local test_manifest=$(cat << EOF
apiVersion: v1
kind: Pod
metadata:
  name: $test_pod_name
  namespace: $namespace
spec:
  restartPolicy: Never
  containers:
  - name: aws-cli
    image: amazon/aws-cli:latest
    command: ["/bin/sh"]
    args: ["-c", "aws s3 ls --endpoint-url \$MINIO_ENDPOINT && echo 'SUCCESS: MinIO connection test passed'"]
    env:
    - name: AWS_ACCESS_KEY_ID
      valueFrom:
        secretKeyRef:
          name: $secret_name
          key: MINIO_ACCESS_KEY
    - name: AWS_SECRET_ACCESS_KEY
      valueFrom:
        secretKeyRef:
          name: $secret_name
          key: MINIO_SECRET_KEY
    - name: MINIO_ENDPOINT
      valueFrom:
        secretKeyRef:
          name: $secret_name
          key: MINIO_ENDPOINT
EOF
)
    
    echo "$test_manifest" | oc apply -f -
    
    if [[ $? -eq 0 ]]; then
        echo -e "${BLUE}INFO${NC}: Test pod created. Waiting for completion..."
        
        # Wait for pod to complete (max 60 seconds)
        local timeout=60
        local elapsed=0
        while [[ $elapsed -lt $timeout ]]; do
            local status=$(oc get pod "$test_pod_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
            if [[ "$status" == "Succeeded" || "$status" == "Failed" ]]; then
                break
            fi
            sleep 5
            elapsed=$((elapsed + 5))
        done
        
        # Get pod logs
        local logs=$(oc logs "$test_pod_name" -n "$namespace" 2>/dev/null)
        if [[ "$logs" =~ "SUCCESS: MinIO connection test passed" ]]; then
            echo -e "${GREEN}SUCCESS${NC}: MinIO connectivity test passed!"
        else
            echo -e "${YELLOW}WARN${NC}: MinIO connectivity test may have failed"
            echo "Test pod logs:"
            echo "$logs"
        fi
        
        # Cleanup test pod
        oc delete pod "$test_pod_name" -n "$namespace" &>/dev/null
    else
        echo -e "${YELLOW}WARN${NC}: Could not create test pod"
    fi
    
    echo -e "${GREEN}SUCCESS${NC}: MinIO cluster access configured!"
    echo -e ""
    echo -e "${BLUE}Usage in pods:${NC}"
    echo -e "  Use secret '$secret_name' in namespace '$namespace'"
    echo -e "  Environment variables: MINIO_ENDPOINT, MINIO_ACCESS_KEY, MINIO_SECRET_KEY"
    echo -e ""
    echo -e "${BLUE}Example pod configuration:${NC}"
    echo -e "  env:"
    echo -e "  - name: AWS_ENDPOINT_URL"
    echo -e "    valueFrom:"
    echo -e "      secretKeyRef:"
    echo -e "        name: $secret_name"
    echo -e "        key: MINIO_ENDPOINT"
}
