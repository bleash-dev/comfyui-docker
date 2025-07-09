#!/bin/bash
set -eo pipefail

echo "🔧 Setting up AWS S3 storage (sync-only operations)..."

# Set default script directory and config root
export SCRIPT_DIR="${SCRIPT_DIR:-/scripts}"
export CONFIG_ROOT="${CONFIG_ROOT:-/root}"

echo "📁 Using Config Root: $CONFIG_ROOT"

# Validate that NETWORK_VOLUME was set by start.sh
if [ -z "$NETWORK_VOLUME" ]; then
    echo "❌ CRITICAL: NETWORK_VOLUME not set by start.sh. This script cannot proceed."
    exit 1
fi
echo "📁 Using Network Volume: $NETWORK_VOLUME"

# Create scripts directory on the network volume if it doesn't exist
mkdir -p "$NETWORK_VOLUME/scripts"
AWS_CACHE_DIR="$NETWORK_VOLUME/.cache/aws"
mkdir -p "$AWS_CACHE_DIR"

# Validate required environment variables
required_vars=("AWS_BUCKET_NAME" "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_REGION" "POD_USER_NAME" "POD_ID")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ CRITICAL: Required environment variable $var is not set."
        if [ "$var" = "POD_ID" ]; then
            echo "POD_ID is required for pod-specific data isolation. Container startup ABORTED."
        fi
        exit 1
    fi
done

echo "✅ Environment variables validated."
echo "   Bucket: $AWS_BUCKET_NAME, Region: $AWS_REGION, User: $POD_USER_NAME, Pod: $POD_ID"

# Configure AWS CLI
echo "📝 Configuring AWS CLI..."
AWS_CONFIG_ROOT="$CONFIG_ROOT/.aws"
export AWS_CONFIG_FILE="$AWS_CACHE_DIR/config"
export AWS_SHARED_CREDENTIALS_FILE="$AWS_CACHE_DIR/credentials"

mkdir -p "$(dirname "$AWS_CONFIG_FILE")"
mkdir -p "$(dirname "$AWS_SHARED_CREDENTIALS_FILE")"
mkdir -p "$AWS_CONFIG_ROOT"

cat > "$AWS_CONFIG_FILE" << EOF
[default]
region = $AWS_REGION
output = json
EOF

cat > "$AWS_SHARED_CREDENTIALS_FILE" << EOF
[default]
aws_access_key_id = $AWS_ACCESS_KEY_ID
aws_secret_access_key = $AWS_SECRET_ACCESS_KEY
EOF

# Set restrictive permissions
chmod 600 "$AWS_CONFIG_FILE"
chmod 600 "$AWS_SHARED_CREDENTIALS_FILE"

# Create symlink to config root for easy access
rm -rf "$AWS_CONFIG_ROOT"
ln -sf "$AWS_CACHE_DIR" "$AWS_CONFIG_ROOT"

echo "✅ AWS CLI configuration created."
echo "📁 AWS config accessible at: $AWS_CONFIG_ROOT"

# Setup cache directory symlink to ensure it's stored in network volume
echo "📁 Setting up cache directory symlink..."
NETWORK_CACHE_DIR="$NETWORK_VOLUME/.cache"
ROOT_CACHE_DIR="$CONFIG_ROOT/.cache"

mkdir -p "$NETWORK_CACHE_DIR"

# Remove existing cache dir and create symlink if it doesn't exist or isn't a symlink
if [ ! -L "$ROOT_CACHE_DIR" ]; then
    [ -d "$ROOT_CACHE_DIR" ] && rm -rf "$ROOT_CACHE_DIR"
    ln -sf "$NETWORK_CACHE_DIR" "$ROOT_CACHE_DIR"
    echo "✅ Cache directory symlinked: $ROOT_CACHE_DIR -> $NETWORK_CACHE_DIR"
else
    echo "✅ Cache directory symlink already exists"
fi

# Test AWS S3 connection
echo "🔍 Testing S3 connection to bucket '$AWS_BUCKET_NAME'..."

