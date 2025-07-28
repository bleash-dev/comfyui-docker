#!/bin/bash
# Sync user data from S3 on startup using archives and optimized venv chunking

# Optional but recommended:
# set -uo pipefail

echo "📥 Syncing user data from S3 (optimized)..."

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

# --- Network Volume Optimization Check ---
# Check if _NETWORK_VOLUME is available for shared data optimization
NETWORK_VOLUME_AVAILABLE=false
if [ -n "${_NETWORK_VOLUME:-}" ] && [ -d "$_NETWORK_VOLUME" ] && [ -w "$_NETWORK_VOLUME" ]; then
    NETWORK_VOLUME_AVAILABLE=true
    echo "🔗 Network volume detected at $_NETWORK_VOLUME - enabling shared data optimization"
    mkdir -p "$_NETWORK_VOLUME"
else
    echo "📁 No network volume available - using standard download method"
fi

# Source venv chunk manager if available
if [ -f "$NETWORK_VOLUME/scripts/venv_chunk_manager.sh" ]; then
    source "$NETWORK_VOLUME/scripts/venv_chunk_manager.sh"
    VENV_CHUNKS_AVAILABLE=true
else
    echo "⚠️ Venv chunk manager not found, using traditional method"
    VENV_CHUNKS_AVAILABLE=false
fi

# Source S3 interactor
if [ -f "$NETWORK_VOLUME/scripts/s3_interactor.sh" ]; then
    source "$NETWORK_VOLUME/scripts/s3_interactor.sh"
else
    echo "⚠️ S3 interactor not found, falling back to direct AWS CLI commands"
fi

# --- Network Volume Helper Functions ---
# Check if a directory is usable (exists, is a directory, and is accessible)
is_directory_usable() {
    local dir_path="$1"
    [ -d "$dir_path" ] && [ -r "$dir_path" ] && [ -w "$dir_path" ]
}

# Create symlink from network volume to pod local path if network volume data is available
# Returns 0 if symlink created successfully, 1 if fallback to download needed
try_symlink_from_network_volume() {
    local network_vol_path="$1"    # Path in _NETWORK_VOLUME
    local pod_local_path="$2"      # Path in NETWORK_VOLUME (pod local)
    local description="$3"         # Description for logging
    
    if [ "$NETWORK_VOLUME_AVAILABLE" != "true" ]; then
        return 1  # Network volume not available, fallback to download
    fi
    
    local full_network_path="$_NETWORK_VOLUME/$network_vol_path"
    
    # Check if network volume has the data and it's usable
    if is_directory_usable "$full_network_path"; then
        echo "  🔗 Found usable $description in network volume, creating symlink..."
        
        # Remove existing directory/symlink if it exists
        if [ -e "$pod_local_path" ] || [ -L "$pod_local_path" ]; then
            rm -rf "$pod_local_path"
        fi
        
        # Create parent directory if needed
        mkdir -p "$(dirname "$pod_local_path")"
        
        # Create symlink
        if ln -s "$full_network_path" "$pod_local_path"; then
            echo "    ✅ Symlink created: $pod_local_path -> $full_network_path"
            return 0  # Success, no download needed
        else
            echo "    ❌ Failed to create symlink, will fallback to download"
            return 1  # Failed, fallback to download
        fi
    else
        echo "  📁 $description not found or unusable in network volume, will download"
        return 1  # Not available or unusable, fallback to download
    fi
}

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

    echo "ℹ️ Checking for $archive_description archive: $archive_s3_uri"

    # Check if the archive exists on S3 using S3 interactor
    if command -v s3_object_exists >/dev/null 2>&1 && s3_object_exists "$archive_s3_uri"; then
        tmp_archive_file=$(mktemp "/tmp/s3_archive_dl_$(basename "$key" .tar.gz)_XXXXXX.tar.gz")

        echo "  📥 Downloading $archive_description..."
        if s3_copy_from "$archive_s3_uri" "$tmp_archive_file" "--only-show-errors"; then
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

