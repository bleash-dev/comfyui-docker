#!/bin/bash

echo "🔧 Setting up rclone S3 mounting..."

# Detect network volume location
NETWORK_VOLUME=""
if [ -d "/runpod-volume" ]; then
    NETWORK_VOLUME="/runpod-volume"
    echo "Network volume detected at /runpod-volume"
elif mountpoint -q /workspace 2>/dev/null; then
    NETWORK_VOLUME="/workspace"
    echo "Network volume detected at /workspace (mounted)"
elif [ -f "/workspace/.runpod_volume" ] || [ -w "/workspace" ]; then
    NETWORK_VOLUME="/workspace"
    echo "Using /workspace as persistent storage"
else
    echo "❌ No network volume detected! This container requires persistent storage."
    echo "Please ensure you have mounted a network volume at /workspace or /runpod-volume"
    exit 1
fi

# Export NETWORK_VOLUME for use in other scripts
export NETWORK_VOLUME

# Final FUSE verification before proceeding
echo "🔧 Final FUSE verification..."
if [ ! -c /dev/fuse ]; then
    echo "❌ CRITICAL: /dev/fuse not available - cannot proceed with S3 mounting"
    exit 1
fi

# Check if we can write to fuse.conf (indicates proper FUSE setup)
if [ ! -f /etc/fuse.conf ] || ! grep -q "user_allow_other" /etc/fuse.conf; then
    echo "⚠️ WARNING: FUSE configuration may not be optimal"
    echo "Adding user_allow_other to fuse.conf..."
    echo "user_allow_other" >> /etc/fuse.conf 2>/dev/null || true
fi

# Validate required environment variables
required_vars=("AWS_BUCKET_NAME" "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_REGION" "POD_USER_NAME" "POD_ID")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ Required environment variable $var is not set"
        if [ "$var" = "POD_ID" ]; then
            echo "POD_ID is required for pod-specific data isolation"
            echo "Without POD_ID, the sync system cannot safely identify pod-specific data"
            echo "Container startup ABORTED due to missing POD_ID."
        fi
        exit 1
    fi
done

echo "✅ Environment variables validated"
echo "Bucket: $AWS_BUCKET_NAME"
echo "Region: $AWS_REGION" 
echo "User: $POD_USER_NAME"
echo "Pod ID: $POD_ID"
echo "Network Volume: $NETWORK_VOLUME"

# Create rclone config directory
mkdir -p /root/.config/rclone

# Create rclone configuration
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

echo "✅ Rclone configuration created"

# Test rclone connection
echo "🔍 Testing S3 connection..."
if ! rclone lsd s3:$AWS_BUCKET_NAME >/dev/null 2>&1; then
    echo "❌ Failed to connect to S3 bucket: $AWS_BUCKET_NAME"
    echo "Please check your AWS credentials and bucket permissions"
    exit 1
fi
echo "✅ S3 connection successful"

# Define shared folders that should be mounted directly (main level)
# ComfyUI is NOT included here - it will be installed locally with mixed subfolders
SHARED_FOLDERS=(
    "venv"
    ".comfyui"
)

# Define ComfyUI-specific shared folders (these are within ComfyUI directory)
COMFYUI_SHARED_FOLDERS=(
    "models"
    "custom_nodes"
)

# Note: No COMFYUI_USER_FOLDERS - everything else in ComfyUI is user-specific

# Function to get user-specific folders from S3 (within ComfyUI)
get_user_s3_folders() {
    local folders=()
    
    # Get user-specific folders from ComfyUI directory in S3 (now pod-specific)
    if rclone lsd s3:$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/ComfyUI/ 2>/dev/null; then
        while IFS= read -r line; do
            if [[ $line =~ ^[[:space:]]*[-0-9]+[[:space:]]+[0-9-]+[[:space:]]+[0-9:]+[[:space:]]+(.+)$ ]]; then
                folder_name="${BASH_REMATCH[1]}"
                folders+=("$folder_name")
            fi
        done < <(rclone lsd s3:$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/ComfyUI/ 2>/dev/null)
    fi
    
    printf '%s\n' "${folders[@]}"
}

# Function to check if folder is in ComfyUI shared list
is_comfyui_shared_folder() {
    local folder="$1"
    for shared in "${COMFYUI_SHARED_FOLDERS[@]}"; do
        if [[ "$folder" == "$shared" ]]; then
            return 0
        fi
    done
    return 1
}

# Function to check if folder is in main shared list
is_shared_folder() {
    local folder="$1"
    for shared in "${SHARED_FOLDERS[@]}"; do
        if [[ "$folder" == "$shared" ]]; then
            return 0
        fi
    done
    return 1
}

# Function to perform mount with retry and validation
mount_with_validation() {
    local s3_path="$1"
    local mount_point="$2"
    local folder_name="$3"
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        echo "🔗 Mounting $s3_path to $mount_point (attempt $((retry_count + 1))/$max_retries)"
        
        # Clear any existing mount point
        if mountpoint -q "$mount_point" 2>/dev/null; then
            echo "⚠️ Unmounting existing mount at $mount_point"
            fusermount -u "$mount_point" 2>/dev/null || fusermount3 -u "$mount_point" 2>/dev/null || umount "$mount_point" 2>/dev/null || true
            sleep 2
        fi
        
        # Ensure mount point exists and is empty
        mkdir -p "$mount_point"
        
        # Attempt mount with enhanced FUSE options
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
            --low-level-retries 10 \
            --log-level ERROR \
            --fuse-flag allow_other \
            --fuse-flag allow_root
        
        # Wait for mount to establish
        sleep 3
        
        # Verify mount
        if mountpoint -q "$mount_point"; then
            # Additional verification - try to list contents with timeout
            if timeout 10 ls "$mount_point" >/dev/null 2>&1; then
                echo "✅ Successfully mounted and verified $folder_name"
                return 0
            else
                echo "❌ Mount point accessible but contents not listable for $folder_name"
                # Clean up failed mount
                fusermount -u "$mount_point" 2>/dev/null || fusermount3 -u "$mount_point" 2>/dev/null || umount "$mount_point" 2>/dev/null || true
            fi
        else
            echo "❌ Mount failed for $folder_name (attempt $((retry_count + 1)))"
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            echo "⏳ Retrying mount in 5 seconds..."
            sleep 5
        fi
    done
    
    echo "❌ All mount attempts failed for $folder_name"
    echo "🔧 FUSE troubleshooting:"
    echo "  - Check if container has --privileged or --device /dev/fuse"
    echo "  - Verify FUSE kernel modules are loaded on host"
    echo "  - Check container capabilities (SYS_ADMIN may be required)"
    return 1
}

# Create mount points and mount ONLY explicitly defined shared folders
echo "📁 Setting up main shared folder mounts..."
mount_failures=()