# First try to get bucket location
echo "   Attempting bucket location test..."
if ! bucket_location_output=$(aws s3api get-bucket-location --bucket "$AWS_BUCKET_NAME" 2>&1); then
    echo "❌ CRITICAL: Failed basic connectivity test to S3 bucket '$AWS_BUCKET_NAME'."
    echo "   Bucket location test error output:"
    echo "   $bucket_location_output"
    echo "   Trying alternative connection test..."
    
    # Fallback test: try to list bucket contents
    echo "   Attempting bucket list test..."
    if ! bucket_list_output=$(aws s3 ls "s3://$AWS_BUCKET_NAME/" 2>&1); then
        echo "❌ CRITICAL: All S3 connection tests failed for bucket '$AWS_BUCKET_NAME'."
        echo "   Bucket list test error output:"
        echo "   $bucket_list_output"
        echo ""
        echo "   Please check:"
        echo "   - AWS credentials (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)"
        echo "   - Bucket name is correct: '$AWS_BUCKET_NAME'"
        echo "   - AWS region is correct: '$AWS_REGION'"
        echo "   - Bucket exists and you have access permissions"
        echo "   - Network connectivity to AWS S3"
        
        # Try to give more specific error information with debug output
        echo "🔍 Attempting diagnostic test with debug output..."
        aws s3 ls "s3://$AWS_BUCKET_NAME/" --debug 2>&1 | head -20 || true
        
        exit 1
    else
        echo "✅ S3 connection successful (via fallback test)."
        echo "   Bucket list output preview:"
        echo "   $(echo "$bucket_list_output" | head -3)"
    fi
else
    echo "✅ S3 connection successful (bucket accessible)."
    echo "   Bucket location: $(echo "$bucket_location_output" | jq -r '.LocationConstraint // "us-east-1"' 2>/dev/null || echo "unknown")"
fi

# Additional test: try to create and read a test file to verify write permissions
echo "🔍 Testing S3 write permissions..."
test_file_content="aws_test_$(date +%s)"
test_s3_path="s3://$AWS_BUCKET_NAME/.aws_test"
test_local_file="/tmp/.aws_test"

echo "$test_file_content" > "$test_local_file"

echo "   Attempting to write test file..."
if upload_output=$(aws s3 cp "$test_local_file" "$test_s3_path" 2>&1); then
    echo "   Test file upload successful, attempting to read back..."
    # Verify we can read it back
    if downloaded_content=$(aws s3 cp "$test_s3_path" - 2>&1) && \
       [ "$downloaded_content" = "$test_file_content" ]; then
        echo "✅ S3 write/read permissions verified."
        # Clean up test file
        aws s3 rm "$test_s3_path" >/dev/null 2>&1 || true
    else
        echo "⚠️ WARNING: S3 write successful but read verification failed."
        echo "   Read error output: $downloaded_content"
        echo "   This may indicate permission issues or eventual consistency delays."
        # Still clean up test file
        aws s3 rm "$test_s3_path" >/dev/null 2>&1 || true
    fi
else
    echo "⚠️ WARNING: S3 write test failed."
    echo "   Write error output:"
    echo "   $upload_output"
    echo "   You have read access but may not have write permissions."
    echo "   Some features requiring S3 uploads may not work."
    echo "   Proceeding with setup anyway..."
fi

rm -f "$test_local_file"

# Create all sync and utility scripts
echo "📝 Creating/configuring dynamic scripts..."
if [ -f "$SCRIPT_DIR/create_sync_scripts.sh" ]; then
    if ! bash "$SCRIPT_DIR/create_sync_scripts.sh"; then
        echo "❌ CRITICAL: Failed to create sync scripts."
        exit 1
    fi
    echo "  ✅ Sync scripts created/configured."
fi

if [ -f "$SCRIPT_DIR/create_monitoring_scripts.sh" ]; then
    if ! bash "$SCRIPT_DIR/create_monitoring_scripts.sh"; then
        echo "❌ CRITICAL: Failed to create monitoring scripts."
        exit 1
    fi
    echo "  ✅ Monitoring scripts created/configured."
fi

