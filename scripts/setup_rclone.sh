#!/bin/bash
set -eo pipefail

echo "🔧 Setting up AWS S3 storage (sync-only operations)..."

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
export AWS_CONFIG_FILE="$AWS_CACHE_DIR/config"
export AWS_SHARED_CREDENTIALS_FILE="$AWS_CACHE_DIR/credentials"

mkdir -p "$(dirname "$AWS_CONFIG_FILE")"
mkdir -p "$(dirname "$AWS_SHARED_CREDENTIALS_FILE")"

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

echo "✅ AWS CLI configuration created."

# Test AWS S3 connection
echo "🔍 Testing S3 connection to bucket '$AWS_BUCKET_NAME'..."

# First try to get bucket location
if ! aws s3api get-bucket-location --bucket "$AWS_BUCKET_NAME" >/dev/null 2>&1; then
    echo "❌ CRITICAL: Failed basic connectivity test to S3 bucket '$AWS_BUCKET_NAME'."
    echo "   Trying alternative connection test..."
    
    # Fallback test: try to list bucket contents
    if ! aws s3 ls "s3://$AWS_BUCKET_NAME/" >/dev/null 2>&1; then
        echo "❌ CRITICAL: All S3 connection tests failed for bucket '$AWS_BUCKET_NAME'."
        echo "   Please check:"
        echo "   - AWS credentials (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)"
        echo "   - Bucket name is correct: '$AWS_BUCKET_NAME'"
        echo "   - AWS region is correct: '$AWS_REGION'"
        echo "   - Bucket exists and you have access permissions"
        echo "   - Network connectivity to AWS S3"
        
        # Try to give more specific error information
        echo "🔍 Attempting diagnostic test..."
        aws s3 ls "s3://$AWS_BUCKET_NAME/" --debug 2>&1 | head -10 || true
        
        exit 1
    else
        echo "✅ S3 connection successful (via fallback test)."
    fi
else
    echo "✅ S3 connection successful (bucket accessible)."
fi

# Additional test: try to create and read a test file to verify write permissions
echo "🔍 Testing S3 write permissions..."
test_file_content="aws_test_$(date +%s)"
test_s3_path="s3://$AWS_BUCKET_NAME/.aws_test"
test_local_file="/tmp/.aws_test"

echo "$test_file_content" > "$test_local_file"

if aws s3 cp "$test_local_file" "$test_s3_path" >/dev/null 2>&1; then
    # Verify we can read it back
    if downloaded_content=$(aws s3 cp "$test_s3_path" - 2>/dev/null) && \
       [ "$downloaded_content" = "$test_file_content" ]; then
        echo "✅ S3 write/read permissions verified."
        # Clean up test file
        aws s3 rm "$test_s3_path" >/dev/null 2>&1 || true
    else
        echo "⚠️ WARNING: S3 write successful but read verification failed."
        echo "   This may indicate permission issues or eventual consistency delays."
        # Still clean up test file
        aws s3 rm "$test_s3_path" >/dev/null 2>&1 || true
    fi
else
    echo "⚠️ WARNING: S3 write test failed."
    echo "   You have read access but may not have write permissions."
    echo "   Some features requiring S3 uploads may not work."
    echo "   Proceeding with setup anyway..."
fi

rm -f "$test_local_file"

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
    "s3_path": "s3://$AWS_BUCKET_NAME/pod_sessions/global_shared/models/",
    "sync_strategy": "on_demand",
    "last_listed": null,
    "note": "Uses AWS CLI sync operations, no mounting"
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

echo "✅ AWS S3 setup completed successfully! (sync-only mode)"