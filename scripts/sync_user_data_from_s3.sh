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

# --- Download and unzip function ---
download_and_unzip() {
    local s3_base_path="$1"
    local local_base_path="$2"
    local folder_name="$3"
    
    local zip_file_name="${folder_name}.zip"
    local s3_zip_path="$s3_base_path/${zip_file_name}"
    local temp_zip_path="/tmp/${zip_file_name}"
    local local_folder_path="$local_base_path/$folder_name"

    echo "  ℹ️ Checking for $zip_file_name in S3 at $s3_zip_path..."
    if aws s3 ls "$s3_zip_path" >/dev/null 2>&1; then
        echo "  📥 Downloading $zip_file_name from S3..."
        if aws s3 cp "$s3_zip_path" "$temp_zip_path"; then
            echo "  📦 Unzipping $zip_file_name to $local_folder_path..."
            mkdir -p "$local_folder_path"
            if unzip -o -q "$temp_zip_path" -d "$local_folder_path"; then
                echo "  ✅ Successfully unzipped $folder_name"
            else
                echo "  ❌ Failed to unzip $zip_file_name"
            fi
            rm "$temp_zip_path"
        else
            echo "  ❌ Failed to download $zip_file_name"
        fi
    else
        echo "  ℹ️ No zip file for $folder_name found in S3. Checking for regular folder."
        # Fallback to regular sync if zip doesn't exist
        local s3_folder_path="$s3_base_path/$folder_name/"
        if aws s3 ls "$s3_folder_path" >/dev/null 2>&1; then
            echo "  📥 Syncing folder '$folder_name' from S3 (fallback)..."
            mkdir -p "$local_folder_path"
            aws s3 sync "$s3_folder_path" "$local_folder_path" || \
                echo "⚠️ WARNING: Failed to sync folder '$folder_name'. Pod will continue."
        else
            echo "  ℹ️ No data for '$folder_name' found to sync."
        fi
    fi
}

# --- ComfyUI Specific Sync ---
S3_COMFYUI_BASE="$S3_POD_BASE/ComfyUI"
LOCAL_COMFYUI_BASE="$NETWORK_VOLUME/ComfyUI"

echo "ℹ️ Checking for user-specific ComfyUI data in S3 at $S3_COMFYUI_BASE/"
if aws s3 ls "$S3_COMFYUI_BASE/" >/dev/null 2>&1; then
    echo "👍 Found user ComfyUI data in S3. Starting sync..."
    mkdir -p "$LOCAL_COMFYUI_BASE" # Ensure local ComfyUI base exists

    # 1. Sync specific user-modifiable ComfyUI subfolders
    comfyui_user_sync_folders=("input" "output") # Customize this list

    for folder_name in "${comfyui_user_sync_folders[@]}"; do
        download_and_unzip "$S3_COMFYUI_BASE" "$LOCAL_COMFYUI_BASE" "$folder_name"
    done

    # 2. Sync ComfyUI root files (e.g., user_startup_options.json, workflow_api.js if customized)
    root_zip_file_name="_root_files.zip"
    s3_root_zip_path="$S3_COMFYUI_BASE/$root_zip_file_name"
    temp_root_zip_path="/tmp/$root_zip_file_name"
    echo "  ℹ️ Checking for ComfyUI root files zip at $s3_root_zip_path..."
    if aws s3 ls "$s3_root_zip_path" >/dev/null 2>&1; then
        echo "  📥 Downloading $root_zip_file_name..."
        if aws s3 cp "$s3_root_zip_path" "$temp_root_zip_path"; then
            echo "  📦 Unzipping root files to $LOCAL_COMFYUI_BASE..."
            unzip -o -q "$temp_root_zip_path" -d "$LOCAL_COMFYUI_BASE" || echo "  ❌ Failed to unzip root files."
            rm "$temp_root_zip_path"
        else
            echo "  ❌ Failed to download root files zip."
        fi
    else
        echo "  ℹ️ No root files zip found. Falling back to directory sync for _root_files..."
        s3_comfyui_root_files_path="$S3_COMFYUI_BASE/_root_files/"
        if aws s3 ls "$s3_comfyui_root_files_path" >/dev/null 2>&1; then
            echo "  📥 Syncing ComfyUI root files from $s3_comfyui_root_files_path to $LOCAL_COMFYUI_BASE/ ..."
            aws s3 sync "$s3_comfyui_root_files_path" "$LOCAL_COMFYUI_BASE/" || \
                echo "⚠️ WARNING: Failed to sync ComfyUI root files. Pod will continue."
        else
            echo "  ℹ️ No ComfyUI _root_files data found in S3."
        fi
    fi
else
    echo "ℹ️ No user-specific ComfyUI directory found in S3 for this pod session."
fi
echo ""


# --- General User Data Sync (Other Top-Level Folders) ---
echo "ℹ️ Checking for other user-specific data in S3 at $S3_POD_BASE/"
if aws s3 ls "$S3_POD_BASE/" >/dev/null 2>&1; then
    echo "👍 Found pod session base in S3. Syncing other user folders..."

    declare -A exclude_folders_map
    exclude_folders_map["ComfyUI"]=1
    exclude_folders_map["_pod_tracking"]=1

    aws s3 ls "$S3_POD_BASE/" | grep "PRE" | awk '{print $2}' | sed 's/\/\//g' | while IFS= read -r folder_name; do
        if [[ -z "${exclude_folders_map[$folder_name]}" ]]; then
            download_and_unzip "$S3_POD_BASE" "$NETWORK_VOLUME" "$folder_name"
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
        download_and_unzip "$S3_USER_SHARED_BASE" "$NETWORK_VOLUME" "$folder_name"
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
        download_and_unzip "$S3_USER_COMFYUI_SHARED_BASE" "$NETWORK_VOLUME/ComfyUI" "$folder_name"
    done
else
    echo "ℹ️ No user-specific ComfyUI shared directory found in S3."
fi
echo ""

echo "✅ User data sync from S3 completed."