if [ -f "$SCRIPT_DIR/create_utility_scripts.sh" ]; then
    if ! bash "$SCRIPT_DIR/create_utility_scripts.sh"; then
        echo "❌ CRITICAL: Failed to create utility scripts."
        exit 1
    fi
    echo "  ✅ Utility scripts created/configured."
fi
echo "✅ Dynamic script creation completed."

# Create global shared models directory structure (no mounting)
echo "🌐 Setting up global shared models directory structure..."
models_dir="$NETWORK_VOLUME/ComfyUI/models"
mkdir -p "$models_dir"

# Create a metadata file to indicate this is a global shared directory
cat > "$models_dir/.global_shared_info" << EOF
{
    "type": "global_shared",
    "s3_path": "s3://$AWS_BUCKET_NAME/pod_sessions/global_shared/models/",
    "sync_strategy": "on_demand",
    "last_listed": null,
    "note": "Uses AWS CLI sync operations, no mounting"
}
EOF
echo "✅ Created global shared directory structure: $models_dir"

# Setup global shared browser session directory and sync from S3
echo "🌐 Setting up global shared browser session..."
browser_sessions_dir="$NETWORK_VOLUME/ComfyUI/.browser-session"
s3_browser_sessions_base="s3://$AWS_BUCKET_NAME/pod_sessions/global_shared/.browser-session"

mkdir -p "$browser_sessions_dir"

echo "📥 Syncing global shared browser session from S3..."
if aws s3 ls "$s3_browser_sessions_base/" >/dev/null 2>&1; then
    echo "  📥 Downloading browser session from $s3_browser_sessions_base/"
    if aws s3 sync "$s3_browser_sessions_base/" "$browser_sessions_dir/" --only-show-errors; then
        echo "  ✅ Browser session synced successfully"
    else
        echo "  ⚠️ WARNING: Failed to sync browser session from S3, starting with empty directory"
    fi
else
    echo "  ℹ️ No existing browser sessions found in S3, starting with empty directory"
fi

# Create metadata file for browser sessions
cat > "$browser_sessions_dir/.global_shared_info" << EOF
{
    "type": "global_shared_browser_session",
    "s3_path": "$s3_browser_sessions_base/",
    "sync_strategy": "periodic",
    "last_synced": "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)",
    "note": "Global shared browser session, synced periodically with models"
}
EOF
echo "✅ Created global shared browser session directory: $browser_sessions_dir"

# Sync user-specific data from S3
USER_SYNC_SCRIPT_PATH=""
if [ -f "$NETWORK_VOLUME/scripts/sync_user_data_from_s3.sh" ]; then
    USER_SYNC_SCRIPT_PATH="$NETWORK_VOLUME/scripts/sync_user_data_from_s3.sh"
elif [ -f "$SCRIPT_DIR/sync_user_data_from_s3.sh" ]; then
    USER_SYNC_SCRIPT_PATH="$SCRIPT_DIR/sync_user_data_from_s3.sh"
fi

if [ -n "$USER_SYNC_SCRIPT_PATH" ]; then
    echo "👤 Syncing user-specific data from S3 via $USER_SYNC_SCRIPT_PATH..."
    if ! bash "$USER_SYNC_SCRIPT_PATH"; then
        echo "⚠️ WARNING: User-specific data sync encountered issues. Startup will continue."
    fi
    echo "✅ User-specific data sync process completed."
else
    echo "⚠️ WARNING: User data sync script not found. Skipping user data sync."
fi

# Sync remote models after cache restoration
# echo "🌐 Starting initial remote model sync..."
# if [ -f "$NETWORK_VOLUME/scripts/sync_remote_models.sh" ]; then
#     # Run in background to avoid blocking startup
#     nohup bash "$NETWORK_VOLUME/scripts/sync_remote_models.sh" > "$NETWORK_VOLUME/.initial_model_sync.log" 2>&1 &
#     INITIAL_SYNC_PID=$!
#     echo "📊 Initial model sync started in background (PID: $INITIAL_SYNC_PID)"
#     echo "📝 Check progress: tail -f $NETWORK_VOLUME/.initial_model_sync.log"
# else
#     echo "⚠️ Remote model sync script not found, skipping initial sync"
# fi

echo "✅ AWS S3 setup completed successfully! (sync-only mode)"