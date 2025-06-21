#!/bin/bash
# Sync user-specific data to S3

echo "🔄 Syncing user data to S3 by zipping folders..."

SHARED_FOLDERS=("venv" ".comfyui")
COMFYUI_SHARED_FOLDERS=("models" "custom_nodes")

is_shared_folder() {
    local folder="$1"
    for shared in "${SHARED_FOLDERS[@]}"; do
        [[ "$folder" == "$shared" ]] && return 0
    done
    return 1
}

is_comfyui_shared() {
    local item="$1"
    for shared in "${COMFYUI_SHARED_FOLDERS[@]}"; do
        [[ "$item" == "$shared" ]] && return 0
    done
    return 1
}

# --- Zip and upload function ---
zip_and_upload() {
    local local_folder_path="$1"
    local s3_base_path="$2"
    local folder_name="$3"
    
    if [[ ! -d "$local_folder_path" ]]; then
        echo "  ⏭️ Skipping non-existent folder: $folder_name"
        return
    fi

    # Check if directory has content
    if [[ -z "$(find "$local_folder_path" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        echo "  📭 Skipping empty folder: $folder_name"
        return
    fi

    local zip_file_name="${folder_name}.zip"
    local temp_zip_path="/tmp/${zip_file_name}"
    local s3_zip_path="$s3_base_path/${zip_file_name}"

    echo "  📦 Zipping $folder_name..."
    if (cd "$local_folder_path" && zip -r -q "$temp_zip_path" .); then
        echo "  📤 Uploading $zip_file_name to $s3_zip_path..."
        aws s3 cp "$temp_zip_path" "$s3_zip_path" --delete || echo "  ❌ Failed to upload $zip_file_name"
        rm "$temp_zip_path"
    else
        echo "  ❌ Failed to zip $folder_name"
        rm -f "$temp_zip_path"
    fi
}

# Sync ComfyUI user folders (pod-specific)
if [[ -d "$NETWORK_VOLUME/ComfyUI" ]]; then
    for dir in "$NETWORK_VOLUME/ComfyUI"/*; do
        if [[ -d "$dir" ]]; then
            folder_name=$(basename "$dir")
            if ! is_comfyui_shared "$folder_name"; then
                echo "📁 Syncing ComfyUI/$folder_name to S3..."
                s3_path="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/ComfyUI"
                zip_and_upload "$dir" "$s3_path" "$folder_name"
            else
                echo "⏭️ Skipping shared ComfyUI folder: $folder_name"
            fi
        fi
    done
    
    # Sync ComfyUI root files
    comfyui_files=()
    for item in "$NETWORK_VOLUME/ComfyUI"/*; do
        [[ -f "$item" ]] && comfyui_files+=($(basename "$item"))
    done
    
    if [[ ${#comfyui_files[@]} -gt 0 ]]; then
        echo "📄 Syncing ComfyUI root files to S3..."
        temp_dir="/tmp/comfyui_root_sync"
        mkdir -p "$temp_dir"
        for file in "${comfyui_files[@]}"; do
            cp "$NETWORK_VOLUME/ComfyUI/$file" "$temp_dir/"
        done
        aws s3 sync "$temp_dir" "s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/ComfyUI/_root_files/" --delete
        rm -rf "$temp_dir"
    fi
fi

# Sync other user folders (pod-specific)
echo "🔍 Checking for other user folders to sync..."
find "$NETWORK_VOLUME" -mindepth 1 -maxdepth 1 -type d | while read -r dir; do
    folder_name=$(basename "$dir")
    echo "  Checking folder: $folder_name"
    
    # Skip system/hidden folders that start with . (except explicitly included ones)
    if [[ "$folder_name" =~ ^\. ]] && ! is_shared_folder "$folder_name"; then
        echo "  ⏭️ Skipping hidden folder: $folder_name"
        continue
    fi
    
    # Skip shared folders and ComfyUI folder
    if ! is_shared_folder "$folder_name" && [[ "$folder_name" != "ComfyUI" ]]; then
        echo "  📁 Syncing user folder: $folder_name to S3..."
        s3_path="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID"
        zip_and_upload "$dir" "$s3_path" "$folder_name"
    else
        echo "  ⏭️ Skipping shared/system folder: $folder_name"
    fi
done

echo "✅ User data sync completed"