for folder in "${SHARED_FOLDERS[@]}"; do
    mount_point="$NETWORK_VOLUME/$folder"
    s3_path="s3:$AWS_BUCKET_NAME/pod_sessions/shared/$folder"
    
    # Create mount point
    mkdir -p "$mount_point"
    
    # Check if folder exists in S3
    if rclone lsd "$s3_path" >/dev/null 2>&1 || rclone ls "$s3_path" >/dev/null 2>&1; then
        echo "📁 Found predefined shared folder in S3: $folder"
        
        # Attempt mount with validation
        if ! mount_with_validation "$s3_path" "$mount_point" "$folder"; then
            echo "❌ CRITICAL: Failed to mount existing S3 folder: $folder"
            mount_failures+=("shared:$folder")
        fi
    else
        echo "📁 Creating empty shared folder: $folder (doesn't exist in S3 yet)"
        mkdir -p "$mount_point"
    fi
done

# Note: ComfyUI will be installed locally, then we'll mount/sync its subfolders
echo "📝 Note: ComfyUI will be installed locally to allow mixed shared/user subfolders"

# Mount ComfyUI shared subfolders
echo "📁 Setting up ComfyUI shared folder mounts..."
for folder in "${COMFYUI_SHARED_FOLDERS[@]}"; do
    mount_point="$NETWORK_VOLUME/ComfyUI/$folder"
    s3_path="s3:$AWS_BUCKET_NAME/pod_sessions/shared/ComfyUI/$folder"
    
    # Create mount point
    mkdir -p "$mount_point"
    
    # Check if folder exists in S3
    if rclone lsd "$s3_path" >/dev/null 2>&1 || rclone ls "$s3_path" >/dev/null 2>&1; then
        echo "📁 Found ComfyUI shared folder in S3: $folder"
        
        # Attempt mount with validation
        if ! mount_with_validation "$s3_path" "$mount_point" "ComfyUI/$folder"; then
            echo "❌ CRITICAL: Failed to mount existing ComfyUI S3 folder: $folder"
            mount_failures+=("comfyui-shared:$folder")
        fi
    else
        echo "📁 Creating empty ComfyUI shared folder: $folder (doesn't exist in S3 yet)"
        mkdir -p "$mount_point"
    fi
done

# Security notice: Only mount predefined shared folders
echo "🔒 Security: Only mounting predefined shared folders to prevent unauthorized access"

# Discover user-specific folders within ComfyUI directory
echo "🔍 Discovering user-specific ComfyUI folders in S3..."
discovered_user_folders=($(get_user_s3_folders))