# --- Helper Function: Download and Restore Chunked Venvs ---
download_and_restore_chunked_venvs() {
    local s3_chunks_base="$1"
    local local_venv_base_dir="$2"
    local description="$3"

    echo "ℹ️ Checking for chunked $description: $s3_chunks_base"

    # Check if any venv chunks are available using S3 interactor
    if command -v s3_list >/dev/null 2>&1 && s3_list "$s3_chunks_base/" >/dev/null 2>&1; then
        local venv_dirs_found
        venv_dirs_found=$(s3_list "$s3_chunks_base/" "--recursive" \
| grep -E '\.zip$|\.tar\.gz$' \
| awk '{print $4}' \
| awk -F'/' '{print $(NF-1)}' \
| sort -u)
        
        if [ -n "$venv_dirs_found" ]; then
            local venv_count=$(echo "$venv_dirs_found" | wc -l)
            local successful_restores=0
            local failed_restores=0
            
            echo "  📦 Found $venv_count venv(s) with chunks, using optimized download..."
            
            if [ "$VENV_CHUNKS_AVAILABLE" = "true" ]; then
                # Process each venv
                while IFS= read -r venv_name; do
                    if [ -n "$venv_name" ]; then
                        local venv_s3_path="$s3_chunks_base/$venv_name"
                        local venv_local_dir="$local_venv_base_dir/$venv_name"
                        
                        echo "    📦 Processing venv: $venv_name"
                        
                        # Use optimized chunked download
                        if download_and_reassemble_venv "$venv_s3_path" "$venv_local_dir"; then
                            echo "      ✅ Successfully restored $venv_name using chunked method"
                            
                            # Verify the restored venv is functional
                            if [ -f "$venv_local_dir/bin/python" ] && "$venv_local_dir/bin/python" --version >/dev/null 2>&1; then
                                echo "      ✅ Restored $venv_name venv is functional"
                                successful_restores=$((successful_restores + 1))
                            else
                                echo "      ⚠️ Restored $venv_name venv appears corrupted"
                                failed_restores=$((failed_restores + 1))
                            fi
                        else
                            echo "      ⚠️ Chunked restoration failed for $venv_name"
                            failed_restores=$((failed_restores + 1))
                        fi
                    fi
                done <<< "$venv_dirs_found"
                
                if [ $successful_restores -gt 0 ]; then
                    echo "  ✅ Successfully restored $successful_restores/$venv_count venvs using chunked method"
                    if [ $failed_restores -gt 0 ]; then
                        echo "  ⚠️ $failed_restores venvs failed chunked restoration"
                    fi
                    return 0
                else
                    echo "  ⚠️ All chunked venv restorations failed"
                    return 1
                fi
            else
                echo "  ⚠️ Chunk manager not available, skipping chunked download"
                return 1
            fi
        else
            echo "  ⏭️ No chunk files found at $s3_chunks_base"
            return 1
        fi
    else
        echo "  ⏭️ Chunked $description not found at $s3_chunks_base"
        return 1
    fi
}

# --- Define S3 Base Paths and Archive Names (mirroring the upload script) ---
S3_POD_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID"
COMFYUI_POD_SPECIFIC_ARCHIVE_S3_PATH="$S3_POD_BASE/comfyui_pod_specific_data.tar.gz"
OTHER_POD_SPECIFIC_ARCHIVE_S3_PATH="$S3_POD_BASE/other_pod_specific_data.tar.gz"

S3_USER_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/shared"
S3_USER_COMFYUI_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/ComfyUI/shared"
COMFYUI_USER_SHARED_ARCHIVE_FILES=("custom_nodes.tar.gz")

# Updated archive list without venv (handled separately)
OTHER_USER_SHARED_ARCHIVE_FILES=("_comfyui.tar.gz" "_cache.tar.gz")

# --- Restore Order ---
echo "--- Restoring Virtual Environments (Optimized) ---"
# Network volume optimization: Try symlinks first, fallback to download
venv_restored=false

# Try network volume symlink first for venv
if try_symlink_from_network_volume "venv" "$NETWORK_VOLUME/venv" "virtual environments"; then
    venv_restored=true
    echo "  ✅ Virtual environments symlinked from network volume"
else
    echo "  🔄 Network volume symlink failed, proceeding with download..."
    
    # New multi-venv structure: S3 path is /venv_chunks/{venv_name}/ for each venv
    # This allows multiple venvs to coexist and be restored independently
    # Legacy single venv structure at /venv_chunks/ is still supported for backwards compatibility
    # Try chunked venvs first, fall back to traditional archive
    
    # Try new multi-venv structure first
    if download_and_restore_chunked_venvs \
        "$S3_USER_SHARED_BASE/venv_chunks" \
        "$NETWORK_VOLUME/venv" \
        "user venvs (chunked)"; then
        venv_restored=true
        echo "  ✅ Chunked venvs restoration successful"
    else
    echo "  🔄 New multi-venv structure not found, trying legacy single venv structure..."
    
    # Try legacy single venv structure (backwards compatibility)
    if [ "$VENV_CHUNKS_AVAILABLE" = "true" ]; then
        echo "  🔄 Checking for legacy single venv structure..."
        if download_and_reassemble_venv \
            "$S3_USER_SHARED_BASE/venv_chunks" \
            "$NETWORK_VOLUME/venv/comfyui"; then
            venv_restored=true
            echo "  ✅ Legacy chunked venv restoration successful"
            echo "  ℹ️ Legacy venv restored as ComfyUI venv - will be migrated to new structure on next sync"
        else
            echo "  ⚠️ Legacy chunked venv restoration failed"
        fi
    fi
    
    # Final fallback to traditional archive
    if [ "$venv_restored" = "false" ]; then
        echo "  🔄 Falling back to traditional venv archive..."
        if download_and_extract \
            "$S3_USER_SHARED_BASE/venv.tar.gz" \
            "$NETWORK_VOLUME" \
            "User-shared 'venv' data (fallback)"; then
            venv_restored=true
            echo "  ✅ Traditional venv restoration successful"
        else
            echo "  ⚠️ All venv restoration methods failed"
            echo "  ℹ️ Will proceed without restored venvs - new environments will be created"
            venv_restored=false
        fi
    fi
