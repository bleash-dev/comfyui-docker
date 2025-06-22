#!/bin/bash
# Sync user data from S3 on startup using archives

echo "📥 Syncing user data from S3 (archives)..."

# --- Configuration & Validation ---
# Exit on error, treat unset variables as an error, and pipe failures.
# The helper function is designed to handle errors gracefully without exiting the main script
# for missing archives, allowing the pod to attempt to start with partial data if necessary.
# Not using -e globally to allow the script to continue if some archives are missing,
# as per the original script's warning-based error handling. Critical errors
# (like missing env vars) will still exit.

required_vars=("AWS_BUCKET_NAME" "POD_USER_NAME" "POD_ID" "NETWORK_VOLUME")
for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then # Use :- to avoid error with set -u if var is truly unset
        echo "❌ ERROR: Required environment variable $var is not set."
        exit 1
    fi
done

# Ensure the local base directories exist, as they are common extraction targets
mkdir -p "$NETWORK_VOLUME"
mkdir -p "$NETWORK_VOLUME/ComfyUI"

# --- Helper Function: Download and Extract ---
download_and_extract() {
    local archive_s3_uri="$1"          # Full s3://bucket/key path
    local local_extract_target_dir="$2"  # Directory to extract INTO
    local archive_description="$3"       # For logging
    local tmp_archive_file
    local bucket_name key

    # Extract bucket and key from S3 URI
    if [[ "$archive_s3_uri" =~ s3://([^/]+)/(.*) ]]; then
        bucket_name="${BASH_REMATCH[1]}"
        key="${BASH_REMATCH[2]}"
    else
        echo "❌ INTERNAL SCRIPT ERROR: Invalid S3 URI format for $archive_description: $archive_s3_uri"
        # This is a script bug, should ideally not happen.
        # Depending on severity, one might 'exit 1' here. For now, we'll try to continue.
        return 1
    fi

    echo "ℹ️ Checking for $archive_description archive: s3://$bucket_name/$key"

    # Check if S3 object exists using head-object (more reliable than ls for single objects)
    if aws s3api head-object --bucket "$bucket_name" --key "$key" >/dev/null 2>&1; then
        # Create a temporary file for the download
        # The .tar.gz suffix is for clarity; mktemp ensures uniqueness.
        tmp_archive_file=$(mktemp "/tmp/s3_archive_dl_$(basename "$key" .tar.gz)_XXXXXX.tar.gz")

        echo "  📥 Downloading $archive_description..."
        if aws s3 cp "s3://$bucket_name/$key" "$tmp_archive_file" --only-show-errors; then
            echo "  📦 Extracting to $local_extract_target_dir..."
            # Ensure the target directory for extraction exists
            mkdir -p "$local_extract_target_dir"

            # Extract the archive. The -C flag tells tar to change to this directory before extracting.
            if tar -xzf "$tmp_archive_file" -C "$local_extract_target_dir"; then
                echo "  ✅ Extracted $archive_description successfully."
            else
                # tar errors are usually serious for data integrity.
                echo "🔥🔥 WARNING: FAILED to extract $archive_description from $tmp_archive_file to $local_extract_target_dir. Data will be missing or incomplete. 🔥🔥"
                # The script will continue, but this is a significant issue.
            fi
            # Clean up the downloaded archive
            rm -f "$tmp_archive_file"
        else
            echo "⚠️ WARNING: Failed to download $archive_description from s3://$bucket_name/$key (e.g., permissions, network issue), even though it exists. Skipping."
        fi
    else
        echo "  ⏭️ $archive_description archive not found at s3://$bucket_name/$key. Skipping."
    fi
    echo "" # Add a newline for better log readability between archive processing
}


# --- Define S3 Base Paths and Archive Names (mirroring the upload script) ---

# Pod-specific data archives (unique to this POD_ID)
S3_POD_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID"
COMFYUI_POD_SPECIFIC_ARCHIVE_S3_PATH="$S3_POD_BASE/comfyui_pod_specific_data.tar.gz"
OTHER_POD_SPECIFIC_ARCHIVE_S3_PATH="$S3_POD_BASE/other_pod_specific_data.tar.gz"

# User-specific shared data archives (shared across user's pods)
S3_USER_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/shared"
USER_SHARED_ARCHIVE_FILES=("venv.tar.gz" ".comfyui.tar.gz") # From sync_user_shared_data.sh

# User-specific ComfyUI shared data archives
S3_USER_COMFYUI_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/ComfyUI/shared"
COMFYUI_USER_SHARED_ARCHIVE_FILES=("custom_nodes.tar.gz") # From sync_user_shared_data.sh


# --- Restore Order: Shared foundational data first, then pod-specific data ---
# This order allows pod-specific data to potentially overlay parts of shared data if necessary,
# though our current archiving strategy largely keeps them separate.

# 1. User-Shared Data (e.g., venv, .comfyui config root)
# These archives (e.g., venv.tar.gz) contain their top-level folder (e.g., "venv/").
# So, they are extracted into $NETWORK_VOLUME.
echo "--- Restoring User-Shared Data ---"
for archive_filename in "${USER_SHARED_ARCHIVE_FILES[@]}"; do
    folder_description="${archive_filename%.tar.gz}" # e.g., "venv" or ".comfyui"
    download_and_extract \
        "$S3_USER_SHARED_BASE/$archive_filename" \
        "$NETWORK_VOLUME" \
        "User-shared '$folder_description' data"
done

# 2. ComfyUI User-Shared Data (e.g., custom_nodes)
# These archives (e.g., custom_nodes.tar.gz) contain their top-level folder (e.g., "custom_nodes/").
# So, they are extracted into $NETWORK_VOLUME/ComfyUI.
echo "--- Restoring ComfyUI User-Shared Data ---"
for archive_filename in "${COMFYUI_USER_SHARED_ARCHIVE_FILES[@]}"; do
    folder_description="${archive_filename%.tar.gz}" # e.g., "custom_nodes"
    download_and_extract \
        "$S3_USER_COMFYUI_SHARED_BASE/$archive_filename" \
        "$NETWORK_VOLUME/ComfyUI" \
        "ComfyUI user-shared '$folder_description' data"
done

# 3. ComfyUI Pod-Specific Data
# This archive (comfyui_pod_specific_data.tar.gz) contains the *contents* of various
# ComfyUI subdirectories (like 'input', 'output') and root files, not a single top-level folder.
# So, it's extracted directly into $NETWORK_VOLUME/ComfyUI.
echo "--- Restoring ComfyUI Pod-Specific Data ---"
download_and_extract \
    "$COMFYUI_POD_SPECIFIC_ARCHIVE_S3_PATH" \
    "$NETWORK_VOLUME/ComfyUI" \
    "ComfyUI pod-specific data"

# 4. Other Pod-Specific Data
# This archive (other_pod_specific_data.tar.gz) contains various top-level user folders
# (like 'my_project'), not a single top-level folder in the archive itself.
# So, it's extracted directly into $NETWORK_VOLUME.
echo "--- Restoring Other Pod-Specific Data ---"
download_and_extract \
    "$OTHER_POD_SPECIFIC_ARCHIVE_S3_PATH" \
    "$NETWORK_VOLUME" \
    "Other pod-specific data"


echo "✅ User data sync from S3 (archives) completed."