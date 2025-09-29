# Common MinIO management functions
# Used by provider-specific MinIO deployment functions

# Directory for storing MinIO deployment configurations
export MINIO_DEPLOYMENTS_DIR="$HOME/.minio-deployments"

# Colors for output (matching your existing patterns)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

znap function create_minio_config_dir() {
    if [[ ! -d "$MINIO_DEPLOYMENTS_DIR" ]]; then
        echo -e "${BLUE}INFO${NC}: Creating MinIO deployments directory: $MINIO_DEPLOYMENTS_DIR"
        mkdir -p "$MINIO_DEPLOYMENTS_DIR"
    fi
}

znap function save_minio_config() {
    local name=$1
    local config_data=$2
    
    create_minio_config_dir
    local config_file="$MINIO_DEPLOYMENTS_DIR/${name}.json"
    
    echo "$config_data" > "$config_file"
    echo -e "${GREEN}INFO${NC}: Configuration saved to $config_file"
}

znap function load_minio_config() {
    local name=$1
    local config_file="$MINIO_DEPLOYMENTS_DIR/${name}.json"
    
    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}ERROR${NC}: No configuration found for MinIO deployment '$name'" >&2
        echo "Available deployments:" >&2
        list-minio-deployments >&2
        return 1
    fi
    
    cat "$config_file"
}

znap function list-minio-deployments() {
    echo -e "${BLUE}INFO${NC}: MinIO deployments:"
    
    if [[ ! -d "$MINIO_DEPLOYMENTS_DIR" ]] || [[ -z "$(ls -A "$MINIO_DEPLOYMENTS_DIR" 2>/dev/null)" ]]; then
        echo "  No deployments found"
        return 0
    fi
    
    for config_file in "$MINIO_DEPLOYMENTS_DIR"/*.json; do
        if [[ -f "$config_file" ]]; then
            local name=$(basename "$config_file" .json)
            local config=$(cat "$config_file")
            local provider=$(echo "$config" | jq -r '.provider // "unknown"')
            local endpoint=$(echo "$config" | jq -r '.endpoint // "unknown"')
            local deployment_status=$(echo "$config" | jq -r '.status // "unknown"')
            
            echo -e "  ${GREEN}$name${NC} [$provider] - $endpoint (${deployment_status})"
        fi
    done
}

znap function get-minio-connection-info() {
    local name=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name)
                name="$2"
                shift 2
                ;;
            *)
                name="$1"
                shift
                ;;
        esac
    done
    
    if [[ -z "$name" ]]; then
        echo -e "${RED}ERROR${NC}: MinIO deployment name is required"
        echo "Usage: get-minio-connection-info --name <deployment-name>"
        return 1
    fi
    
    if ! config=$(load_minio_config "$name"); then
        return 1
    fi
    
    local endpoint=$(echo "$config" | jq -r '.endpoint')
    local access_key=$(echo "$config" | jq -r '.access_key')
    local secret_key=$(echo "$config" | jq -r '.secret_key')
    local cert_file=$(echo "$config" | jq -r '.cert_file // ""')
    local provider=$(echo "$config" | jq -r '.provider')
    
    echo -e "${BLUE}Connection Information for MinIO deployment '${name}'${NC}:"
    echo -e "  Provider:    ${provider}"
    echo -e "  Endpoint:    ${endpoint}"
    echo -e "  Access Key:  ${access_key}"
    echo -e "  Secret Key:  ${secret_key}"
    if [[ -n "$cert_file" && "$cert_file" != "null" ]]; then
        echo -e "  Certificate: ${cert_file}"
    fi
    
    echo -e "\n${BLUE}AWS CLI Configuration:${NC}"
    echo "export AWS_ACCESS_KEY_ID='$access_key'"
    echo "export AWS_SECRET_ACCESS_KEY='$secret_key'"
    echo "export AWS_ENDPOINT_URL='$endpoint'"
    if [[ -n "$cert_file" && "$cert_file" != "null" && -f "$cert_file" ]]; then
        echo "export AWS_CA_BUNDLE='$cert_file'"
    fi
    
    echo -e "\n${BLUE}MinIO Client (mc) Configuration:${NC}"
    echo "mc config host add $name $endpoint $access_key $secret_key"
    if [[ -n "$cert_file" && "$cert_file" != "null" && -f "$cert_file" ]]; then
        echo "# Note: mc will automatically use system trust store for certificate validation"
    fi
    
    echo -e "\n${BLUE}Test Commands:${NC}"
    echo "# List buckets:"
    echo "aws s3 ls --endpoint-url $endpoint"
    if [[ -n "$cert_file" && "$cert_file" != "null" ]]; then
        echo "# Or with custom certificate:"
        echo "aws s3 ls --endpoint-url $endpoint --ca-bundle $cert_file"
    fi
}

znap function generate_self_signed_cert() {
    local hostname=$1
    local cert_dir=$2
    local cert_name=${3:-"minio-cert"}
    
    if [[ -z "$hostname" || -z "$cert_dir" ]]; then
        echo -e "${RED}ERROR${NC}: hostname and cert_dir are required"
        return 1
    fi
    
    mkdir -p "$cert_dir"
    
    local key_file="$cert_dir/${cert_name}.key"
    local cert_file="$cert_dir/${cert_name}.pem"
    local config_file="$cert_dir/${cert_name}.conf"
    
    # Create OpenSSL config for SAN
    cat > "$config_file" << EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
CN=$hostname

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = $hostname
DNS.2 = localhost
IP.1 = 127.0.0.1
EOF
    
    # If hostname looks like an EC2 public DNS, extract the IP
    if [[ "$hostname" =~ ^ec2-[0-9-]+\..*\.compute\.amazonaws\.com$ ]]; then
        local ip=$(echo "$hostname" | sed 's/ec2-\([0-9]\+\)-\([0-9]\+\)-\([0-9]\+\)-\([0-9]\+\)\..*/\1.\2.\3.\4/')
        echo "IP.2 = $ip" >> "$config_file"
    fi
    
    echo -e "${BLUE}INFO${NC}: Generating self-signed certificate for $hostname" >&2
    openssl req -new -x509 -days 365 -nodes \
        -keyout "$key_file" \
        -out "$cert_file" \
        -config "$config_file" \
        -extensions v3_req
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}SUCCESS${NC}: Certificate generated:" >&2
        echo "  Key:  $key_file" >&2
        echo "  Cert: $cert_file" >&2
        
        # Clean up config file
        rm "$config_file"
        
        echo "$cert_file"
        return 0
    else
        echo -e "${RED}ERROR${NC}: Failed to generate certificate" >&2
        return 1
    fi
}

