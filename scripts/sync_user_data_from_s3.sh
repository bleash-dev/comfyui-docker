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

# Source venv chunk manager if available
if [ -f "$NETWORK_VOLUME/scripts/venv_chunk_manager.sh" ]; then
    source "$NETWORK_VOLUME/scripts/venv_chunk_manager.sh"
    VENV_CHUNKS_AVAILABLE=true
else
    echo "⚠️ Venv chunk manager not found, using traditional method"
    VENV_CHUNKS_AVAILABLE=false
fi

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

# --- Helper Function: Download and Restore Chunked Venvs ---
download_and_restore_chunked_venvs() {
    local s3_chunks_base="$1"
    local local_venv_base_dir="$2"
    local description="$3"

    echo "ℹ️ Checking for chunked $description: $s3_chunks_base"

    # Check if any venv chunks are available
    if aws s3 ls "$s3_chunks_base/" >/dev/null 2>&1; then
        local venv_dirs_found
        venv_dirs_found=$(aws s3 ls "$s3_chunks_base/" --recursive \
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
# New multi-venv structure: S3 path is /venv_chunks/{venv_name}/ for each venv
# This allows multiple venvs to coexist and be restored independently
# Legacy single venv structure at /venv_chunks/ is still supported for backwards compatibility
# Try chunked venvs first, fall back to traditional archive
venv_restored=false

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
for archive_filename in "${OTHER_USER_SHARED_ARCHIVE_FILES[@]}"; do
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

echo "📊 Restore Summary:"
if [ "$venv_restored" = "true" ]; then
    if [ -d "$NETWORK_VOLUME/venv" ]; then
        venv_count=$(find "$NETWORK_VOLUME/venv" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        echo "  📦 Virtual environments: $venv_count venv(s) restored"
    fi
else
    echo "  📦 Virtual environments: No venvs restored - will be created fresh"
fi
echo "  📁 Other data: User-shared and pod-specific data restored from archives"

echo "✅ User data sync from S3 (optimized) completed."