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
# Provides a consistent interface for S3 operations using s5cmd for high performance

# Configuration
S3_INTERACTOR_LOG="$NETWORK_VOLUME/.s3_interactor.log"

# Default S3 configuration (can be overridden by environment variables)
S3_PROVIDER="${S3_PROVIDER:-aws}"  # AWS S3 only
S3_ENDPOINT_URL="${S3_ENDPOINT_URL:-}"  # Custom endpoint for S3-compatible services
S3_BUCKET_NAME="${S3_BUCKET_NAME:-$AWS_BUCKET_NAME}"  # Fallback to AWS_BUCKET_NAME
S3_REGION="${S3_REGION:-$AWS_REGION}"  # Fallback to AWS_REGION
S3_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:-$AWS_ACCESS_KEY_ID}"
S3_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-$AWS_SECRET_ACCESS_KEY}"

# s5cmd configuration - uses environment variables or defaults

# Check for s5cmd availability
if ! command -v s5cmd >/dev/null 2>&1; then
    echo "ERROR: s5cmd not found in PATH. Please install s5cmd first."
    exit 1
fi

# Provider-specific configuration
case "$S3_PROVIDER" in
    "aws")
        # AWS S3 configuration (default)
        S5CMD_ENDPOINT_ARG=""
        if [ -n "$S3_ENDPOINT_URL" ]; then
            S5CMD_ENDPOINT_ARG="--endpoint-url $S3_ENDPOINT_URL"
        fi
        ;;
    *)
        echo "ERROR: Unsupported S3_PROVIDER: $S3_PROVIDER. Only 'aws' is supported"
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

# Function to execute s5cmd with provider-specific arguments
execute_s5cmd() {
    # Set environment variables for s5cmd
    export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
    export AWS_DEFAULT_REGION="$S3_REGION"
    
    # Build s5cmd command with endpoint if specified
    if [ -n "$S5CMD_ENDPOINT_ARG" ]; then
        log_s3_activity "DEBUG" "Executing: s5cmd $S5CMD_ENDPOINT_ARG $*"
        s5cmd $S5CMD_ENDPOINT_ARG "$@"
    else
        log_s3_activity "DEBUG" "Executing: s5cmd $*"
        s5cmd "$@"
    fi
}

# =============================================================================
# S3 OPERATION FUNCTIONS
# =============================================================================

# Function to list objects in S3 bucket/prefix
s3_list() {
    local s3_path="$1"
    local options="${2:-}"  # Additional s5cmd ls options
    
    # Translate AWS CLI options to s5cmd options
    local s5cmd_options
    s5cmd_options=$(translate_aws_to_s5cmd_options "$options")
    
    log_s3_activity "INFO" "Listing S3 path: $s3_path"
    
    if [ -n "$s5cmd_options" ]; then
        execute_s5cmd ls $s5cmd_options "$s3_path"
    else
        execute_s5cmd ls "$s3_path"
    fi
}

# Function to copy file/directory to S3
s3_copy_to() {
    local source_path="$1"
    local s3_destination="$2"
    local options="${3:-}"  # Additional s5cmd cp options
    
    if [ ! -e "$source_path" ]; then
        log_s3_activity "ERROR" "Source path does not exist: $source_path"
        return 1
    fi
    
    # Translate AWS CLI options to s5cmd options
    local s5cmd_options
    s5cmd_options=$(translate_aws_to_s5cmd_options "$options")
    
    # For s5cmd: if source is a directory, append /* to copy contents
    if [ -d "$source_path" ]; then
        # Remove trailing slash and add /*
        local normalized_source="${source_path%/}/*"
        log_s3_activity "INFO" "Copying directory to S3: $normalized_source -> $s3_destination"
        
        if [ -n "$s5cmd_options" ]; then
            execute_s5cmd cp $s5cmd_options "$normalized_source" "$s3_destination"
        else
            execute_s5cmd cp "$normalized_source" "$s3_destination"
        fi
    else
        log_s3_activity "INFO" "Copying file to S3: $source_path -> $s3_destination"
        
        if [ -n "$s5cmd_options" ]; then
            execute_s5cmd cp $s5cmd_options "$source_path" "$s3_destination"
        else
            execute_s5cmd cp "$source_path" "$s3_destination"
        fi
    fi
}