# Check for mount failures and fail if any critical mounts failed
if [[ ${#mount_failures[@]} -gt 0 ]]; then
    echo ""
    echo "❌ CRITICAL ERROR: Failed to mount the following existing S3 folders:"
    for failure in "${mount_failures[@]}"; do
        echo "  - $failure"
    done
    echo ""
    echo "This indicates a serious issue with:"
    echo "  1. Network connectivity to S3"
    echo "  2. FUSE filesystem support"
    echo "  3. Mount permissions"
    echo "  4. S3 credentials or permissions"
    echo ""
    echo "Data integrity cannot be guaranteed without proper mounts."
    echo "Container startup FAILED."
    exit 1
fi

# Handle user-specific ComfyUI folders - sync from S3
echo "👤 Setting up user-specific ComfyUI folders for: $POD_USER_NAME"
sync_failures=()

if [[ ${#discovered_user_folders[@]} -gt 0 ]]; then
    echo "📁 Found user ComfyUI folders in S3:"
    for folder in "${discovered_user_folders[@]}"; do
        echo "  - ComfyUI/$folder"
    done
fi

# Process all discovered user ComfyUI folders
for folder in "${discovered_user_folders[@]}"; do
    local_path="$NETWORK_VOLUME/ComfyUI/$folder"
    s3_path="s3:$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/ComfyUI/$folder"
    
    # Skip if it's a shared ComfyUI folder (security check)
    if is_comfyui_shared_folder "$folder"; then
        echo "🔒 Security: Skipping ComfyUI/$folder (it's a predefined shared folder, should not be in user space)"
        continue
    fi
    
    # Create local directory
    mkdir -p "$local_path"
    
    echo "📥 Syncing user ComfyUI folder from S3: $folder"
    if ! rclone sync "$s3_path" "$local_path" --progress --retries 3; then
        echo "❌ CRITICAL: Failed to sync existing user ComfyUI folder from S3: $folder"
        sync_failures+=("user-comfyui:$folder")
    else
        echo "✅ Synced ComfyUI/$folder from S3"
    fi
done

# Remove the predefined user folders setup - we'll handle everything dynamically
echo "📁 Setting up dynamic user-specific ComfyUI content..."

# Sync ComfyUI root files if they exist in S3 (now pod-specific)
echo "📄 Syncing ComfyUI root files from S3..."
s3_root_files_path="s3:$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/ComfyUI/_root_files"
if rclone lsd "$s3_root_files_path" >/dev/null 2>&1 || rclone ls "$s3_root_files_path" >/dev/null 2>&1; then
    echo "📥 Found ComfyUI root files in S3, syncing..."
    # Create temp directory and sync from S3
    temp_root_dir="/tmp/comfyui_root_restore"
    mkdir -p "$temp_root_dir"
    
    if rclone sync "$s3_root_files_path" "$temp_root_dir" --progress --retries 3; then
        # Copy files to ComfyUI root (avoiding conflicts with shared content)
        for file in "$temp_root_dir"/*; do
            if [[ -f "$file" ]]; then
                filename=$(basename "$file")
                # Only restore if it doesn't exist or isn't a shared folder/critical file
                if [[ ! -e "$NETWORK_VOLUME/ComfyUI/$filename" ]] || [[ ! -d "$NETWORK_VOLUME/ComfyUI/$filename" ]]; then
                    cp "$file" "$NETWORK_VOLUME/ComfyUI/"
                    echo "✅ Restored ComfyUI root file: $filename"
                fi
            fi
        done
        echo "✅ ComfyUI root files restored from S3"
    else
        echo "❌ WARNING: Failed to sync ComfyUI root files from S3"
    fi
    
    # Cleanup
    rm -rf "$temp_root_dir"
else
    echo "📁 No ComfyUI root files found in S3"
fi

# Check for mount failures and fail if any critical mounts failed
if [[ ${#mount_failures[@]} -gt 0 ]]; then
    echo ""
    echo "❌ CRITICAL ERROR: Failed to mount the following existing S3 folders:"
    for failure in "${mount_failures[@]}"; do
        echo "  - $failure"
    done
    echo ""
    echo "This indicates a serious issue with:"
    echo "  1. Network connectivity to S3"
    echo "  2. FUSE filesystem support"
    echo "  3. Mount permissions"
    echo "  4. S3 credentials or permissions"
    echo ""
    echo "Data integrity cannot be guaranteed without proper mounts."
    echo "Container startup FAILED."
    exit 1
fi

# Create dynamic user data sync script
cat > "$NETWORK_VOLUME/scripts/sync_user_data.sh" << EOF
#!/bin/bash
# Script to sync ALL user-specific data to S3 (everything not in shared folders)

echo "🔄 Syncing user data to S3..."
SYNC_LOG="$NETWORK_VOLUME/.sync_log"
echo "\$(date): Starting dynamic sync" >> "\$SYNC_LOG"

# Define main shared folders (same as setup script)
SHARED_FOLDERS=(
    "venv"
    ".comfyui"
)

# Define ComfyUI shared folders (only these are shared within ComfyUI)
COMFYUI_SHARED_FOLDERS=(
    "models"
    "custom_nodes"
)

# Function to check if folder is shared (main level)
is_shared_folder() {
    local folder="\$1"
    for shared in "\${SHARED_FOLDERS[@]}"; do
        if [[ "\$folder" == "\$shared" ]]; then
            return 0
        fi
    done
    return 1
}

# Function to check if ComfyUI folder is shared
is_comfyui_shared() {
    local item="\$1"
    for shared in "\${COMFYUI_SHARED_FOLDERS[@]}"; do
        if [[ "\$item" == "\$shared" ]]; then
            return 0
        fi
    done
    return 1
}

# Sync ALL ComfyUI content except shared folders
echo "📁 Syncing user-specific ComfyUI content..."
if [[ -d "$NETWORK_VOLUME/ComfyUI" ]]; then
    # Get all folders in ComfyUI that are NOT shared
    comfyui_user_folders=()
    for dir in $NETWORK_VOLUME/ComfyUI/*/; do
        if [[ -d "\$dir" ]]; then
            folder_name=\$(basename "\$dir")
            # Include if it's NOT a shared ComfyUI folder
            if ! is_comfyui_shared "\$folder_name"; then
                comfyui_user_folders+=("\$folder_name")
            fi
        fi
    done

    echo "📁 Found \${#comfyui_user_folders[@]} user-specific ComfyUI folders"

    # Sync each user ComfyUI folder
    for folder in "\${comfyui_user_folders[@]}"; do
        local_path="$NETWORK_VOLUME/ComfyUI/\$folder"
        s3_path="s3:$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/ComfyUI/\$folder"
        
        if [[ -d "\$local_path" ]]; then
            echo "📤 Syncing ComfyUI folder: \$folder"
            if rclone sync "\$local_path" "\$s3_path" --progress; then
                echo "✅ Synced ComfyUI/\$folder"
                echo "\$(date): Successfully synced ComfyUI/\$folder" >> "\$SYNC_LOG"
            else
                echo "❌ Failed to sync ComfyUI/\$folder"
                echo "\$(date): Failed to sync ComfyUI/\$folder" >> "\$SYNC_LOG"
            fi
        fi
    done

    # Now sync ALL loose files in ComfyUI root (excluding shared folders)
    echo "📄 Syncing ComfyUI root files..."
    comfyui_user_files=()
    for item in $NETWORK_VOLUME/ComfyUI/*; do
        if [[ -f "\$item" ]]; then
            filename=\$(basename "\$item")
            # All files in ComfyUI root are user-specific
            comfyui_user_files+=("\$filename")
        fi
    done

    if [[ \${#comfyui_user_files[@]} -gt 0 ]]; then
        echo "📤 Found \${#comfyui_user_files[@]} user-specific files in ComfyUI root"
        
        # Create temporary directory for ComfyUI root files
        temp_dir="/tmp/comfyui_root_sync"
        mkdir -p "\$temp_dir"
        
        # Copy ComfyUI root files to temp directory
        for file in "\${comfyui_user_files[@]}"; do
            if [[ -f "$NETWORK_VOLUME/ComfyUI/\$file" ]]; then
                cp "$NETWORK_VOLUME/ComfyUI/\$file" "\$temp_dir/"
            fi
        done
        
        # Sync temp directory to S3 (now pod-specific)
        s3_path="s3:$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/ComfyUI/_root_files"
        if rclone sync "\$temp_dir" "\$s3_path" --progress; then
            echo "✅ Synced ComfyUI root files"
            echo "\$(date): Successfully synced ComfyUI root files" >> "\$SYNC_LOG"
        else
            echo "❌ Failed to sync ComfyUI root files"
            echo "\$(date): Failed to sync ComfyUI root files" >> "\$SYNC_LOG"
        fi
        
        # Cleanup
        rm -rf "\$temp_dir"
    else
        echo "📁 No user-specific files found in ComfyUI root"
    fi
    
    # Summary of what was treated as user-specific
    echo "📊 ComfyUI Content Summary:"
    echo "  🔒 Shared folders: \${COMFYUI_SHARED_FOLDERS[*]}"
    echo "  👤 User folders: \${comfyui_user_folders[*]}"
    echo "  📄 User files: \${#comfyui_user_files[@]} files"
else
    echo "⚠️ ComfyUI directory not found at $NETWORK_VOLUME/ComfyUI"
fi

# Sync other user folders outside ComfyUI (everything except main shared folders)
echo "📁 Syncing other user-specific folders..."
user_folders=()
for dir in $NETWORK_VOLUME/*/; do
    if [[ -d "\$dir" ]]; then
        folder_name=\$(basename "\$dir")
        # Skip main shared folders and ComfyUI (already handled above)
        if ! is_shared_folder "\$folder_name" && [[ "\$folder_name" != "ComfyUI" ]]; then
            user_folders+=("\$folder_name")
        fi
    fi
done

echo "📁 Found \${#user_folders[@]} other user-specific folders"

# Sync each other user folder
for folder in "\${user_folders[@]}"; do
    local_path="$NETWORK_VOLUME/\$folder"
    s3_path="s3:$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/\$folder"
    
    if [[ -d "\$local_path" ]] && [[ "\$(ls -A "\$local_path" 2>/dev/null)" ]]; then
        echo "📤 Syncing \$folder to S3..."
        if rclone sync "\$local_path" "\$s3_path" --progress; then
            echo "✅ Synced \$folder"
            echo "\$(date): Successfully synced \$folder" >> "\$SYNC_LOG"
        else
            echo "❌ Failed to sync \$folder"
            echo "\$(date): Failed to sync \$folder" >> "\$SYNC_LOG"
        fi
    else
        echo "📁 No data to sync in \$folder (empty or doesn't exist)"
    fi
done

# Also sync any loose files in network volume root (user-specific)
echo "📄 Checking for loose files in network volume root..."
loose_files=()
for item in $NETWORK_VOLUME/*; do
    if [[ -f "\$item" ]]; then
        filename=\$(basename "\$item")
        # Skip log files and system files
        if [[ ! "\$filename" =~ ^\.(sync_log|activity_log) ]] && [[ ! "\$filename" =~ \.sh$ ]]; then
            loose_files+=("\$filename")
        fi
    fi
done

if [[ \${#loose_files[@]} -gt 0 ]]; then
    echo "📤 Syncing \${#loose_files[@]} loose files to S3..."
    s3_path="s3:$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/_workspace_root"
    
    # Create temporary directory for loose files
    temp_dir="/tmp/workspace_root_sync"
    mkdir -p "\$temp_dir"
    
    # Copy loose files to temp directory
    for file in "\${loose_files[@]}"; do
        cp "$NETWORK_VOLUME/\$file" "\$temp_dir/"
    done
    
    # Sync temp directory to S3 (now pod-specific)
    if rclone sync "\$temp_dir" "\$s3_path" --progress; then
        echo "✅ Synced loose files"
        echo "\$(date): Successfully synced loose files" >> "\$SYNC_LOG"
    else
        echo "❌ Failed to sync loose files"
        echo "\$(date): Failed to sync loose files" >> "\$SYNC_LOG"
    fi
    
    # Cleanup
    rm -rf "\$temp_dir"
fi

echo "🎉 User data sync completed!"
echo "\$(date): Dynamic sync completed" >> "\$SYNC_LOG"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_user_data.sh"

# Create enhanced sync script that also handles new folders
cat > "$NETWORK_VOLUME/scripts/sync_new_folders.sh" << EOF
#!/bin/bash
# Script to detect and sync new folders created during runtime

echo "🔍 Checking for new user folders..."

# Define main shared folders (same as setup script)
SHARED_FOLDERS=(
    "venv"
    ".comfyui"
)

# Define ComfyUI shared folders (only these are shared within ComfyUI)
COMFYUI_SHARED_FOLDERS=(
    "models"
    "custom_nodes"
)

# Function to check if folder is shared (main level)
is_shared_folder() {
    local folder="\$1"
    for shared in "\${SHARED_FOLDERS[@]}"; do
        if [[ "\$folder" == "\$shared" ]]; then
            return 0
        fi
    done
    return 1
}

# Function to check if ComfyUI folder is shared
is_comfyui_shared_folder() {
    local folder="\$1"
    for shared in "\${COMFYUI_SHARED_FOLDERS[@]}"; do
        if [[ "\$folder" == "\$shared" ]]; then
            return 0
        fi
    done
    return 1
}

# Track last scan file
LAST_SCAN_FILE="$NETWORK_VOLUME/.last_folder_scan"
current_time=\$(date +%s)

# Get folders that were modified since last scan (main level)
new_or_modified_folders=()
for dir in $NETWORK_VOLUME/*/; do
    if [[ -d "\$dir" ]]; then
        folder_name=\$(basename "\$dir")
        
        # Skip main shared folders and ComfyUI (will be handled separately)
        if is_shared_folder "\$folder_name" || [[ "\$folder_name" == "ComfyUI" ]]; then
            continue
        fi
        
        # Check if folder is new or modified
        if [[ ! -f "\$LAST_SCAN_FILE" ]] || [[ "\$dir" -nt "\$LAST_SCAN_FILE" ]]; then
            new_or_modified_folders+=("\$folder_name")
        fi
    fi
done

# Get ComfyUI folders that were modified since last scan
new_or_modified_comfyui_folders=()
if [[ -d "$NETWORK_VOLUME/ComfyUI" ]]; then
    for dir in $NETWORK_VOLUME/ComfyUI/*/; do
        if [[ -d "\$dir" ]]; then
            folder_name=\$(basename "\$dir")
            
            # Skip ComfyUI shared folders
            if is_comfyui_shared_folder "\$folder_name"; then
                continue
            fi
            
            # Check if folder is new or modified
            if [[ ! -f "\$LAST_SCAN_FILE" ]] || [[ "\$dir" -nt "\$LAST_SCAN_FILE" ]]; then
                new_or_modified_comfyui_folders+=("\$folder_name")
            fi
        fi
    done
    
    # Also check for modified files in ComfyUI root
    comfyui_root_modified=false
    for item in $NETWORK_VOLUME/ComfyUI/*; do
        if [[ -f "\$item" ]]; then
            if [[ ! -f "\$LAST_SCAN_FILE" ]] || [[ "\$item" -nt "\$LAST_SCAN_FILE" ]]; then
                comfyui_root_modified=true
                break
            fi
        fi
    done
fi

# Report findings
total_changes=\$((${#new_or_modified_folders[@]} + ${#new_or_modified_comfyui_folders[@]}))
if [[ \$comfyui_root_modified == true ]]; then
    total_changes=\$((total_changes + 1))
fi

if [[ \$total_changes -gt 0 ]]; then
    echo "📁 Found changes since last scan:"
    
    if [[ \${#new_or_modified_folders[@]} -gt 0 ]]; then
        echo "  📂 Modified main folders: \${new_or_modified_folders[*]}"
    fi
    
    if [[ \${#new_or_modified_comfyui_folders[@]} -gt 0 ]]; then
        echo "  📂 Modified ComfyUI folders: \${new_or_modified_comfyui_folders[*]}"
    fi
    
    if [[ \$comfyui_root_modified == true ]]; then
        echo "  📄 ComfyUI root files modified"
    fi
    
    # Sync new/modified content immediately
    echo "🚀 Syncing modified content..."
    $NETWORK_VOLUME/scripts/sync_user_data.sh
else
    echo "✅ No new or modified user content detected"
fi

# Update last scan timestamp
touch "\$LAST_SCAN_FILE"

# Summary
echo "📊 Scan Summary:"
echo "  🔒 Main shared folders (ignored): \${SHARED_FOLDERS[*]}"
echo "  🔒 ComfyUI shared folders (ignored): \${COMFYUI_SHARED_FOLDERS[*]}"
echo "  👤 Changes detected: \$total_changes"
echo "  ⏰ Last scan: \$(date)"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_new_folders.sh"

# Create periodic sync service
cat > "$NETWORK_VOLUME/scripts/setup_periodic_sync.sh" << 'EOF'
#!/bin/bash
# Setup periodic sync service

echo "⏰ Setting up periodic sync service..."

# Create systemd-like service using cron
cat > /workspace/sync_cron_job << 'CRON_EOF'
# Sync user data every 5 minutes
*/5 * * * * /workspace/sync_user_data.sh >> /workspace/.sync_log 2>&1

# Sync user data every hour (more robust)
0 * * * * /workspace/sync_user_data.sh >> /workspace/.sync_log 2>&1
CRON_EOF

# Install cron job if cron is available
if command -v crontab >/dev/null 2>&1; then
    crontab /workspace/sync_cron_job
    echo "✅ Periodic sync scheduled via cron"
else
    echo "⚠️ Cron not available, will use background sync process"
fi

# Create background sync daemon
cat > "$NETWORK_VOLUME/scripts/sync_daemon.sh" << 'EOF'
#!/bin/bash
# Background sync daemon

SYNC_INTERVAL=${SYNC_INTERVAL:-300}  # 5 minutes default
ACTIVITY_TIMEOUT=${ACTIVITY_TIMEOUT:-1800}  # 30 minutes default

echo "🔄 Starting sync daemon (interval: ${SYNC_INTERVAL}s, inactivity timeout: ${ACTIVITY_TIMEOUT}s)"

last_activity_file="$NETWORK_VOLUME/.last_activity"
touch "$last_activity_file"

# Function to detect activity
detect_activity() {
    # Check for file modifications in user directories
    find $NETWORK_VOLUME/ComfyUI -type f -newer "$last_activity_file" 2>/dev/null | head -1
}

# Function to update activity timestamp
update_activity() {
    touch "$last_activity_file"
    echo "$(date): Activity detected" >> $NETWORK_VOLUME/.activity_log
}

# Function to check inactivity and sync
check_inactivity_and_sync() {
    local current_time=$(date +%s)
    local last_activity=$(stat -c %Y "$last_activity_file" 2>/dev/null || echo 0)
    local inactive_duration=$((current_time - last_activity))
    
    if [ $inactive_duration -gt $ACTIVITY_TIMEOUT ]; then
        echo "🔄 Inactivity detected (${inactive_duration}s), performing sync..."
        $NETWORK_VOLUME/scripts/sync_user_data.sh
        update_activity  # Reset activity timer after sync
    fi
}

# Main daemon loop
while true; do
    # Check for activity
    if [ -n "$(detect_activity)" ]; then
        update_activity
    fi
    
    # Check for inactivity and sync if needed
    check_inactivity_and_sync
    
    # Regular periodic sync
    $NETWORK_VOLUME/scripts/sync_user_data.sh
    
    sleep $SYNC_INTERVAL
done
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_daemon.sh"

# Create enhanced graceful shutdown script with log sync
cat > "$NETWORK_VOLUME/scripts/graceful_shutdown.sh" << 'EOF'
#!/bin/bash
# Graceful shutdown with final sync and log collection

echo "🛑 Graceful shutdown initiated at $(date)"

# Stop all background processes
echo "🔄 Stopping background processes..."
pkill -f "$NETWORK_VOLUME/scripts/sync_daemon.sh" 2>/dev/null || true
pkill -f "$NETWORK_VOLUME/scripts/sync_new_folders.sh" 2>/dev/null || true
pkill -f "$NETWORK_VOLUME/scripts/log_monitor.sh" 2>/dev/null || true
pkill -f "$NETWORK_VOLUME/scripts/error_detector.sh" 2>/dev/null || true

# Perform final log sync FIRST (before other operations)
echo "📤 Performing final log sync..."
if [ -f "$NETWORK_VOLUME/scripts/sync_logs.sh" ]; then
    "$NETWORK_VOLUME/scripts/sync_logs.sh"
fi

# Perform final user data sync
echo "🔄 Performing final user data sync..."
if [ -f "$NETWORK_VOLUME/scripts/sync_user_data.sh" ]; then
    "$NETWORK_VOLUME/scripts/sync_user_data.sh"
fi

# Wait for any pending uploads
sleep 5

# Unmount all rclone filesystems with multiple methods
echo "🔌 Unmounting rclone filesystems..."
for mount_point in "$NETWORK_VOLUME/venv" "$NETWORK_VOLUME/.comfyui" "$NETWORK_VOLUME/ComfyUI/models" "$NETWORK_VOLUME/ComfyUI/custom_nodes"; do
    if mountpoint -q "$mount_point" 2>/dev/null; then
        echo "📤 Unmounting $mount_point"
        fusermount -u "$mount_point" 2>/dev/null || \
        fusermount3 -u "$mount_point" 2>/dev/null || \
        umount "$mount_point" 2>/dev/null || \
        umount -f "$mount_point" 2>/dev/null || \
        umount -l "$mount_point" 2>/dev/null || true
    fi
done

# Kill any remaining rclone processes
pkill -f "rclone mount" 2>/dev/null || true

# Also kill any folder detection processes (using full path pattern)
pkill -f "$NETWORK_VOLUME/scripts/sync_new_folders.sh" 2>/dev/null || true

echo "✅ Graceful shutdown completed at $(date)"
echo "$(date): Graceful shutdown completed" >> "$NETWORK_VOLUME/.sync_log"

# Final log sync after shutdown
"$NETWORK_VOLUME/scripts/sync_logs.sh" 2>/dev/null || true
EOF

chmod +x "$NETWORK_VOLUME/scripts/graceful_shutdown.sh"

# Create signal handler script
cat > "$NETWORK_VOLUME/scripts/signal_handler.sh" << 'EOF'
#!/bin/bash
# Signal handler for graceful shutdown

handle_signal() {
    echo "📢 Received shutdown signal, initiating graceful shutdown..."
    $NETWORK_VOLUME/scripts/graceful_shutdown.sh
    exit 0
}

# Trap signals
trap handle_signal SIGTERM SIGINT SIGQUIT

# Keep script running to handle signals
while true; do
    sleep 1
done
EOF

chmod +x "$NETWORK_VOLUME/scripts/signal_handler.sh"

# Create comprehensive custom node installation monitor
cat > "$NETWORK_VOLUME/scripts/monitor_custom_nodes.sh" << 'EOF'
#!/bin/bash
# Monitor custom node installations and activities

CUSTOM_NODES_DIR="$NETWORK_VOLUME/ComfyUI/custom_nodes"
CUSTOM_NODES_LOG="$NETWORK_VOLUME/ComfyUI/custom_nodes_activity.log"
INSTALLATION_LOG="$NETWORK_VOLUME/ComfyUI/node_installations.log"

echo "🔍 Starting custom node installation monitor..."
echo "$(date): Custom node monitor started" >> "$CUSTOM_NODES_LOG"

# Function to log custom node activity
log_node_activity() {
    local message="$1"
    echo "$(date): $message" >> "$CUSTOM_NODES_LOG"
    echo "$(date): $message" >> "$INSTALLATION_LOG"
    echo "$message"
}

# Function to monitor git operations in custom_nodes directory
monitor_git_operations() {
    # Monitor for git clone operations
    if command -v inotifywait >/dev/null 2>&1; then
        inotifywait -m -r "$CUSTOM_NODES_DIR" -e create,moved_to,modify --format '%w%f %e' 2>/dev/null | while read file event; do
            # Check if it's a git-related change
            if [[ "$file" == *".git"* ]] || [[ "$event" == "CREATE,ISDIR" ]]; then
                log_node_activity "📦 Git activity detected: $file ($event)"
                
                # Trigger immediate log sync for new installations
                if [[ "$event" == "CREATE,ISDIR" && -d "$file" ]]; then
                    log_node_activity "🆕 New custom node directory created: $(basename "$file")"
                    $NETWORK_VOLUME/scripts/sync_logs.sh &
                fi
            fi
        done &
    fi
}

# Function to scan for new custom nodes
scan_for_new_nodes() {
    local known_nodes_file="$NETWORK_VOLUME/.known_custom_nodes"
    
    # Create list of current nodes
    current_nodes=($(find "$CUSTOM_NODES_DIR" -maxdepth 1 -type d -name "*" ! -name "custom_nodes" | xargs -I {} basename {}))
    
    # Load previously known nodes
    if [[ -f "$known_nodes_file" ]]; then
        mapfile -t known_nodes < "$known_nodes_file"
    else
        known_nodes=()
    fi
    
    # Find new nodes
    for node in "${current_nodes[@]}"; do
        if [[ ! " ${known_nodes[*]} " =~ " ${node} " ]]; then
            log_node_activity "🆕 NEW CUSTOM NODE DETECTED: $node"
            
            # Check for installation logs in the node directory
            node_dir="$CUSTOM_NODES_DIR/$node"
            if [[ -d "$node_dir" ]]; then
                # Look for common installation artifacts
                if [[ -f "$node_dir/requirements.txt" ]]; then
                    log_node_activity "📋 Found requirements.txt in $node"
                    cat "$node_dir/requirements.txt" >> "$INSTALLATION_LOG"
                fi
                
                if [[ -f "$node_dir/install.py" ]]; then
                    log_node_activity "🐍 Found install.py in $node"
                fi
                
                if [[ -f "$node_dir/package.json" ]]; then
                    log_node_activity "📦 Found package.json in $node"
                fi
                
                # Check git info if available
                if [[ -d "$node_dir/.git" ]]; then
                    cd "$node_dir"
                    if git_url=$(git config --get remote.origin.url 2>/dev/null); then
                        log_node_activity "🔗 Git URL for $node: $git_url"
                    fi
                    if git_commit=$(git rev-parse HEAD 2>/dev/null); then
                        log_node_activity "🔖 Git commit for $node: $git_commit"
                    fi
                fi
            fi
            
            # Trigger immediate sync for new installations
            $NETWORK_VOLUME/scripts/sync_logs.sh &
        fi
    done
    
    # Update known nodes list
    printf "%s\n" "${current_nodes[@]}" > "$known_nodes_file"
}

# Main monitoring loop
while true; do
    scan_for_new_nodes
    sleep 30  # Check every 30 seconds
done
EOF

chmod +x "$NETWORK_VOLUME/scripts/monitor_custom_nodes.sh"

# Create ComfyUI Manager activity interceptor
cat > "$NETWORK_VOLUME/scripts/intercept_manager_logs.sh" << 'EOF'
#!/bin/bash
# Intercept and capture ComfyUI Manager installation logs

MANAGER_LOG="$NETWORK_VOLUME/ComfyUI/manager_activity.log"
COMFYUI_LOG="$NETWORK_VOLUME/ComfyUI/comfyui.log"

echo "🔍 Starting ComfyUI Manager log interceptor..."

# Function to parse and extract manager activities from ComfyUI logs
parse_manager_activities() {
    if [[ -f "$COMFYUI_LOG" ]]; then
        # Monitor for Manager installation activities
        tail -f "$COMFYUI_LOG" | while read line; do
            # Check for Manager installation activities
            if echo "$line" | grep -i -E "(installing|install|downloading|download|cloning|clone|manager|custom.node)" >/dev/null; then
                echo "$(date): MANAGER ACTIVITY: $line" >> "$MANAGER_LOG"
                
                # Trigger immediate log sync for installations
                if echo "$line" | grep -i -E "(installing|cloning|downloading)" >/dev/null; then
                    echo "$(date): Installation activity detected, triggering log sync" >> "$MANAGER_LOG"
                    $NETWORK_VOLUME/scripts/sync_logs.sh &
                fi
            fi
        done &
    fi
}

# Monitor ComfyUI log for manager activities
parse_manager_activities

# Keep the script running
while true; do
    sleep 60
done
EOF

chmod +x "$NETWORK_VOLUME/scripts/intercept_manager_logs.sh"

# Enhanced log sync script to include custom node logs
cat > "$NETWORK_VOLUME/scripts/sync_logs.sh" << 'EOF'
#!/bin/bash
# Script to sync all logs to S3 for debugging (enhanced for custom nodes)

LOG_DATE=$(date +%Y-%m-%d)
LOG_HOUR=$(date +%H)
S3_LOG_BASE="s3:$AWS_BUCKET_NAME/pod_logs/$POD_USER_NAME/logs/$LOG_DATE"

echo "🔄 Syncing logs to S3: $S3_LOG_BASE"

# Create local log collection directory
LOCAL_LOG_DIR="/tmp/log_collection"
mkdir -p "$LOCAL_LOG_DIR"

# Function to safely copy log file
copy_log_if_exists() {
    local source="$1"
    local dest_name="$2"
    
    if [[ -f "$source" ]]; then
        cp "$source" "$LOCAL_LOG_DIR/${dest_name}"
        echo "📄 Collected: $dest_name"
    else
        echo "⚠️ Log not found: $source"
    fi
}

# Collect all logs
echo "📂 Collecting logs..."

# Startup and system logs
copy_log_if_exists "/var/log/startup.log" "startup.log"
copy_log_if_exists "$NETWORK_VOLUME/.startup.log" "network_startup.log"

# Sync daemon logs
copy_log_if_exists "$NETWORK_VOLUME/.sync_daemon.log" "sync_daemon.log"
copy_log_if_exists "$NETWORK_VOLUME/.folder_detection.log" "folder_detection.log"
copy_log_if_exists "$NETWORK_VOLUME/.signal_handler.log" "signal_handler.log"

# ComfyUI logs
copy_log_if_exists "$NETWORK_VOLUME/ComfyUI/comfyui.log" "comfyui.log"
copy_log_if_exists "$NETWORK_VOLUME/ComfyUI/comfyui_error.log" "comfyui_error.log"
copy_log_if_exists "$NETWORK_VOLUME/.comfyui/logs/comfyui.log" "comfyui_config.log"

# Custom Node logs (NEW)
copy_log_if_exists "$NETWORK_VOLUME/ComfyUI/custom_nodes_activity.log" "custom_nodes_activity.log"
copy_log_if_exists "$NETWORK_VOLUME/ComfyUI/node_installations.log" "node_installations.log"
copy_log_if_exists "$NETWORK_VOLUME/ComfyUI/manager_activity.log" "manager_activity.log"

# Activity and sync logs
copy_log_if_exists "$NETWORK_VOLUME/.sync_log" "sync_operations.log"
copy_log_if_exists "$NETWORK_VOLUME/.activity_log" "activity.log"
copy_log_if_exists "$NETWORK_VOLUME/.error_alerts.log" "error_alerts.log"

# Monitor logs
copy_log_if_exists "$NETWORK_VOLUME/.log_monitor.log" "log_monitor.log"
copy_log_if_exists "$NETWORK_VOLUME/.error_detector.log" "error_detector.log"

# Custom node specific logs
echo "📦 Collecting custom node specific logs..."
CUSTOM_NODES_DIR="$NETWORK_VOLUME/ComfyUI/custom_nodes"
if [[ -d "$CUSTOM_NODES_DIR" ]]; then
    # Create custom nodes log directory
    mkdir -p "$LOCAL_LOG_DIR/custom_nodes"
    
    # Collect individual node logs
    for node_dir in "$CUSTOM_NODES_DIR"/*; do
        if [[ -d "$node_dir" ]]; then
            node_name=$(basename "$node_dir")
            
            # Look for common log files in each custom node
            for log_file in "$node_dir"/*.log "$node_dir"/logs/*.log "$node_dir"/install.log; do
                if [[ -f "$log_file" ]]; then
                    log_basename=$(basename "$log_file")
                    cp "$log_file" "$LOCAL_LOG_DIR/custom_nodes/${node_name}_${log_basename}"
                    echo "📄 Collected custom node log: ${node_name}/${log_basename}"
                fi
            done
            
            # Collect requirements and package info
            if [[ -f "$node_dir/requirements.txt" ]]; then
                cp "$node_dir/requirements.txt" "$LOCAL_LOG_DIR/custom_nodes/${node_name}_requirements.txt"
            fi
            
            if [[ -f "$node_dir/package.json" ]]; then
                cp "$node_dir/package.json" "$LOCAL_LOG_DIR/custom_nodes/${node_name}_package.json"
            fi
        fi
    done
    
    # Create custom nodes summary
    cat > "$LOCAL_LOG_DIR/custom_nodes_summary.txt" << SUMMARY
Custom Nodes Summary - $(date)
================================

Installed Custom Nodes:
$(find "$CUSTOM_NODES_DIR" -maxdepth 1 -type d -name "*" ! -name "custom_nodes" | xargs -I {} basename {} | sort)

Custom Nodes with Git Info:
$(for dir in "$CUSTOM_NODES_DIR"/*; do
    if [[ -d "$dir/.git" ]]; then
        node_name=$(basename "$dir")
        cd "$dir"
        echo "$node_name: $(git config --get remote.origin.url 2>/dev/null || echo 'No remote URL') ($(git rev-parse --short HEAD 2>/dev/null || echo 'No commit'))"
    fi
done)

Total Custom Nodes: $(find "$CUSTOM_NODES_DIR" -maxdepth 1 -type d | wc -l | xargs)
SUMMARY
fi

# Docker and system logs (if accessible)
if command -v journalctl >/dev/null 2>&1; then
    journalctl --since="1 hour ago" --no-pager > "$LOCAL_LOG_DIR/system_journal.log" 2>/dev/null || true
fi

# Process information
ps aux > "$LOCAL_LOG_DIR/running_processes.log" 2>/dev/null || true
df -h > "$LOCAL_LOG_DIR/disk_usage.log" 2>/dev/null || true
mount | grep rclone > "$LOCAL_LOG_DIR/rclone_mounts.log" 2>/dev/null || true

# Environment information
cat > "$LOCAL_LOG_DIR/environment.log" << ENVEOF
Timestamp: $(date)
Pod User: $POD_USER_NAME
Network Volume: $NETWORK_VOLUME
ComfyUI Venv: $COMFYUI_VENV
Jupyter Venv: $JUPYTER_VENV
GPU Info: $(nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader,nounits 2>/dev/null || echo "No GPU info available")
Python Version: $(python3 --version 2>/dev/null || echo "Python not available")
ComfyUI Version: $(cd "$NETWORK_VOLUME/ComfyUI" && git rev-parse --short HEAD 2>/dev/null || echo "Unknown")
ENVEOF

# Create a summary of log files
ls -la "$LOCAL_LOG_DIR" > "$LOCAL_LOG_DIR/log_summary.txt"
if [[ -d "$LOCAL_LOG_DIR/custom_nodes" ]]; then
    echo -e "\nCustom Nodes Logs:" >> "$LOCAL_LOG_DIR/log_summary.txt"
    ls -la "$LOCAL_LOG_DIR/custom_nodes" >> "$LOCAL_LOG_DIR/log_summary.txt"
fi

# Sync to S3 with timestamp
TIMESTAMP=$(date +%H-%M-%S)
S3_LOG_PATH="$S3_LOG_BASE/$TIMESTAMP"

echo "📤 Uploading logs to: $S3_LOG_PATH"
if rclone sync "$LOCAL_LOG_DIR" "$S3_LOG_PATH" --progress; then
    echo "✅ Logs synced successfully to S3"
    echo "$(date): Logs synced to $S3_LOG_PATH" >> "$NETWORK_VOLUME/.sync_log"
else
    echo "❌ Failed to sync logs to S3"
    echo "$(date): Failed to sync logs to $S3_LOG_PATH" >> "$NETWORK_VOLUME/.sync_log"
fi

# Cleanup
rm -rf "$LOCAL_LOG_DIR"

echo "🎉 Log sync completed!"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_logs.sh"

# Create continuous log monitoring script
cat > "$NETWORK_VOLUME/scripts/log_monitor.sh" << 'EOF'
#!/bin/bash
# Continuous log monitoring and syncing

LOG_SYNC_INTERVAL=${LOG_SYNC_INTERVAL:-180}  # 3 minutes default
STARTUP_LOG_FILE="$NETWORK_VOLUME/.startup.log"

echo "🔍 Starting log monitor (sync interval: ${LOG_SYNC_INTERVAL}s)"
echo "$(date): Log monitor started" >> "$NETWORK_VOLUME/.activity_log"

# Function to capture startup logs
capture_startup_logs() {
    echo "📝 Capturing startup sequence..."
    
    # Redirect all output to startup log
    exec 1> >(tee -a "$STARTUP_LOG_FILE")
    exec 2> >(tee -a "$STARTUP_LOG_FILE" >&2)
    
    echo "=== Startup Log - $(date) ===" >> "$STARTUP_LOG_FILE"
}

# Function to monitor ComfyUI logs
monitor_comfyui_logs() {
    local comfyui_log="$NETWORK_VOLUME/ComfyUI/comfyui.log"
    local last_position_file="$NETWORK_VOLUME/.comfyui_log_position"
    
    if [[ -f "$comfyui_log" ]]; then
        # Get last read position
        local last_pos=0
        if [[ -f "$last_position_file" ]]; then
            last_pos=$(cat "$last_position_file")
        fi
        
        # Read new content
        local current_size=$(stat -c%s "$comfyui_log" 2>/dev/null || echo "0")
        if [[ $current_size -gt $last_pos ]]; then
            echo "📄 New ComfyUI log content detected"
            
            # Extract new content and append to activity log
            tail -c +$((last_pos + 1)) "$comfyui_log" >> "$NETWORK_VOLUME/.activity_log"
            
            # Update position
            echo "$current_size" > "$last_position_file"
            
            # Trigger immediate log sync if there are errors
            if tail -c +$((last_pos + 1)) "$comfyui_log" | grep -i "error\|exception\|failed\|critical" >/dev/null; then
                echo "🚨 Error detected in ComfyUI logs, triggering immediate sync"
                $NETWORK_VOLUME/scripts/sync_logs.sh
            fi
        fi
    fi
}

# Main monitoring loop
while true; do
    # Monitor ComfyUI logs for new content
    monitor_comfyui_logs
    
    # Regular log sync
    $NETWORK_VOLUME/scripts/sync_logs.sh
    
    # Wait for next cycle
    sleep $LOG_SYNC_INTERVAL
done
EOF

chmod +x "$NETWORK_VOLUME/scripts/log_monitor.sh"

# Create error detection and immediate sync script
cat > "$NETWORK_VOLUME/scripts/error_detector.sh" << 'EOF'
#!/bin/bash
# Detect critical errors and trigger immediate log sync

ERROR_PATTERNS=(
    "CRITICAL"
    "FATAL"
    "Exception"
    "Traceback"
    "Error:"
    "Failed to"
    "Connection refused"
    "Permission denied"
    "No such file"
    "Out of memory"
    "CUDA error"
    "RuntimeError"
)

echo "🔍 Starting error detector..."

# Function to check for errors in log files
check_for_errors() {
    local log_file="$1"
    local context_name="$2"
    
    if [[ -f "$log_file" ]]; then
        for pattern in "${ERROR_PATTERNS[@]}"; do
            if tail -100 "$log_file" | grep -i "$pattern" >/dev/null; then
                echo "🚨 ERROR DETECTED in $context_name: $pattern"
                echo "$(date): ERROR in $context_name - $pattern" >> "$NETWORK_VOLUME/.error_alerts.log"
                return 0  # Error found
            fi
        done
    fi
    return 1  # No error found
}

# Monitor key log files
while true; do
    error_detected=false
    
    # Check various log files
    if check_for_errors "$NETWORK_VOLUME/.startup.log" "startup"; then
        error_detected=true
    fi
    
    if check_for_errors "$NETWORK_VOLUME/.sync_daemon.log" "sync_daemon"; then
        error_detected=true
    fi
    
    if check_for_errors "$NETWORK_VOLUME/ComfyUI/comfyui.log" "comfyui"; then
        error_detected=true
    fi
    
    if check_for_errors "/var/log/syslog" "system" 2>/dev/null; then
        error_detected=true
    fi
    
    # If errors detected, sync logs immediately
    if [[ "$error_detected" == true ]]; then
        echo "🚨 Errors detected - triggering immediate log sync"
        $NETWORK_VOLUME/scripts/sync_logs.sh
        
        # Also sync user data in case of critical errors
        $NETWORK_VOLUME/scripts/sync_user_data.sh
    fi
    
    sleep 30  # Check every 30 seconds
done
EOF

chmod +x "$NETWORK_VOLUME/scripts/error_detector.sh"

echo "✅ Rclone S3 setup completed successfully!"
echo ""
echo "📁 Shared folders mounted from: pod_sessions/shared/ (predefined only)"
echo "📁 ComfyUI shared folders mounted from: pod_sessions/shared/ComfyUI/ (models, custom_nodes, input)"
echo "👤 User ComfyUI folders synced from: pod_sessions/$POD_USER_NAME/$POD_ID/ComfyUI/ (output, user, temp, workflows, etc.)"
echo "👤 Other user folders synced from: pod_sessions/$POD_USER_NAME/$POD_ID/"
echo "🗂️ Network Volume: $NETWORK_VOLUME"
echo "🔧 FUSE: Properly configured and tested"
echo ""
if [[ ${#mount_failures[@]} -eq 0 ]] && [[ ${#sync_failures[@]} -eq 0 ]]; then
    echo "🎉 All critical operations completed successfully!"
else
    echo "⚠️ Some operations had issues - check logs above"
fi
echo ""
echo "🔒 Security: Only predefined shared folders are mounted"
echo "👤 User-specific: output, user, temp, workflows folders are user-specific"
echo "💡 ComfyUI user-specific folders are synced from S3"
echo "💡 Use '$NETWORK_VOLUME/sync_user_data.sh' to manually sync your changes to S3"
echo "💡 Use '$NETWORK_VOLUME/sync_new_folders.sh' to check for new folders"
echo "⏰ Automatic sync is configured to run every 5 minutes"
echo "🛑 Use '$NETWORK_VOLUME/graceful_shutdown.sh' for clean shutdown"
echo "⏰ Automatic sync is configured to run every 5 minutes"
echo ""
echo "📁 Main shared folders mounted from: pod_sessions/shared/ (venv, .comfyui)"
echo "📁 ComfyUI app: Installed locally in $NETWORK_VOLUME/ComfyUI"
echo "📁 ComfyUI shared subfolders mounted from: pod_sessions/shared/ComfyUI/ (models, custom_nodes)"
echo "👤 User ComfyUI subfolders synced from: pod_sessions/$POD_USER_NAME/ComfyUI/ (input, output, user, temp, workflows, etc.)"
echo "👤 Other user folders synced from: pod_sessions/$POD_USER_NAME/"
echo "🗂️ Network Volume: $NETWORK_VOLUME"
echo "🔧 FUSE: Properly configured and tested"
echo ""
if [[ ${#mount_failures[@]} -eq 0 ]] && [[ ${#sync_failures[@]} -eq 0 ]]; then
    echo "🎉 All critical operations completed successfully!"
else
    echo "⚠️ Some operations had issues - check logs above"
fi
echo ""
echo "🔒 Security: Only predefined shared folders are mounted"
echo "👤 User-specific: output, user, temp, workflows folders are user-specific"
echo "💡 ComfyUI user-specific folders are synced from S3"
echo "💡 Use '$NETWORK_VOLUME/sync_user_data.sh' to manually sync your changes to S3"
echo "💡 Use '$NETWORK_VOLUME/sync_new_folders.sh' to check for new folders"
echo "⏰ Automatic sync is configured to run every 5 minutes"
echo "🛑 Use '$NETWORK_VOLUME/graceful_shutdown.sh' for clean shutdown"
echo ""
echo "🔒 Security: Only predefined shared folders are mounted"
echo "👤 User-specific: output, user, temp, workflows folders are user-specific"
echo "💡 ComfyUI user-specific folders are synced from S3"
echo "💡 Use '$NETWORK_VOLUME/sync_user_data.sh' to manually sync your changes to S3"
echo "💡 Use '$NETWORK_VOLUME/sync_new_folders.sh' to check for new folders"
echo "⏰ Automatic sync is configured to run every 5 minutes"
echo "🛑 Use '$NETWORK_VOLUME/graceful_shutdown.sh' for clean shutdown"
