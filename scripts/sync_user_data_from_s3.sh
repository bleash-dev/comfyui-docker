#!/bin/bash
# Sync user data from S3 on startup using archives

# Optional but recommended:
# set -uo pipefail

echo "📥 Syncing user data from S3 (archives)..."

# --- Configuration & Validation ---
required_vars=("AWS_BUCKET_NAME" "POD_USER_NAME" "POD_ID" "NETWORK_VOLUME")
for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then 
        echo "❌ ERROR: Required environment variable $var is not set."
        exit 1
    fi
done

mkdir -p "$NETWORK_VOLUME"
mkdir -p "$NETWORK_VOLUME/ComfyUI"

# --- Helper Function: Download and Extract ---
download_and_extract() {
    local archive_s3_uri="$1"          
    local local_extract_target_dir="$2"  
    local archive_description="$3"       
    local tmp_archive_file
    local bucket_name key

    if [[ "$archive_s3_uri" =~ s3://([^/]+)/(.*) ]]; then
        bucket_name="${BASH_REMATCH[1]}"
        key="${BASH_REMATCH[2]}"
    else
        echo "❌ INTERNAL SCRIPT ERROR: Invalid S3 URI format for $archive_description: $archive_s3_uri"
        return 1
    fi

    echo "ℹ️ Checking for $archive_description archive: s3://$bucket_name/$key"

    if aws s3api head-object --bucket "$bucket_name" --key "$key" >/dev/null 2>&1; then
        tmp_archive_file=$(mktemp "/tmp/s3_archive_dl_$(basename "$key" .tar.gz)_XXXXXX.tar.gz")

        echo "  📥 Downloading $archive_description..."
        if aws s3 cp "s3://$bucket_name/$key" "$tmp_archive_file" --only-show-errors; then
            echo "  📦 Extracting to $local_extract_target_dir..."
            mkdir -p "$local_extract_target_dir"
            if tar -xzf "$tmp_archive_file" -C "$local_extract_target_dir"; then
                echo "  ✅ Extracted $archive_description successfully."
            else
                echo "🔥🔥 WARNING: FAILED to extract $archive_description from $tmp_archive_file to $local_extract_target_dir. Data will be missing or incomplete. 🔥🔥"
            fi
            rm -f "$tmp_archive_file"
        else
            echo "⚠️ WARNING: Failed to download $archive_description from s3://$bucket_name/$key (e.g., permissions, network issue), even though it exists. Skipping."
            # Clean up temp file if download failed but mktemp succeeded
            [ -f "$tmp_archive_file" ] && rm -f "$tmp_archive_file"
        fi
    else
        echo "  ⏭️ $archive_description archive not found at s3://$bucket_name/$key. Skipping."
    fi
    echo "" 
}


# --- Define S3 Base Paths and Archive Names (mirroring the upload script) ---
S3_POD_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID"
COMFYUI_POD_SPECIFIC_ARCHIVE_S3_PATH="$S3_POD_BASE/comfyui_pod_specific_data.tar.gz"
OTHER_POD_SPECIFIC_ARCHIVE_S3_PATH="$S3_POD_BASE/other_pod_specific_data.tar.gz"

S3_USER_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/shared"
# CORRECTED to match upload script for .comfyui -> _comfyui.tar.gz
USER_SHARED_ARCHIVE_FILES=("venv.tar.gz" "_comfyui.tar.gz" "_cache.tar.gz") 

S3_USER_COMFYUI_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/ComfyUI/shared"
COMFYUI_USER_SHARED_ARCHIVE_FILES=("custom_nodes.tar.gz") 

# --- Restore Order ---
echo "--- Restoring User-Shared Data ---"
for archive_filename in "${USER_SHARED_ARCHIVE_FILES[@]}"; do
    folder_description="${archive_filename%.tar.gz}" 
    # For _comfyui.tar.gz, folder_description becomes "_comfyui". 
    # If you want it to log ".comfyui", you'd need a small mapping or string replacement here.
    # E.g., if [[ "$folder_description" == "_comfyui" ]]; then display_name=".comfyui"; else display_name="$folder_description"; fi
    # For now, keeping it simple:
    download_and_extract \
        "$S3_USER_SHARED_BASE/$archive_filename" \
        "$NETWORK_VOLUME" \
        "User-shared '$folder_description' data"
done

echo "--- Restoring ComfyUI User-Shared Data ---"
for archive_filename in "${COMFYUI_USER_SHARED_ARCHIVE_FILES[@]}"; do
    folder_description="${archive_filename%.tar.gz}" 
    download_and_extract \
        "$S3_USER_COMFYUI_SHARED_BASE/$archive_filename" \
        "$NETWORK_VOLUME/ComfyUI" \
        "ComfyUI user-shared '$folder_description' data"
done

echo "--- Restoring ComfyUI Pod-Specific Data ---"
download_and_extract \
    "$COMFYUI_POD_SPECIFIC_ARCHIVE_S3_PATH" \
    "$NETWORK_VOLUME/ComfyUI" \
    "ComfyUI pod-specific data"

echo "--- Restoring Other Pod-Specific Data ---"
download_and_extract \
    "$OTHER_POD_SPECIFIC_ARCHIVE_S3_PATH" \
    "$NETWORK_VOLUME" \
    "Other pod-specific data"

echo "✅ User data sync from S3 (archives) completed."