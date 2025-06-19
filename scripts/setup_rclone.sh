#!/bin/bash

echo "🔧 Setting up rclone S3 mounting..."

# Validate that NETWORK_VOLUME was set by start.sh
if [ -z "$NETWORK_VOLUME" ]; then
    echo "❌ CRITICAL: NETWORK_VOLUME not set by start.sh"
    exit 1
fi

echo "📁 Using Network Volume: $NETWORK_VOLUME"

# Create scripts directory
mkdir -p "$NETWORK_VOLUME/scripts"

# Validate required environment variables
required_vars=("AWS_BUCKET_NAME" "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_REGION" "POD_USER_NAME" "POD_ID")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ Required environment variable $var is not set"
        if [ "$var" = "POD_ID" ]; then
            echo "POD_ID is required for pod-specific data isolation"
            echo "Container startup ABORTED due to missing POD_ID."
        fi
        exit 1
    fi
done

echo "✅ Environment variables validated"
echo "Bucket: $AWS_BUCKET_NAME, Region: $AWS_REGION, User: $POD_USER_NAME, Pod: $POD_ID"

# Create rclone configuration
mkdir -p /root/.config/rclone
cat > /root/.config/rclone/rclone.conf << EOF
[s3]
type = s3
provider = AWS
access_key_id = $AWS_ACCESS_KEY_ID
secret_access_key = $AWS_SECRET_ACCESS_KEY
region = $AWS_REGION
acl = private
storage_class = STANDARD
EOF

# Test rclone connection
echo "🔍 Testing S3 connection..."
if ! rclone lsd s3:$AWS_BUCKET_NAME >/dev/null 2>&1; then
    echo "❌ Failed to connect to S3 bucket: $AWS_BUCKET_NAME"
    exit 1
fi
echo "✅ S3 connection successful"

# Define folder structures
SHARED_FOLDERS=("venv" ".comfyui")
COMFYUI_SHARED_FOLDERS=("models" "custom_nodes")

# Create all sync and utility scripts FIRST before any operations that depend on them
echo "📝 Creating sync and utility scripts..."
if ! bash /scripts/create_sync_scripts.sh; then
    echo "❌ Failed to create sync scripts"
    exit 1
fi

if ! bash /scripts/create_monitoring_scripts.sh; then
    echo "❌ Failed to create monitoring scripts"
    exit 1
fi

if ! bash /scripts/create_utility_scripts.sh; then
    echo "❌ Failed to create utility scripts"
    exit 1
fi

echo "✅ All scripts created successfully"

# Mount shared folders
echo "📁 Setting up shared folder mounts..."
mount_failures=()

# Function to perform mount with retry and validation
mount_with_validation() {
    local s3_path="$1"
    local mount_point="$2"
    local folder_name="$3"
    
    mkdir -p "$mount_point"
    
    if rclone lsd "$s3_path" >/dev/null 2>&1 || rclone ls "$s3_path" >/dev/null 2>&1; then
        echo "📁 Mounting $folder_name from S3..."
        
        rclone mount "$s3_path" "$mount_point" \
            --daemon \
            --allow-other \
            --allow-non-empty \
            --dir-cache-time 1m \
            --vfs-cache-mode writes \
            --vfs-cache-max-age 24h \
            --vfs-cache-max-size 1G \
            --buffer-size 64M \
            --timeout 30s \
            --retries 3 \
            --log-level ERROR
        
        sleep 3
        
        if mountpoint -q "$mount_point" && timeout 10 ls "$mount_point" >/dev/null 2>&1; then
            echo "✅ Successfully mounted $folder_name"
            return 0
        else
            echo "❌ Failed to mount $folder_name"
            return 1
        fi
    else
        echo "📁 Creating empty folder: $folder_name"
        mkdir -p "$mount_point"
        return 0
    fi
}

# Mount main shared folders
for folder in "${SHARED_FOLDERS[@]}"; do
    mount_point="$NETWORK_VOLUME/$folder"
    s3_path="s3:$AWS_BUCKET_NAME/pod_sessions/shared/$folder"
    
    if ! mount_with_validation "$s3_path" "$mount_point" "$folder"; then
        mount_failures+=("shared:$folder")
    fi
done

# Mount ComfyUI shared subfolders
for folder in "${COMFYUI_SHARED_FOLDERS[@]}"; do
    mount_point="$NETWORK_VOLUME/ComfyUI/$folder"
    s3_path="s3:$AWS_BUCKET_NAME/pod_sessions/shared/ComfyUI/$folder"
    
    if ! mount_with_validation "$s3_path" "$mount_point" "ComfyUI/$folder"; then
        mount_failures+=("comfyui-shared:$folder")
    fi
done

# Check for critical mount failures
if [[ ${#mount_failures[@]} -gt 0 ]]; then
    echo "❌ CRITICAL ERROR: Failed to mount S3 folders: ${mount_failures[*]}"
    echo "Data integrity cannot be guaranteed without proper mounts."
    exit 1
fi

# Sync user-specific data from S3
echo "👤 Syncing user-specific data from S3..."
bash /scripts/sync_user_data_from_s3.sh

echo "✅ Rclone S3 setup completed successfully!"
