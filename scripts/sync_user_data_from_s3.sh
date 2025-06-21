#!/bin/bash
# Sync user data from S3 on startup

echo "📥 Syncing user data from S3..."

# --- Configuration & Validation ---
set -eo pipefail # Exit on error, treat unset variables as an error, and pipe failures

required_vars=("AWS_BUCKET_NAME" "POD_USER_NAME" "POD_ID" "NETWORK_VOLUME")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ ERROR: Required environment variable $var is not set."
        exit 1
    fi
done

# Base S3 path for the current pod's user data (pod-specific)
S3_POD_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID"

# User-specific shared data (not pod-specific)
S3_USER_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/shared"
S3_USER_COMFYUI_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/ComfyUI/shared"

# Ensure the local base directory exists
mkdir -p "$NETWORK_VOLUME"

# --- ComfyUI Specific Sync ---
S3_COMFYUI_BASE="$S3_POD_BASE/ComfyUI"
LOCAL_COMFYUI_BASE="$NETWORK_VOLUME/ComfyUI"

echo "ℹ️ Checking for user-specific ComfyUI data in S3 at $S3_COMFYUI_BASE/"
if aws s3 ls "$S3_COMFYUI_BASE/" >/dev/null 2>&1; then
    echo "👍 Found user ComfyUI data in S3. Starting sync..."
    mkdir -p "$LOCAL_COMFYUI_BASE" # Ensure local ComfyUI base exists

    # 1. Sync specific user-modifiable ComfyUI subfolders (e.g., inputs, outputs)
    #    Add other folders here that the user typically owns and modifies,
    #    and that are NOT part of shared/common models or custom_nodes.
    #    Example: 'input', 'output', 'temp_files', 'user_configs'
    comfyui_user_sync_folders=("input" "output") # Customize this list

    for folder_name in "${comfyui_user_sync_folders[@]}"; do
        s3_folder_path="$S3_COMFYUI_BASE/$folder_name/"
        local_folder_path="$LOCAL_COMFYUI_BASE/$folder_name/"

        # Check if the specific user folder exists in S3 before syncing
        if aws s3 ls "$s3_folder_path" >/dev/null 2>&1; then
            echo "  📥 Syncing ComfyUI/$folder_name from S3..."
            mkdir -p "$local_folder_path"
            aws s3 sync "$s3_folder_path" "$local_folder_path" || \
                echo "⚠️ WARNING: Failed to sync ComfyUI/$folder_name. Pod will continue."
        else
            echo "  ℹ️ No user data for ComfyUI/$folder_name found in S3."
        fi
    done

    # 2. Sync ComfyUI root files (e.g., user_startup_options.json, workflow_api.js if customized)
    #    These are files directly in ComfyUI/, not in subfolders managed above.
    #    Assume _root_files on S3 contains only files meant for the ComfyUI root.
    s3_comfyui_root_files_path="$S3_COMFYUI_BASE/_root_files/"
    if aws s3 ls "$s3_comfyui_root_files_path" >/dev/null 2>&1; then
        echo "  📥 Syncing ComfyUI root files from $s3_comfyui_root_files_path to $LOCAL_COMFYUI_BASE/ ..."
        aws s3 sync "$s3_comfyui_root_files_path" "$LOCAL_COMFYUI_BASE/" || \
            echo "⚠️ WARNING: Failed to sync ComfyUI root files. Pod will continue."
    else
        echo "  ℹ️ No ComfyUI _root_files found in S3."
    fi
else
    echo "ℹ️ No user-specific ComfyUI directory found in S3 for this pod session."
fi
echo ""