znap function trust_certificate_in_system() {
    local cert_file=$1
    
    if [[ -z "$cert_file" || ! -f "$cert_file" ]]; then
        echo -e "${RED}ERROR${NC}: Certificate file not found: $cert_file"
        return 1
    fi
    
    if [[ "$(uname -s)" == "Darwin" ]]; then
        echo -e "${BLUE}INFO${NC}: Adding certificate to macOS system trust store"
        sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$cert_file"
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}SUCCESS${NC}: Certificate added to macOS trust store"
        else
            echo -e "${RED}ERROR${NC}: Failed to add certificate to macOS trust store"
            return 1
        fi
    else
        echo -e "${BLUE}INFO${NC}: Adding certificate to Linux system trust store"
        local cert_name=$(basename "$cert_file" .pem)
        sudo cp "$cert_file" "/usr/local/share/ca-certificates/${cert_name}.crt"
        sudo update-ca-certificates
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}SUCCESS${NC}: Certificate added to Linux trust store"
        else
            echo -e "${RED}ERROR${NC}: Failed to add certificate to Linux trust store"
            return 1
        fi
    fi
}

znap function remove_certificate_from_system() {
    local cert_file=$1
    
    if [[ -z "$cert_file" ]]; then
        echo -e "${RED}ERROR${NC}: Certificate file path is required"
        return 1
    fi
    
    if [[ "$(uname -s)" == "Darwin" ]]; then
        echo -e "${BLUE}INFO${NC}: Removing certificate from macOS system trust store"
        if [[ -f "$cert_file" ]]; then
            sudo security delete-certificate -c "$(openssl x509 -noout -subject -in "$cert_file" | sed 's/subject= //')" /Library/Keychains/System.keychain 2>/dev/null || true
        fi
        echo -e "${GREEN}SUCCESS${NC}: Certificate removal attempted from macOS trust store"
    else
        echo -e "${BLUE}INFO${NC}: Removing certificate from Linux system trust store"
        local cert_name=$(basename "$cert_file" .pem)
        sudo rm -f "/usr/local/share/ca-certificates/${cert_name}.crt"
        sudo update-ca-certificates
        echo -e "${GREEN}SUCCESS${NC}: Certificate removed from Linux trust store"
    fi
}

