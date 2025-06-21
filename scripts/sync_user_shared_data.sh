#!/bin/bash
# Sync user-shared data to S3 (data that persists across different pods for the same user)

echo "🔄 Syncing user-shared data to S3 by zipping folders..."

# User-specific shared data (not pod-specific)
S3_USER_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/shared"
S3_USER_COMFYUI_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/ComfyUI/shared"

# Folders that should be shared across pods for the same user
USER_SHARED_FOLDERS=("venv" ".comfyui")
COMFYUI_USER_SHARED_FOLDERS=("custom_nodes")

# --- Zip and upload function ---
zip_and_upload() {
    local local_folder_path="$1"
    local s3_base_path="$2"
    local folder_name="$3"
    
    if [[ ! -d "$local_folder_path" ]]; then
        echo "  ⏭️ Skipping non-existent folder: $folder_name"
        return
    fi

    local zip_file_name="${folder_name}.zip"
    local temp_zip_path="/tmp/${zip_file_name}"
    local s3_zip_path="$s3_base_path/${zip_file_name}"

    echo "  📦 Zipping $folder_name..."
    # Use -r to recurse into directories, and -q for quiet operation
    # The 'cd' is important to avoid including the parent directory structure in the zip
    if (cd "$local_folder_path" && zip -r -q "$temp_zip_path" .); then
        echo "  📤 Uploading $zip_file_name to $s3_zip_path..."
        aws s3 cp "$temp_zip_path" "$s3_zip_path" || \
            echo "  ❌ Failed to upload $zip_file_name"
        rm "$temp_zip_path"
    else
        echo "  ❌ Failed to zip $folder_name"
        rm -f "$temp_zip_path"
    fi
}

# Sync user-shared folders
echo "📁 Syncing user-shared folders..."
for folder_name in "${USER_SHARED_FOLDERS[@]}"; do
    local_folder_path="$NETWORK_VOLUME/$folder_name"
    zip_and_upload "$local_folder_path" "$S3_USER_SHARED_BASE" "$folder_name"
done

# Sync ComfyUI user-shared folders
echo "📁 Syncing ComfyUI user-shared folders..."
for folder_name in "${COMFYUI_USER_SHARED_FOLDERS[@]}"; do
    local_folder_path="$NETWORK_VOLUME/ComfyUI/$folder_name"
    zip_and_upload "$local_folder_path" "$S3_USER_COMFYUI_SHARED_BASE" "$folder_name"
done

echo "✅ User-shared data sync completed"