# --- General User Data Sync (Other Top-Level Folders) ---
echo "ℹ️ Checking for other user-specific data in S3 at $S3_POD_BASE/"
if aws s3 ls "$S3_POD_BASE/" >/dev/null 2>&1; then
    echo "👍 Found pod session base in S3. Syncing other user folders..."

    # Define folders to exclude from this general sync
    # These are either handled specifically (ComfyUI) or are internal (_pod_tracking)
    # or potentially mounted/handled differently (_workspace_root if it's a special mount point)
    declare -A exclude_folders_map # Use an associative array for efficient lookup
    exclude_folders_map["ComfyUI"]=1
    exclude_folders_map["_pod_tracking"]=1
    exclude_folders_map["_workspace_root"]=1 # If this is a special folder synced by other means

    # Get list of top-level directories in the pod's S3 base
    aws s3 ls "$S3_POD_BASE/" | grep "PRE" | awk '{print $2}' | sed 's/\///g' | while IFS= read -r folder_name; do
        if [[ -z "${exclude_folders_map[$folder_name]}" ]]; then # Check if folder is NOT in the exclusion map
            s3_folder_path="$S3_POD_BASE/$folder_name/"
            local_folder_path="$NETWORK_VOLUME/$folder_name/" # Sync to top-level of NETWORK_VOLUME

            echo "  📥 Syncing general folder '$folder_name' from S3..."
            mkdir -p "$local_folder_path"
            aws s3 sync "$s3_folder_path" "$local_folder_path" || \
                echo "⚠️ WARNING: Failed to sync general folder '$folder_name'. Pod will continue."
        else
            echo "  ↪️ Skipping folder '$folder_name' (in exclusion list or handled separately)."
        fi
    done
else
    echo "ℹ️ No S3 data found at the pod session base: $S3_POD_BASE/"
fi

echo ""

# --- User-Specific Shared Data Sync (Not Pod-Specific) ---
echo "ℹ️ Checking for user-specific shared data in S3 at $S3_USER_SHARED_BASE/"
if aws s3 ls "$S3_USER_SHARED_BASE/" >/dev/null 2>&1; then
    echo "👍 Found user shared data in S3. Starting sync..."
    
    user_shared_sync_folders=("venv" ".comfyui")
    
    for folder_name in "${user_shared_sync_folders[@]}"; do
        s3_folder_path="$S3_USER_SHARED_BASE/$folder_name/"
        local_folder_path="$NETWORK_VOLUME/$folder_name/"
        
        if aws s3 ls "$s3_folder_path" >/dev/null 2>&1; then
            echo "  📥 Syncing user-shared/$folder_name from S3..."
            mkdir -p "$local_folder_path"
            aws s3 sync "$s3_folder_path" "$local_folder_path" || \
                echo "⚠️ WARNING: Failed to sync user-shared/$folder_name. Pod will continue."
        else
            echo "  ℹ️ No user shared data for $folder_name found in S3."
        fi
    done
else
    echo "ℹ️ No user-specific shared directory found in S3."
fi
echo ""

# --- User-Specific ComfyUI Shared Data Sync ---
echo "ℹ️ Checking for user-specific ComfyUI shared data in S3 at $S3_USER_COMFYUI_SHARED_BASE/"
if aws s3 ls "$S3_USER_COMFYUI_SHARED_BASE/" >/dev/null 2>&1; then
    echo "👍 Found user ComfyUI shared data in S3. Starting sync..."
    mkdir -p "$NETWORK_VOLUME/ComfyUI"
    
    comfyui_user_shared_sync_folders=("custom_nodes")
    
    for folder_name in "${comfyui_user_shared_sync_folders[@]}"; do
        s3_folder_path="$S3_USER_COMFYUI_SHARED_BASE/$folder_name/"
        local_folder_path="$NETWORK_VOLUME/ComfyUI/$folder_name/"
        
        if aws s3 ls "$s3_folder_path" >/dev/null 2>&1; then
            echo "  📥 Syncing ComfyUI-user-shared/$folder_name from S3..."
            mkdir -p "$local_folder_path"
            aws s3 sync "$s3_folder_path" "$local_folder_path" || \
                echo "⚠️ WARNING: Failed to sync ComfyUI-user-shared/$folder_name. Pod will continue."
        else
            echo "  ℹ️ No user ComfyUI shared data for $folder_name found in S3."
        fi
    done
else
    echo "ℹ️ No user-specific ComfyUI shared directory found in S3."
fi
echo ""

echo "✅ User data sync from S3 completed."

