#!/bin/bash
# Create centralized S3 interactor script

# Get the target directory from the first argument
TARGET_DIR="${1:-$NETWORK_VOLUME/scripts}"
mkdir -p "$TARGET_DIR"

echo "☁️ Creating centralized S3 interactor script..."

# Create the S3 interactor script
cat > "$TARGET_DIR/s3_interactor.sh" << 'EOF'
#!/bin/bash
# Centralized S3 Interactor Script
# Provides a consistent interface for S3 operations supporting both AWS S3 and Cloudflare R2

# Configuration
S3_INTERACTOR_LOG="$NETWORK_VOLUME/.s3_interactor.log"

# Default S3 configuration (can be overridden by environment variables)
S3_PROVIDER="${S3_PROVIDER:-aws}"  # "aws" or "cloudflare"
S3_ENDPOINT_URL="${S3_ENDPOINT_URL:-}"  # Custom endpoint for R2 or S3-compatible services
S3_BUCKET_NAME="${S3_BUCKET_NAME:-$AWS_BUCKET_NAME}"  # Fallback to AWS_BUCKET_NAME
S3_REGION="${S3_REGION:-$AWS_REGION}"  # Fallback to AWS_REGION
S3_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:-$AWS_ACCESS_KEY_ID}"
S3_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-$AWS_SECRET_ACCESS_KEY}"

# Models Staging Bucket Configuration (AWS S3 for fast uploads)
MODELS_STAGING_BUCKET_NAME="${MODELS_STAGING_BUCKET_NAME:-}"
MODELS_STAGING_REGION="${MODELS_STAGING_REGION:-us-east-1}"
MODELS_STAGING_ACCESS_KEY_ID="${MODELS_STAGING_ACCESS_KEY_ID:-}"
MODELS_STAGING_SECRET_ACCESS_KEY="${MODELS_STAGING_SECRET_ACCESS_KEY:-}"

# Provider-specific configuration
case "$S3_PROVIDER" in
    "cloudflare")
        # Cloudflare R2 configuration
        if [ -z "$S3_ENDPOINT_URL" ]; then
            # Format: https://<account-id>.r2.cloudflarestorage.com
            S3_ENDPOINT_URL="${CLOUDFLARE_R2_ENDPOINT:-}"
            if [ -z "$S3_ENDPOINT_URL" ]; then
                echo "ERROR: For Cloudflare R2, set CLOUDFLARE_R2_ENDPOINT or S3_ENDPOINT_URL"
                exit 1
            fi
        fi
        S3_CLI_PROVIDER_ARGS="--endpoint-url $S3_ENDPOINT_URL"
        ;;
    "aws")
        # AWS S3 configuration (default)
        S3_CLI_PROVIDER_ARGS=""
        if [ -n "$S3_ENDPOINT_URL" ]; then
            S3_CLI_PROVIDER_ARGS="--endpoint-url $S3_ENDPOINT_URL"
        fi
        ;;
    *)
        echo "ERROR: Unsupported S3_PROVIDER: $S3_PROVIDER. Use 'aws' or 'cloudflare'"
        exit 1
        ;;
esac

# Ensure log file exists
mkdir -p "$(dirname "$S3_INTERACTOR_LOG")"
touch "$S3_INTERACTOR_LOG"

# Function to log S3 interactor activities
log_s3_activity() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] S3 Interactor ($S3_PROVIDER): $message" | tee -a "$S3_INTERACTOR_LOG" >&2
}

# Function to get AWS CLI command with provider-specific arguments
get_aws_cli_cmd() {
    local aws_cmd="aws"
    if [ -n "${AWS_CLI_OVERRIDE:-}" ] && [ -x "$AWS_CLI_OVERRIDE" ]; then
        aws_cmd="$AWS_CLI_OVERRIDE"
    fi
    echo "$aws_cmd"
}