fi

# Verify the restored venvs (if any) are functional
if [ "$venv_restored" = "true" ] && [ -d "$NETWORK_VOLUME/venv" ]; then
    echo "  🔍 Verifying restored venvs..."
    venv_count=0
    functional_venvs=0
    
    # Check each venv subdirectory
    for venv_dir in "$NETWORK_VOLUME/venv"/*; do
        if [ -d "$venv_dir" ]; then
            venv_count=$((venv_count + 1))
            venv_name=$(basename "$venv_dir")
            
            if [ -f "$venv_dir/bin/python" ] && "$venv_dir/bin/python" --version >/dev/null 2>&1; then
                echo "    ✅ $venv_name venv verified as functional"
                functional_venvs=$((functional_venvs + 1))
            else
                echo "    ⚠️ $venv_name venv appears corrupted - will be recreated during setup"
            fi
        fi
    done
    
    if [ $venv_count -gt 0 ]; then
        echo "  📊 Venv verification: $functional_venvs/$venv_count venvs are functional"
    else
        echo "  ℹ️ No venvs found in backup - will be created fresh"
    fi
fi

echo "--- Restoring Other User-Shared Data ---"
# Define the shared folders and their corresponding archive names
declare -A SHARED_FOLDERS_MAP=(
    [".comfyui"]="_comfyui.tar.gz"
    [".cache"]="_cache.tar.gz"
)

for folder_name in "${!SHARED_FOLDERS_MAP[@]}"; do
    archive_filename="${SHARED_FOLDERS_MAP[$folder_name]}"
    pod_local_path="$NETWORK_VOLUME/$folder_name"
    
    # Try network volume symlink first
    if try_symlink_from_network_volume "$folder_name" "$pod_local_path" "$folder_name data"; then
        echo "  ✅ $folder_name symlinked from network volume"
    else
        echo "  🔄 Network volume symlink failed for $folder_name, downloading from S3..."
        folder_description="${archive_filename%.tar.gz}"
        download_and_extract \
            "$S3_USER_SHARED_BASE/$archive_filename" \
            "$NETWORK_VOLUME" \
            "User-shared '$folder_description' data"
    fi
done

echo "--- Restoring ComfyUI User-Shared Data ---"
# Define ComfyUI shared folders that can be symlinked
COMFYUI_SHARED_FOLDERS=("custom_nodes")

for folder_name in "${COMFYUI_SHARED_FOLDERS[@]}"; do
    archive_filename="${folder_name}.tar.gz"
    pod_local_path="$NETWORK_VOLUME/ComfyUI/$folder_name"
    
    # Try network volume symlink first
    if try_symlink_from_network_volume "ComfyUI/$folder_name" "$pod_local_path" "ComfyUI $folder_name"; then
        echo "  ✅ ComfyUI $folder_name symlinked from network volume"
    else
        echo "  🔄 Network volume symlink failed for ComfyUI $folder_name, downloading from S3..."
        download_and_extract \
            "$S3_USER_COMFYUI_SHARED_BASE/$archive_filename" \
            "$NETWORK_VOLUME/ComfyUI" \
            "ComfyUI user-shared '$folder_name' data"
    fi
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

echo "📊 Restore Summary:"
if [ "$venv_restored" = "true" ]; then
    if [ -d "$NETWORK_VOLUME/venv" ]; then
        venv_count=$(find "$NETWORK_VOLUME/venv" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        if [ -L "$NETWORK_VOLUME/venv" ]; then
            echo "  📦 Virtual environments: $venv_count venv(s) symlinked from network volume"
        else
            echo "  📦 Virtual environments: $venv_count venv(s) restored from S3"
        fi
    fi
else
    echo "  📦 Virtual environments: No venvs restored - will be created fresh"
fi

# Report network volume optimizations
if [ "$NETWORK_VOLUME_AVAILABLE" = "true" ]; then
    symlinked_count=0
    downloaded_count=0
    
    # Check which folders are symlinked vs downloaded
    for folder in "venv" ".comfyui" ".cache" "ComfyUI/custom_nodes"; do
        local_path="$NETWORK_VOLUME/$folder"
        if [ -L "$local_path" ]; then
            symlinked_count=$((symlinked_count + 1))
        elif [ -d "$local_path" ]; then
            downloaded_count=$((downloaded_count + 1))
        fi
    done
    
    echo "  🔗 Network volume optimization: $symlinked_count folder(s) symlinked, $downloaded_count downloaded"
else
    echo "  📁 Network volume: Not available - all data downloaded from S3"
fi

echo "  📁 Other data: User-shared and pod-specific data restored"

echo "✅ User data sync from S3 (optimized) completed."