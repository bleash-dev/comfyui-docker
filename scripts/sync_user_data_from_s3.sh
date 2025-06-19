#!/bin/bash
# Sync user data from S3 on startup

echo "📥 Syncing user data from S3..."

# Sync ComfyUI user folders
if rclone lsd "s3:$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/ComfyUI/" 2>/dev/null; then
    echo "📁 Found user ComfyUI data in S3"
    
    # Get list of user folders
    user_folders=()
    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*[-0-9]+[[:space:]]+[0-9-]+[[:space:]]+[0-9:]+[[:space:]]+(.+)$ ]]; then
            folder_name="${BASH_REMATCH[1]}"
            # Skip shared folders
            if [[ "$folder_name" != "models" && "$folder_name" != "custom_nodes" ]]; then
                user_folders+=("$folder_name")
            fi
        fi
    done < <(rclone lsd "s3:$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/ComfyUI/" 2>/dev/null)
    
    # Sync each user folder
    for folder in "${user_folders[@]}"; do
        local_path="$NETWORK_VOLUME/ComfyUI/$folder"
        s3_path="s3:$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/ComfyUI/$folder"
        
        mkdir -p "$local_path"
        echo "📥 Syncing ComfyUI/$folder from S3..."
        rclone sync "$s3_path" "$local_path" --progress --retries 3 || echo "Failed to sync $folder"
    done
    
    # Sync ComfyUI root files
    s3_root_files="s3:$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/ComfyUI/_root_files"
    if rclone lsd "$s3_root_files" >/dev/null 2>&1; then
        echo "📥 Syncing ComfyUI root files from S3..."
        temp_root="/tmp/comfyui_root_restore"
        mkdir -p "$temp_root"
        rclone sync "$s3_root_files" "$temp_root" --progress --retries 3
        
        for file in "$temp_root"/*; do
            if [[ -f "$file" ]]; then
                filename=$(basename "$file")
                if [[ ! -e "$NETWORK_VOLUME/ComfyUI/$filename" ]]; then
                    cp "$file" "$NETWORK_VOLUME/ComfyUI/"
                fi
            fi
        done
        rm -rf "$temp_root"
    fi
fi

# Sync other user folders
if rclone lsd "s3:$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/" 2>/dev/null; then
    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*[-0-9]+[[:space:]]+[0-9-]+[[:space:]]+[0-9:]+[[:space:]]+(.+)$ ]]; then
            folder_name="${BASH_REMATCH[1]}"
            if [[ "$folder_name" != "ComfyUI" && "$folder_name" != "_pod_tracking" && "$folder_name" != "_workspace_root" ]]; then
                local_path="$NETWORK_VOLUME/$folder_name"
                s3_path="s3:$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/$folder_name"
                
                mkdir -p "$local_path"
                echo "📥 Syncing $folder_name from S3..."
                rclone sync "$s3_path" "$local_path" --progress --retries 3 || echo "Failed to sync $folder_name"
            fi
        fi
    done < <(rclone lsd "s3:$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/" 2>/dev/null)
fi

echo "✅ User data sync from S3 completed"