# Function to build S3 URI from bucket and key
build_s3_uri() {
    local bucket="$1"
    local key="$2"
    
    if [ -z "$bucket" ]; then
        bucket="$S3_BUCKET_NAME"
    fi
    
    echo "s3://${bucket}/${key}"
}

# Function to parse S3 URI into bucket and key
parse_s3_uri() {
    local s3_uri="$1"
    local output_var_bucket="$2"
    local output_var_key="$3"
    
    if [[ "$s3_uri" =~ ^s3://([^/]+)/(.*)$ ]]; then
        eval "$output_var_bucket='${BASH_REMATCH[1]}'"
        eval "$output_var_key='${BASH_REMATCH[2]}'"
        return 0
    else
        log_s3_activity "ERROR" "Invalid S3 URI format: $s3_uri"
        return 1
    fi
}

# Function to execute AWS CLI with provider-specific arguments
execute_aws_cli() {
    local aws_cmd
    aws_cmd=$(get_aws_cli_cmd)
    
    # Set environment variables for the command
    export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
    export AWS_DEFAULT_REGION="$S3_REGION"
    
    # Execute with provider-specific arguments
    if [ -n "$S3_CLI_PROVIDER_ARGS" ]; then
        log_s3_activity "DEBUG" "Executing: $aws_cmd $S3_CLI_PROVIDER_ARGS $*"
        "$aws_cmd" $S3_CLI_PROVIDER_ARGS "$@"
    else
        log_s3_activity "DEBUG" "Executing: $aws_cmd $*"
        "$aws_cmd" "$@"
    fi
}

# Function to execute AWS CLI with staging bucket credentials (for models)
execute_staging_aws_cli() {
    local aws_cmd
    aws_cmd=$(get_aws_cli_cmd)
    
    # Set environment variables for staging bucket
    export AWS_ACCESS_KEY_ID="$MODELS_STAGING_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$MODELS_STAGING_SECRET_ACCESS_KEY"
    export AWS_DEFAULT_REGION="$MODELS_STAGING_REGION"
    
    # Always use standard AWS S3 for staging (no custom endpoint)
    log_s3_activity "DEBUG" "Executing staging: $aws_cmd $*"
    "$aws_cmd" "$@"
}

# Function to check if an S3 path contains models
is_models_path() {
    local s3_path="$1"
    
    # Check if path contains "models/" or "model" (case insensitive)
    if echo "$s3_path" | grep -qi "models/"; then
        return 0
    fi
    return 1
}

# Function to get staging bucket name for models
get_staging_bucket_for_models() {
    if [ -n "$MODELS_STAGING_BUCKET_NAME" ]; then
        echo "$MODELS_STAGING_BUCKET_NAME"
    else
        echo "$S3_BUCKET_NAME"  # Fallback to regular bucket
    fi
}

# Function to check if staging bucket is configured
is_staging_configured() {
    [ -n "$MODELS_STAGING_BUCKET_NAME" ] && \
    [ -n "$MODELS_STAGING_ACCESS_KEY_ID" ] && \
    [ -n "$MODELS_STAGING_SECRET_ACCESS_KEY" ]
}

# =============================================================================
# S3 OPERATION FUNCTIONS
# =============================================================================

# Function to list objects in S3 bucket/prefix
s3_list() {
    local s3_path="$1"
    local options="${2:-}"  # Additional aws s3 ls options
    
    log_s3_activity "INFO" "Listing S3 path: $s3_path"
    
    if [ -n "$options" ]; then
        execute_aws_cli s3 ls "$s3_path" $options
    else
        execute_aws_cli s3 ls "$s3_path"
    fi
}

# Function to copy file/directory to S3
s3_copy_to() {
    local source_path="$1"
    local s3_destination="$2"
    local options="${3:-}"  # Additional aws s3 cp options
    
    if [ ! -e "$source_path" ]; then
        log_s3_activity "ERROR" "Source path does not exist: $source_path"
        return 1
    fi
    
    # Check if this is a models upload and staging is configured
    if is_models_path "$s3_destination" && is_staging_configured; then
        log_s3_activity "INFO" "Models upload detected - using staging bucket: $source_path -> $s3_destination"
        
        # Parse original destination to get the key
        local bucket key
        if parse_s3_uri "$s3_destination" bucket key; then
            # Create staging destination with staging bucket
            local staging_destination="s3://$MODELS_STAGING_BUCKET_NAME/$key"
            log_s3_activity "INFO" "Staging upload: $source_path -> $staging_destination"
            
            # Upload to staging bucket using staging credentials
            if [ -n "$options" ]; then
                execute_staging_aws_cli s3 cp "$source_path" "$staging_destination" $options
            else
                execute_staging_aws_cli s3 cp "$source_path" "$staging_destination"
            fi
        else
            log_s3_activity "ERROR" "Failed to parse S3 destination: $s3_destination"
            return 1
        fi
    else
        # Regular upload to main bucket
        log_s3_activity "INFO" "Copying to S3: $source_path -> $s3_destination"
        
        if [ -n "$options" ]; then
            execute_aws_cli s3 cp "$source_path" "$s3_destination" $options
        else
            execute_aws_cli s3 cp "$source_path" "$s3_destination"
        fi
    fi
}

# Function to copy file from S3
s3_copy_from() {
    local s3_source="$1"
    local destination_path="$2"
    local options="${3:-}"  # Additional aws s3 cp options
    
    # Create destination directory if it doesn't exist
    mkdir -p "$(dirname "$destination_path")"
    
    log_s3_activity "INFO" "Copying from S3: $s3_source -> $destination_path"
    
    if [ -n "$options" ]; then
        execute_aws_cli s3 cp "$s3_source" "$destination_path" $options
    else
        execute_aws_cli s3 cp "$s3_source" "$destination_path"
    fi
}

# Function to sync directory to S3
s3_sync_to() {
    local source_path="$1"
    local s3_destination="$2"
    local options="${3:-}"  # Additional aws s3 sync options
    
    if [ ! -d "$source_path" ]; then
        log_s3_activity "ERROR" "Source directory does not exist: $source_path"
        return 1
    fi
    
    log_s3_activity "INFO" "Syncing to S3: $source_path -> $s3_destination"
    
    if [ -n "$options" ]; then
        execute_aws_cli s3 sync "$source_path" "$s3_destination" $options
    else
        execute_aws_cli s3 sync "$source_path" "$s3_destination"
    fi
}

# Function to sync directory from S3
s3_sync_from() {
    local s3_source="$1"
    local destination_path="$2"
    local options="${3:-}"  # Additional aws s3 sync options
    
    # Create destination directory if it doesn't exist
    mkdir -p "$destination_path"
    
    log_s3_activity "INFO" "Syncing from S3: $s3_source -> $destination_path"
    
    if [ -n "$options" ]; then
        execute_aws_cli s3 sync "$s3_source" "$destination_path" $options
    else
        execute_aws_cli s3 sync "$s3_source" "$destination_path"
    fi
}

# Function to remove S3 object(s)
s3_remove() {
    local s3_path="$1"
    local options="${2:-}"  # Additional aws s3 rm options (e.g., --recursive)
    
    log_s3_activity "INFO" "Removing from S3: $s3_path"
    
    if [ -n "$options" ]; then
        execute_aws_cli s3 rm "$s3_path" $options
    else
        execute_aws_cli s3 rm "$s3_path"
    fi
}

# Function to move S3 object
s3_move() {
    local s3_source="$1"
    local s3_destination="$2"
    local options="${3:-}"  # Additional aws s3 mv options
    
    log_s3_activity "INFO" "Moving in S3: $s3_source -> $s3_destination"
    
    if [ -n "$options" ]; then
        execute_aws_cli s3 mv "$s3_source" "$s3_destination" $options
    else
        execute_aws_cli s3 mv "$s3_source" "$s3_destination"
    fi
}

# Function to check if an S3 object exists (head-object operation)
s3_head_object() {
    local s3_uri="$1"
    local bucket_name key
    
    # Parse S3 URI
    if [[ "$s3_uri" =~ s3://([^/]+)/(.*) ]]; then
        bucket_name="${BASH_REMATCH[1]}"
        key="${BASH_REMATCH[2]}"
    else
        echo "ERROR: Invalid S3 URI format: $s3_uri" >&2
        return 1
    fi
    
    log_s3_activity "DEBUG" "Checking object existence: $s3_uri"
    
    # Use AWS CLI for head-object as this is an API-specific operation
    execute_aws_cli s3api head-object --bucket "$bucket_name" --key "$key"
}

# Function to get object metadata using s3api
s3_get_object_metadata() {
    local s3_uri="$1"
    local bucket key
    
    if ! parse_s3_uri "$s3_uri" bucket key; then
        return 1
    fi
    
    log_s3_activity "DEBUG" "Getting object metadata: $s3_uri"
    execute_aws_cli s3api head-object --bucket "$bucket" --key "$key"
}

# Function to get object size
s3_get_object_size() {
    local s3_uri="$1"
    local bucket key
    
    if ! parse_s3_uri "$s3_uri" bucket key; then
        return 1
    fi
    
    log_s3_activity "DEBUG" "Getting object size: $s3_uri"
    execute_aws_cli s3api head-object --bucket "$bucket" --key "$key" --query 'ContentLength' --output text
}

# Function to check if S3 object exists
s3_object_exists() {
    local s3_uri="$1"
    local bucket key
    
    if ! parse_s3_uri "$s3_uri" bucket key; then
        return 1
    fi
    
    log_s3_activity "DEBUG" "Checking if object exists: $s3_uri"
    execute_aws_cli s3api head-object --bucket "$bucket" --key "$key" >/dev/null 2>&1
}

# Function to download S3 object with range (for chunked downloads)
s3_download_range() {
    local s3_uri="$1"
    local output_file="$2"
    local range="$3"  # Format: "bytes=start-end"
    local bucket key
    
    if ! parse_s3_uri "$s3_uri" bucket key; then
        return 1
    fi
    
    # Create directory for output file
    mkdir -p "$(dirname "$output_file")"
    
    log_s3_activity "DEBUG" "Downloading range $range from: $s3_uri"
    execute_aws_cli s3api get-object --bucket "$bucket" --key "$key" --range "$range" "$output_file"
}

# Function to test S3 connectivity
s3_test_connectivity() {
    log_s3_activity "INFO" "Testing S3 connectivity to provider: $S3_PROVIDER"
    
    # Try to list the bucket
    if execute_aws_cli s3 ls "s3://$S3_BUCKET_NAME/" >/dev/null 2>&1; then
        log_s3_activity "INFO" "S3 connectivity test successful"
        return 0
    else
        log_s3_activity "ERROR" "S3 connectivity test failed"
        return 1
    fi
}

# Function to get current S3 configuration info
s3_get_config() {
    cat << CONFIG_EOF
{
    "provider": "$S3_PROVIDER",
    "bucket": "$S3_BUCKET_NAME",
    "region": "$S3_REGION",
    "endpoint_url": "$S3_ENDPOINT_URL",
    "provider_args": "$S3_CLI_PROVIDER_ARGS",
    "staging": {
        "configured": $(is_staging_configured && echo "true" || echo "false"),
        "bucket": "$MODELS_STAGING_BUCKET_NAME",
        "region": "$MODELS_STAGING_REGION"
    }
}
CONFIG_EOF
}


# Function to show usage examples
show_s3_usage() {
    echo "☁️ S3 Interactor Usage Examples"
    echo "================================"
    echo ""
    echo "Configuration:"
    echo "  export S3_PROVIDER=aws          # or 'cloudflare'"
    echo "  export S3_BUCKET_NAME=my-bucket"
    echo "  export S3_REGION=us-east-1"
    echo "  export S3_ENDPOINT_URL=https://account-id.r2.cloudflarestorage.com  # For R2"
    echo ""
    echo "Models Staging Configuration (for fast uploads):"
    echo "  export MODELS_STAGING_BUCKET_NAME=my-staging-bucket"
    echo "  export MODELS_STAGING_REGION=us-east-1"
    echo "  export MODELS_STAGING_ACCESS_KEY_ID=staging-key"
    echo "  export MODELS_STAGING_SECRET_ACCESS_KEY=staging-secret"
    echo ""
    echo "Basic Operations:"
    echo "  s3_copy_to /local/file.txt s3://bucket/path/file.txt"
    echo "  s3_copy_to /local/model.safetensors s3://bucket/models/model.safetensors  # Auto-staging"
    echo "  s3_copy_from s3://bucket/path/file.txt /local/file.txt"
    echo "  s3_sync_to /local/dir s3://bucket/path/"
    echo "  s3_sync_from s3://bucket/path/ /local/dir"
    echo "  s3_list s3://bucket/path/"
    echo "  s3_remove s3://bucket/path/file.txt"
    echo ""
    echo "Advanced Operations:"
    echo "  s3_object_exists s3://bucket/path/file.txt"
    echo "  s3_get_object_size s3://bucket/path/file.txt"
    echo "  s3_download_range s3://bucket/file.txt /local/chunk.bin 'bytes=0-1048575'"
}

# Allow script to be sourced or called directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Script is being run directly
    case "${1:-help}" in
        "test")
            s3_test_connectivity
            ;;
        "config")
            s3_get_config
            ;;
        "help"|*)
            show_s3_usage
            ;;
    esac
else
    # Script is being sourced
    if is_staging_configured; then
        log_s3_activity "INFO" "S3 Interactor loaded (Provider: $S3_PROVIDER, Bucket: $S3_BUCKET_NAME, Staging: $MODELS_STAGING_BUCKET_NAME)"
    else
        log_s3_activity "INFO" "S3 Interactor loaded (Provider: $S3_PROVIDER, Bucket: $S3_BUCKET_NAME, Staging: Not configured)"
    fi
fi
EOF

chmod +x "$TARGET_DIR/s3_interactor.sh"

echo "✅ S3 interactor script created at $TARGET_DIR/s3_interactor.sh"
echo ""
echo "📚 Usage:"
echo "  Source the script: source \$NETWORK_VOLUME/scripts/s3_interactor.sh"
echo "  Test connectivity: s3_test_connectivity"
echo "  Get configuration: s3_get_config"
echo "  Migrate to Cloudflare R2: s3_migrate_to_cloudflare 'your-account-id'"
echo ""
echo "🔧 Configuration Environment Variables:"
echo "  S3_PROVIDER=aws|cloudflare"
echo "  S3_ENDPOINT_URL=https://account-id.r2.cloudflarestorage.com"
echo "  S3_BUCKET_NAME=your-bucket"
echo "  S3_REGION=your-region"
echo "  S3_ACCESS_KEY_ID=your-access-key"
echo "  S3_SECRET_ACCESS_KEY=your-secret-key"
echo ""
echo "🚀 Models Staging Configuration (for fast uploads):"
echo "  MODELS_STAGING_BUCKET_NAME=your-staging-bucket"
echo "  MODELS_STAGING_REGION=us-east-1"
echo "  MODELS_STAGING_ACCESS_KEY_ID=your-staging-key"
echo "  MODELS_STAGING_SECRET_ACCESS_KEY=your-staging-secret"
echo "  # Models are automatically moved from staging to main bucket by backend"