# Function to translate AWS CLI options to s5cmd options
translate_aws_to_s5cmd_options() {
    local aws_options="$1"
    local s5cmd_options=""
    
    # Handle common AWS CLI flags and translate them to s5cmd equivalents
    # Remove --only-show-errors (no direct equivalent in s5cmd, s5cmd is less verbose by default)
    aws_options="${aws_options//--only-show-errors/}"
    
    # Handle --recursive flag
    if [[ "$aws_options" == *"--recursive"* ]]; then
        # s5cmd cp handles recursive automatically with /* pattern
        aws_options="${aws_options//--recursive/}"
    fi
    
    # Handle --delete flag (for sync operations)
    if [[ "$aws_options" == *"--delete"* ]]; then
        s5cmd_options="$s5cmd_options --delete"
        aws_options="${aws_options//--delete/}"
    fi
    
    # Clean up any remaining options (remove extra spaces)
    s5cmd_options=$(echo "$s5cmd_options $aws_options" | sed 's/  */ /g' | sed 's/^ *//' | sed 's/ *$//')
    
    # Log the translation for debugging
    if [ -n "$aws_options" ] && [ "$aws_options" != "$s5cmd_options" ]; then
        log_s3_activity "DEBUG" "Translated AWS options '$1' to s5cmd options '$s5cmd_options'"
    fi
    
    echo "$s5cmd_options"
}

# Function to copy file/directory from S3
s3_copy_from() {
    local s3_source="$1"
    local destination_path="$2"
    local options="${3:-}"  # Additional s5cmd cp options
    
    # Translate AWS CLI options to s5cmd options
    local s5cmd_options
    s5cmd_options=$(translate_aws_to_s5cmd_options "$options")
    
    # For s5cmd: if s3_source ends with /* (directory pattern), create destination directory
    # if it's a file pattern, create parent directory
    if [[ "$s3_source" == *"/*" ]]; then
        # Directory copy - ensure destination directory exists
        mkdir -p "$destination_path"
        log_s3_activity "INFO" "Copying directory from S3: $s3_source -> $destination_path"
    else
        # File copy - create parent directory if destination looks like a file path
        if [[ "$destination_path" != */ ]]; then
            mkdir -p "$(dirname "$destination_path")"
        else
            mkdir -p "$destination_path"
        fi
        log_s3_activity "INFO" "Copying file from S3: $s3_source -> $destination_path"
    fi
    
    if [ -n "$s5cmd_options" ]; then
        execute_s5cmd cp $s5cmd_options "$s3_source" "$destination_path"
    else
        execute_s5cmd cp "$s3_source" "$destination_path"
    fi
}

# Function to sync directory to S3
s3_sync_to() {
    local source_path="$1"
    local s3_destination="$2"
    local options="${3:-}"  # Additional s5cmd sync options
    
    if [ ! -d "$source_path" ]; then
        log_s3_activity "ERROR" "Source directory does not exist: $source_path"
        return 1
    fi
    
    # Translate AWS CLI options to s5cmd options
    local s5cmd_options
    s5cmd_options=$(translate_aws_to_s5cmd_options "$options")
    
    # For s5cmd sync: ensure source ends with / and destination ends with /
    local normalized_source="${source_path%/}/"
    local normalized_dest="${s3_destination%/}/"
    
    log_s3_activity "INFO" "Syncing to S3: $normalized_source -> $normalized_dest"
    
    if [ -n "$s5cmd_options" ]; then
        execute_s5cmd sync $s5cmd_options "$normalized_source" "$normalized_dest"
    else
        execute_s5cmd sync "$normalized_source" "$normalized_dest"
    fi
}

# Function to sync directory from S3
s3_sync_from() {
    local s3_source="$1"
    local destination_path="$2"
    local options="${3:-}"  # Additional s5cmd sync options
    
    # Create destination directory if it doesn't exist
    mkdir -p "$destination_path"
    
    # Translate AWS CLI options to s5cmd options
    local s5cmd_options
    s5cmd_options=$(translate_aws_to_s5cmd_options "$options")
    
    # For s5cmd sync: ensure source ends with / and destination ends with /
    local normalized_source="${s3_source%/}/"
    local normalized_dest="${destination_path%/}/"
    
    log_s3_activity "INFO" "Syncing from S3: $normalized_source -> $normalized_dest"
    
    if [ -n "$s5cmd_options" ]; then
        execute_s5cmd sync $s5cmd_options "$normalized_source" "$normalized_dest"
    else
        execute_s5cmd sync "$normalized_source" "$normalized_dest"
    fi
}