znap function test_minio_connection() {
    local name=$1
    
    if [[ -z "$name" ]]; then
        echo -e "${RED}ERROR${NC}: MinIO deployment name is required"
        echo "Usage: test_minio_connection <deployment-name>"
        return 1
    fi
    
    if ! config=$(load_minio_config "$name"); then
        return 1
    fi
    
    local endpoint=$(echo "$config" | jq -r '.endpoint')
    local access_key=$(echo "$config" | jq -r '.access_key')
    local secret_key=$(echo "$config" | jq -r '.secret_key')
    local cert_file=$(echo "$config" | jq -r '.cert_file // ""')
    
    echo -e "${BLUE}INFO${NC}: Testing connection to MinIO deployment '$name' at $endpoint"
    
    # Set AWS credentials for this test
    export AWS_ACCESS_KEY_ID="$access_key"
    export AWS_SECRET_ACCESS_KEY="$secret_key"
    
    local aws_cmd="aws s3 ls --endpoint-url $endpoint"
    if [[ -n "$cert_file" && "$cert_file" != "null" && -f "$cert_file" ]]; then
        aws_cmd="$aws_cmd --ca-bundle $cert_file"
    fi
    
    echo -e "${BLUE}INFO${NC}: Running: $aws_cmd"
    if eval "$aws_cmd"; then
        echo -e "${GREEN}SUCCESS${NC}: Connection to MinIO deployment '$name' successful!"
    else
        echo -e "${RED}ERROR${NC}: Failed to connect to MinIO deployment '$name'"
        echo -e "${YELLOW}HINT${NC}: Try running: get-minio-connection-info --name $name"
        return 1
    fi
    
    # Clean up environment
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
}

znap function remove_minio_config() {
    local name=$1
    
    if [[ -z "$name" ]]; then
        echo -e "${RED}ERROR${NC}: MinIO deployment name is required"
        return 1
    fi
    
    local config_file="$MINIO_DEPLOYMENTS_DIR/${name}.json"
    
    if [[ -f "$config_file" ]]; then
        rm "$config_file"
        echo -e "${GREEN}INFO${NC}: Configuration removed for MinIO deployment '$name'"
    else
        echo -e "${YELLOW}WARN${NC}: No configuration found for MinIO deployment '$name'"
    fi
}

