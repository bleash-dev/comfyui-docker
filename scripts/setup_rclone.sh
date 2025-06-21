#!/bin/bash
set -eo pipefail

echo "🔧 Setting up rclone S3 storage (sync-only operations)..."

# Validate that NETWORK_VOLUME was set by start.sh
if [ -z "$NETWORK_VOLUME" ]; then
    echo "❌ CRITICAL: NETWORK_VOLUME not set by start.sh. This script cannot proceed."
    exit 1
fi
echo "📁 Using Network Volume: $NETWORK_VOLUME"

# Create scripts directory on the network volume if it doesn't exist
mkdir -p "$NETWORK_VOLUME/scripts"
RCLONE_CACHE_DIR="$NETWORK_VOLUME/.cache/rclone"
mkdir -p "$RCLONE_CACHE_DIR"

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

# Create rclone configuration
RCLONE_CONFIG_DIR="/root/.config/rclone"
RCLONE_CONFIG_FILE="$RCLONE_CONFIG_DIR/rclone.conf"
mkdir -p "$RCLONE_CONFIG_DIR"
echo "📝 Creating rclone configuration at $RCLONE_CONFIG_FILE..."
cat > "$RCLONE_CONFIG_FILE" << EOF
[s3]
type = s3
provider = AWS
access_key_id = $AWS_ACCESS_KEY_ID
secret_access_key = $AWS_SECRET_ACCESS_KEY
region = $AWS_REGION
acl = private
storage_class = STANDARD
EOF
echo "✅ Rclone configuration created."

# Test rclone connection
echo "🔍 Testing S3 connection to bucket '$AWS_BUCKET_NAME'..."

# First try to list the bucket itself (this tests basic connectivity and permissions)
if ! rclone about "s3:$AWS_BUCKET_NAME" --retries 2 >/dev/null 2>&1; then
    echo "❌ CRITICAL: Failed basic connectivity test to S3 bucket '$AWS_BUCKET_NAME'."
    echo "   Trying alternative connection test..."
    
    # Fallback test: try to list the bucket root (even if empty)
    if ! rclone ls "s3:$AWS_BUCKET_NAME/" --max-depth 1 --retries 2 >/dev/null 2>&1; then
        echo "❌ CRITICAL: All S3 connection tests failed for bucket '$AWS_BUCKET_NAME'."
        echo "   Please check:"
        echo "   - AWS credentials (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)"
        echo "   - Bucket name is correct: '$AWS_BUCKET_NAME'"
        echo "   - AWS region is correct: '$AWS_REGION'"
        echo "   - Bucket exists and you have access permissions"
        echo "   - Network connectivity to AWS S3"
        
        # Try to give more specific error information
        echo "🔍 Attempting diagnostic test..."
        rclone ls "s3:$AWS_BUCKET_NAME/" --max-depth 1 --retries 1 --verbose 2>&1 | head -10 || true
        
        exit 1
    else
        echo "✅ S3 connection successful (via fallback test)."
    fi
else
    echo "✅ S3 connection successful (bucket accessible)."
fi

# Additional test: try to create and read a test file to verify write permissions
echo "🔍 Testing S3 write permissions..."
test_file_content="rclone_test_$(date +%s)"
test_s3_path="s3:$AWS_BUCKET_NAME/.rclone_test"

if echo "$test_file_content" | rclone rcat "$test_s3_path" --retries 2 2>/dev/null; then
    # Verify we can read it back
    if downloaded_content=$(rclone cat "$test_s3_path" --retries 2 2>/dev/null) && \
       [ "$downloaded_content" = "$test_file_content" ]; then
        echo "✅ S3 write/read permissions verified."
        # Clean up test file
        rclone delete "$test_s3_path" --retries 1 >/dev/null 2>&1 || true
    else
        echo "⚠️ WARNING: S3 write successful but read verification failed."
        echo "   This may indicate permission issues or eventual consistency delays."
        # Still clean up test file
        rclone delete "$test_s3_path" --retries 1 >/dev/null 2>&1 || true
    fi
else
    echo "⚠️ WARNING: S3 write test failed."
    echo "   You have read access but may not have write permissions."
    echo "   Some features requiring S3 uploads may not work."
    echo "   Proceeding with setup anyway..."
fi

# Create all sync and utility scripts
echo "📝 Creating/configuring dynamic scripts..."
if [ -f /scripts/create_sync_scripts.sh ]; then
    if ! bash /scripts/create_sync_scripts.sh; then
        echo "❌ CRITICAL: Failed to create sync scripts."
        exit 1
    fi
    echo "  ✅ Sync scripts created/configured."
fi

if [ -f /scripts/create_monitoring_scripts.sh ]; then
    if ! bash /scripts/create_monitoring_scripts.sh; then
        echo "❌ CRITICAL: Failed to create monitoring scripts."
        exit 1
    fi
    echo "  ✅ Monitoring scripts created/configured."
fi

if [ -f /scripts/create_utility_scripts.sh ]; then
    if ! bash /scripts/create_utility_scripts.sh; then
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
    "s3_path": "s3:$AWS_BUCKET_NAME/pod_sessions/global_shared/models/",
    "sync_strategy": "on_demand",
    "last_listed": null,
    "note": "Uses rclone sync operations, no FUSE mounting"
}
EOF
echo "✅ Created global shared directory structure: $models_dir"

# Sync user-specific data from S3
USER_SYNC_SCRIPT_PATH=""
if [ -f "$NETWORK_VOLUME/scripts/sync_user_data_from_s3.sh" ]; then
    USER_SYNC_SCRIPT_PATH="$NETWORK_VOLUME/scripts/sync_user_data_from_s3.sh"
elif [ -f "/scripts/sync_user_data_from_s3.sh" ]; then
    USER_SYNC_SCRIPT_PATH="/scripts/sync_user_data_from_s3.sh"
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

echo "✅ Rclone S3 setup completed successfully! (sync-only mode)"