# Function to remove S3 object(s)
s3_remove() {
    local s3_path="$1"
    local options="${2:-}"  # Additional s5cmd rm options
    
    # Translate AWS CLI options to s5cmd options
    local s5cmd_options
    s5cmd_options=$(translate_aws_to_s5cmd_options "$options")
    
    log_s3_activity "INFO" "Removing from S3: $s3_path"
    
    if [ -n "$s5cmd_options" ]; then
        execute_s5cmd rm $s5cmd_options "$s3_path"
    else
        execute_s5cmd rm "$s3_path"
    fi
}

# Function to move S3 object
s3_move() {
    local s3_source="$1"
    local s3_destination="$2"
    local options="${3:-}"  # Additional s5cmd mv options
    
    # Translate AWS CLI options to s5cmd options
    local s5cmd_options
    s5cmd_options=$(translate_aws_to_s5cmd_options "$options")
    
    log_s3_activity "INFO" "Moving in S3: $s3_source -> $s3_destination"
    
    if [ -n "$s5cmd_options" ]; then
        execute_s5cmd mv $s5cmd_options "$s3_source" "$s3_destination"
    else
        execute_s5cmd mv "$s3_source" "$s3_destination"
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
    "provider_args": "$S3_CLI_PROVIDER_ARGS"
}
CONFIG_EOF
}


# Function to show usage examples
show_s3_usage() {
    echo "☁️ S3 Interactor Usage Examples"
    echo "================================"
    echo ""
    echo "Configuration:"
    echo "  export S3_PROVIDER=aws"
    echo "  export S3_BUCKET_NAME=my-bucket"
    echo "  export S3_REGION=us-east-1"
    echo "  export S3_ENDPOINT_URL=https://custom-s3-endpoint.com  # For S3-compatible services (optional)"
    echo ""
    echo "Basic Operations:"
    echo "  s3_copy_to /local/file.txt s3://bucket/path/file.txt"
    echo "  s3_copy_to /local/model.safetensors s3://bucket/models/model.safetensors"
    echo "  s3_copy_from s3://bucket/path/file.txt /local/file.txt"
    echo "  s3_sync_to /local/dir s3://bucket/path/"
    echo "  s3_sync_from s3://bucket/path/ /local/dir"
    echo "  s3_list s3://bucket/path/"
    echo "  s3_remove s3://bucket/path/file.txt"
    echo ""
    echo "With AWS CLI compatible options (automatically translated to s5cmd):"
    echo "  s3_copy_from s3://bucket/file.txt /local/file.txt '--only-show-errors'"
    echo "  s3_sync_from s3://bucket/path/ /local/dir '--delete --only-show-errors'"
    echo "  s3_remove s3://bucket/path/ '--recursive --only-show-errors'"
    echo ""
    echo "Advanced Operations:"
    echo "  s3_object_exists s3://bucket/path/file.txt"
    echo "  s3_get_object_size s3://bucket/path/file.txt"
    echo ""
    echo "Testing:"
    echo "  s3_test_connectivity"
    echo "  s3_get_config"
    echo ""
    echo "Note: This script uses s5cmd for high-performance S3 operations but maintains"
    echo "      compatibility with common AWS CLI flags like --only-show-errors, --delete, --recursive"
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
    log_s3_activity "INFO" "S3 Interactor loaded (Provider: $S3_PROVIDER, Bucket: $S3_BUCKET_NAME)"
fi
EOF

chmod +x "$TARGET_DIR/s3_interactor.sh"

echo "✅ S3 interactor script created at $TARGET_DIR/s3_interactor.sh"
echo ""
echo "📚 Usage:"
echo "  Source the script: source \$NETWORK_VOLUME/scripts/s3_interactor.sh"
echo "  Test connectivity: s3_test_connectivity"
echo "  Get configuration: s3_get_config"
echo ""
echo "🔧 Configuration Environment Variables:"
echo "  S3_PROVIDER=aws"
echo "  S3_ENDPOINT_URL=https://custom-s3-endpoint.com  # For S3-compatible services (optional)"
echo "  S3_BUCKET_NAME=your-bucket"
echo "  S3_REGION=your-region"
echo "  S3_ACCESS_KEY_ID=your-access-key"
echo "  S3_SECRET_ACCESS_KEY=your-secret-key"