znap function download-minio-certificate() {
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
                echo "Usage: download-minio-certificate [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --name NAME      MinIO deployment name (required)"
                echo "  --force          Overwrite existing certificate file"
                echo "  --help           Show this help message"
                echo ""
                echo "Downloads the self-signed certificate from a MinIO deployment."
                echo "Works with both Docker-based and systemd-based deployments."
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
        echo "Usage: download-minio-certificate --name <deployment-name> [--force]"
        return 1
    fi

    if ! config=$(load_minio_config "$name"); then
        return 1
    fi

    local provider=$(echo "$config" | jq -r '.provider')
    local public_dns=$(echo "$config" | jq -r '.public_dns')
    local endpoint=$(echo "$config" | jq -r '.endpoint')
    local cert_dir="$MINIO_DEPLOYMENTS_DIR/$name"
    local cert_file="$cert_dir/minio-cert.pem"

    if [[ "$provider" != "aws" ]]; then
        echo -e "${RED}ERROR${NC}: Certificate download is only supported for AWS deployments"
        return 1
    fi

    # Ensure directory exists
    mkdir -p "$cert_dir"

    # Check if certificate already exists
    if [[ -f "$cert_file" && -s "$cert_file" && "$force" == false ]]; then
        echo -e "${BLUE}INFO${NC}: Certificate already exists at $cert_file"
        echo -e "${YELLOW}NOTE${NC}: Use '--force' to re-download"

        # Verify the existing certificate
        if openssl x509 -in "$cert_file" -text -noout &>/dev/null; then
            echo -e "${GREEN}SUCCESS${NC}: Existing certificate is valid"
            return 0
        else
            echo -e "${YELLOW}WARN${NC}: Existing certificate appears invalid, re-downloading..."
        fi
    fi

    echo -e "${BLUE}INFO${NC}: Downloading certificate from MinIO deployment '$name'"
    echo -e "${BLUE}INFO${NC}: Endpoint: $endpoint"

    # First check if HTTPS is responding
    if ! curl -k -s --connect-timeout 10 --max-time 15 "https://${public_dns}:9000/minio/health/ready" &>/dev/null; then
        echo -e "${RED}ERROR${NC}: MinIO HTTPS endpoint is not responding"
        echo -e "${YELLOW}HINT${NC}: Make sure the MinIO deployment is running"
        echo -e "${YELLOW}HINT${NC}: For Docker deployments, MinIO may take 2-3 minutes to start"
        echo -e "${YELLOW}HINT${NC}: You can check with: curl -k $endpoint/minio/health/ready"
        return 1
    fi

    echo -e "${BLUE}INFO${NC}: Extracting certificate from HTTPS connection..."

    # Extract certificate from the HTTPS connection
    local temp_cert="/tmp/minio-cert-$$.pem"
    if timeout 10 bash -c "echo | openssl s_client -servername '$public_dns' -connect '${public_dns}:9000' 2>/dev/null | openssl x509 -outform PEM" > "$temp_cert"; then
        if [[ -s "$temp_cert" ]]; then
            # Verify the certificate is valid
            if openssl x509 -in "$temp_cert" -text -noout &>/dev/null; then
                mv "$temp_cert" "$cert_file"

                # Update the config file with the certificate path
                local updated_config=$(echo "$config" | jq --arg cert_file "$cert_file" '.cert_file = $cert_file')
                save_minio_config "$name" "$updated_config"

                echo -e "${GREEN}SUCCESS${NC}: Certificate downloaded successfully"
                echo -e "${BLUE}INFO${NC}: Certificate saved to: $cert_file"

                # Show certificate details
                echo -e "${BLUE}INFO${NC}: Certificate details:"
                openssl x509 -in "$cert_file" -noout -subject -dates | sed 's/^/  /'

                echo -e ""
                echo -e "${BLUE}Next steps:${NC}"
                echo -e "  1. Trust the certificate: trust_certificate_in_system $cert_file"
                echo -e "  2. Test connection: test_minio_connection $name"
                echo -e "  3. Use MinIO: get-minio-connection-info --name $name"

                return 0
            else
                echo -e "${RED}ERROR${NC}: Downloaded file is not a valid certificate"
                rm -f "$temp_cert"
                return 1
            fi
        fi
    fi

    # Clean up temp file if it exists
    rm -f "$temp_cert"

    echo -e "${RED}ERROR${NC}: Failed to extract certificate from HTTPS connection"
    echo -e "${YELLOW}HINT${NC}: Make sure MinIO is running with HTTPS enabled"
    echo -e "${YELLOW}HINT${NC}: You can test the connection with: curl -k $endpoint/minio/health/ready"
    return 1
}


# Function to ensure default bucket exists
# Function to check MinIO Docker container status (requires SSH access)
znap function check-minio-docker-status() {
    local name="$1"
    local key_name="$2"

    if [[ -z "$name" ]]; then
        echo -e "${RED}ERROR${NC}: MinIO deployment name is required"
        echo "Usage: check-minio-docker-status <deployment-name> [key-name]"
        return 1
    fi

    if ! config=$(load_minio_config "$name"); then
        return 1
    fi

    local provider=$(echo "$config" | jq -r '.provider')
    local public_dns=$(echo "$config" | jq -r '.public_dns')
    local endpoint=$(echo "$config" | jq -r '.endpoint')

    if [[ "$provider" != "aws" ]]; then
        echo -e "${RED}ERROR${NC}: Docker status check is only supported for AWS deployments"
        return 1
    fi

    echo -e "${BLUE}INFO${NC}: Checking Docker status for MinIO deployment '$name'"

    # First try HTTPS health check
    echo -e "${BLUE}INFO${NC}: Checking HTTPS endpoint..."
    if curl -k -s --connect-timeout 5 --max-time 10 "https://${public_dns}:9000/minio/health/ready" &>/dev/null; then
        echo -e "${GREEN}SUCCESS${NC}: MinIO is responding on HTTPS"
        echo -e "${BLUE}INFO${NC}: Endpoint: $endpoint"
        echo -e "${BLUE}INFO${NC}: Console: https://${public_dns}:9001"
        return 0
    else
        echo -e "${YELLOW}WARN${NC}: MinIO is not responding on HTTPS"

        if [[ -n "$key_name" ]]; then
            echo -e "${BLUE}INFO${NC}: Attempting to check Docker status via SSH..."

            # Try common key locations
            local key_path=""
            if [[ -f ~/.ssh/${key_name}.pem ]]; then
                key_path="~/.ssh/${key_name}.pem"
            elif [[ -f ~/.ssh/${key_name} ]]; then
                key_path="~/.ssh/${key_name}"
            elif [[ -f ${key_name} ]]; then
                key_path="${key_name}"
            else
                echo -e "${RED}ERROR${NC}: SSH key not found"
                return 1
            fi

            echo -e "${BLUE}INFO${NC}: Checking Docker container status..."
            if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$key_path" "ec2-user@${public_dns}" "docker ps --filter name=minio --format 'table {{.Status}}'" 2>/dev/null; then
                echo -e "${BLUE}INFO${NC}: Checking Docker logs (last 20 lines)..."
                ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$key_path" "ec2-user@${public_dns}" "docker logs minio --tail 20" 2>/dev/null
            else
                echo -e "${RED}ERROR${NC}: Could not connect via SSH"
            fi
        else
            echo -e "${YELLOW}HINT${NC}: Provide SSH key name to check Docker container status"
            echo -e "${YELLOW}HINT${NC}: Example: check-minio-docker-status $name your-key-name"
        fi

        return 1
    fi
}

znap function ensure_default_bucket() {
    local deployment_name="$1"
    local bucket_name="${2:-default-bucket}"
    
    if [[ -z "$deployment_name" ]]; then
        echo -e "${RED}ERROR${NC}: Deployment name is required"
        echo "Usage: ensure_default_bucket <deployment-name> [bucket-name]"
        return 1
    fi
    
    local deployment_file="$MINIO_DEPLOYMENTS_DIR/${deployment_name}.json"
    if [[ ! -f "$deployment_file" ]]; then
        echo -e "${RED}ERROR${NC}: Deployment '$deployment_name' not found"
        return 1
    fi
    
    # Get deployment details
    local endpoint=$(jq -r '.endpoint' "$deployment_file")
    local ca_bundle_file="$MINIO_DEPLOYMENTS_DIR/${deployment_name}/minio-cert.pem"
    
    echo -e "${BLUE}INFO${NC}: Checking if bucket '$bucket_name' exists in deployment '$deployment_name'"
    
    # Check if bucket exists
    if aws s3 ls --endpoint-url "$endpoint" --ca-bundle "$ca_bundle_file" 2>/dev/null | grep -q "$bucket_name"; then
        echo -e "${GREEN}SUCCESS${NC}: Bucket '$bucket_name' already exists"
        return 0
    fi
    
    echo -e "${YELLOW}INFO${NC}: Creating bucket '$bucket_name'..."
    if aws s3api create-bucket --bucket "$bucket_name" --endpoint-url "$endpoint" --ca-bundle "$ca_bundle_file" >/dev/null 2>&1; then
        echo -e "${GREEN}SUCCESS${NC}: Created bucket '$bucket_name'"
        return 0
    else
        echo -e "${RED}ERROR${NC}: Failed to create bucket '$bucket_name'"
        echo -e "${YELLOW}HINT${NC}: Make sure AWS credentials are set (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)"
        return 1
    fi
}