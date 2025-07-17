#!/bin/bash
# Create all sync-related scripts (Simplified - No Hashing/Caching)

echo "📝 Creating simplified sync scripts (no checksum caching)..."

# User data sync script (Simplified)
cat > "$NETWORK_VOLUME/scripts/sync_user_data.sh" << 'EOF'
#!/bin/bash
# Sync user-specific data to S3 by zipping and uploading archives.
# This version syncs every time it is called.

# Source the sync lock manager, API client, and model sync integration for progress notifications
source "$NETWORK_VOLUME/scripts/sync_lock_manager.sh"
source "$NETWORK_VOLUME/scripts/api_client.sh"
source "$NETWORK_VOLUME/scripts/model_sync_integration.sh"

### REMOVED: All hash calculation and cache-checking functions ###

sync_user_data_internal() {
    # This script now always attempts to sync.
    echo "🔄 Syncing user data to S3 (archived)..."
    
    # Send initial progress notification
    notify_sync_progress "user_data" "PROGRESS" 0

    EXCLUDE_SHARED_FOLDERS=("venv" ".comfyui" ".cache") 
    EXCLUDE_COMFYUI_SHARED_FOLDERS=("models" "custom_nodes" ".browser-session")

    COMFYUI_POD_SPECIFIC_ARCHIVE_NAME="comfyui_pod_specific_data.tar.gz"
    S3_COMFYUI_POD_SPECIFIC_PATH="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/$COMFYUI_POD_SPECIFIC_ARCHIVE_NAME"
    TEMP_COMFYUI_STAGING_DIR=$(mktemp -d /tmp/comfyui_pod_staging.XXXXXX)
    COMFYUI_HAS_DATA_TO_SYNC=false

    if [[ -d "$NETWORK_VOLUME/ComfyUI" ]]; then
        echo "📦 Preparing ComfyUI pod-specific data for archival..."
        notify_sync_progress "user_data" "PROGRESS" 10
        
        shopt -s dotglob
        for item_path in "$NETWORK_VOLUME/ComfyUI"/*; do
            item_name=$(basename "$item_path")
            is_excluded=false
            for excluded in "${EXCLUDE_COMFYUI_SHARED_FOLDERS[@]}"; do
                if [[ "$item_name" == "$excluded" ]]; then
                    is_excluded=true
                    break
                fi
            done

            if [[ "$is_excluded" == "true" ]]; then
                echo "  ⏭️ Skipping ComfyUI shared/excluded item: $item_name"
                continue
            fi

            if [[ -d "$item_path" ]]; then
                if [[ -n "$(find "$item_path" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
                    echo "  ➕ Adding ComfyUI sub-folder to archive: $item_name"
                    cp -R "$item_path" "$TEMP_COMFYUI_STAGING_DIR/"
                    COMFYUI_HAS_DATA_TO_SYNC=true
                else
                    echo "  📭 Skipping empty ComfyUI sub-folder: $item_name"
                fi
            elif [[ -f "$item_path" ]]; then
                echo "  ➕ Adding ComfyUI root file to archive: $item_name"
                cp "$item_path" "$TEMP_COMFYUI_STAGING_DIR/"
                COMFYUI_HAS_DATA_TO_SYNC=true
            fi
        done
        
        notify_sync_progress "user_data" "PROGRESS" 30
        
        if [[ "$COMFYUI_HAS_DATA_TO_SYNC" == "true" ]]; then
            echo "  🗜️ Compressing ComfyUI pod-specific data..."
            TEMP_ARCHIVE_PATH="/tmp/$COMFYUI_POD_SPECIFIC_ARCHIVE_NAME"
            (cd "$TEMP_COMFYUI_STAGING_DIR" && tar -czf "$TEMP_ARCHIVE_PATH" .)
            
            notify_sync_progress "user_data" "PROGRESS" 40
            
            echo "  📤 Uploading $COMFYUI_POD_SPECIFIC_ARCHIVE_NAME to S3..."
            if sync_to_s3_with_progress "$TEMP_ARCHIVE_PATH" "$S3_COMFYUI_POD_SPECIFIC_PATH" "user_data" 1 2 "cp"; then
                echo "  ✅ Successfully uploaded $COMFYUI_POD_SPECIFIC_ARCHIVE_NAME"
            else
                echo "  ❌ Failed to sync $COMFYUI_POD_SPECIFIC_ARCHIVE_NAME"
            fi
            rm -f "$TEMP_ARCHIVE_PATH"
        else
            echo "  ℹ️ No ComfyUI pod-specific data found to sync."
        fi
    else
        echo "⏭️ ComfyUI directory not found, skipping ComfyUI pod-specific sync."
    fi
    rm -rf "$TEMP_COMFYUI_STAGING_DIR"
    echo "--- ComfyUI pod-specific sync finished ---"

    notify_sync_progress "user_data" "PROGRESS" 50

    OTHER_POD_SPECIFIC_ARCHIVE_NAME="other_pod_specific_data.tar.gz"
    S3_OTHER_POD_SPECIFIC_PATH="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/$OTHER_POD_SPECIFIC_ARCHIVE_NAME"
    TEMP_OTHER_STAGING_DIR=$(mktemp -d /tmp/other_pod_staging.XXXXXX)
    OTHER_HAS_DATA_TO_SYNC=false

    echo "📦 Preparing other pod-specific data for archival..."
    find "$NETWORK_VOLUME" -mindepth 1 -maxdepth 1 -type d | while read -r dir_path; do
        folder_name=$(basename "$dir_path")
        
        if [[ "$folder_name" == "ComfyUI" ]]; then
            continue
        fi
        
        is_excluded_shared=false
        for excluded in "${EXCLUDE_SHARED_FOLDERS[@]}"; do
            if [[ "$folder_name" == "$excluded" ]]; then
                is_excluded_shared=true
                break
            fi
        done
        if [[ "$is_excluded_shared" == "true" ]]; then
            echo "    ⏭️ Skipping user-shared folder: $folder_name (handled by shared sync)"
            continue
        fi
        
        if [[ "$folder_name" =~ ^\. ]] && [[ "$folder_name" != ".comfyui" ]] && [[ "$folder_name" != ".git" ]]; then 
            echo "    ⏭️ Skipping hidden folder: $folder_name"
            continue
        fi
            
        if [[ -n "$(find "$dir_path" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
            echo "    ➕ Adding folder to 'other' pod-specific archive: $folder_name"
            cp -R "$dir_path" "$TEMP_OTHER_STAGING_DIR/"
            OTHER_HAS_DATA_TO_SYNC=true
        else
            echo "    📭 Skipping empty folder: $folder_name"
        fi
    done

    if [[ "$OTHER_HAS_DATA_TO_SYNC" == "true" ]]; then
        echo "  🗜️ Compressing other pod-specific data..."
        TEMP_ARCHIVE_PATH="/tmp/$OTHER_POD_SPECIFIC_ARCHIVE_NAME"
        (cd "$TEMP_OTHER_STAGING_DIR" && tar -czf "$TEMP_ARCHIVE_PATH" .)
        
        notify_sync_progress "user_data" "PROGRESS" 80
        
        echo "  📤 Uploading $OTHER_POD_SPECIFIC_ARCHIVE_NAME to S3..."
        if sync_to_s3_with_progress "$TEMP_ARCHIVE_PATH" "$S3_OTHER_POD_SPECIFIC_PATH" "user_data" 2 2 "cp"; then
            echo "  ✅ Successfully uploaded $OTHER_POD_SPECIFIC_ARCHIVE_NAME"
        else
            echo "  ❌ Failed to sync $OTHER_POD_SPECIFIC_ARCHIVE_NAME"
        fi
        rm -f "$TEMP_ARCHIVE_PATH"
    else
        echo "  ℹ️ No other pod-specific data found to sync."
    fi
    rm -rf "$TEMP_OTHER_STAGING_DIR"
    echo "--- Other pod-specific sync finished ---"

    ### REMOVED: call to save_user_data_sync_state ###

    notify_sync_progress "user_data" "DONE" 100
    echo "✅ User data archive sync completed"
}

# Execute sync with lock management
execute_with_sync_lock "user_data" "sync_user_data_internal"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_user_data.sh"

# User shared data sync script (Simplified)
cat > "$NETWORK_VOLUME/scripts/sync_user_shared_data.sh" << 'EOF'
#!/bin/bash
# Sync user-shared data to S3 (data that persists across different pods for the same user)
# This version syncs every time it is called.

# Source the sync lock manager, API client, model sync integration, and venv chunk manager
source "$NETWORK_VOLUME/scripts/sync_lock_manager.sh"
source "$NETWORK_VOLUME/scripts/api_client.sh"
source "$NETWORK_VOLUME/scripts/model_sync_integration.sh"
source "$NETWORK_VOLUME/scripts/venv_chunk_manager.sh"

### REMOVED: All hash calculation and cache-checking functions ###

sync_user_shared_data_internal() {
    # This script now always attempts to sync.
    echo "🔄 Syncing user-shared data to S3 (optimized)..."

    # Send initial progress notification and ensure tools are available
    notify_sync_progress "user_data" "PROGRESS" 0

    S3_USER_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/shared"
    S3_USER_COMFYUI_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/ComfyUI/shared"

    # Separate venv handling from other folders for optimization
    OTHER_SHARED_FOLDERS=(".comfyui" ".cache")
    COMFYUI_USER_SHARED_FOLDERS_TO_ARCHIVE=("custom_nodes")

    # Use temp file for archive tracking instead of associative array for compatibility
    ARCHIVES_LIST_FILE="/tmp/user_shared_archives_$$"
    > "$ARCHIVES_LIST_FILE"

    # Handle all venvs with chunked optimization
    # New structure: S3 path becomes /venv_chunks/{venv_name}/ for each venv
    # This allows multiple venvs to coexist and be synced independently
    # Legacy single venv structure at /venv_chunks/ is still supported for backwards compatibility
    local venv_base_dir="$NETWORK_VOLUME/venv"
    if [[ -d "$venv_base_dir" ]]; then
        echo "📦 Processing venvs with chunked optimization..."
        notify_sync_progress "user_data" "PROGRESS" 10
        
        local venv_processed=false
        local venv_failures=()
        
        # Process each venv subdirectory
        for venv_dir in "$venv_base_dir"/*; do
            if [[ -d "$venv_dir" ]] && [[ -n "$(find "$venv_dir" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
                local venv_name=$(basename "$venv_dir")
                echo "  📦 Processing venv: $venv_name"
                
                # Use chunked upload for this venv
                local s3_venv_chunks_path="$S3_USER_SHARED_BASE/venv_chunks/$venv_name"
                if chunk_and_upload_venv "$venv_dir" "$s3_venv_chunks_path" "user_shared"; then
                    echo "    ✅ Successfully uploaded $venv_name venv using chunked method"
                    venv_processed=true
                else
                    echo "    ⚠️ Chunked $venv_name venv upload failed, adding to fallback queue"
                    venv_failures+=("$venv_name")
                fi
            fi
        done
        
        # Clean up legacy single venv chunk structure if we successfully uploaded using new structure
        if [[ "$venv_processed" == true ]]; then
            echo "  🧹 Cleaning up legacy single venv chunk structure..."
            local legacy_venv_chunks_path="$S3_USER_SHARED_BASE/venv_chunks"
            # Check if legacy chunks exist at the root level (not in subdirectories)
            if aws s3 ls "$legacy_venv_chunks_path/" 2>/dev/null | grep -q "venv_chunk_.*\.tar\.gz"; then
                echo "    🗑️ Removing legacy venv chunks to avoid duplication..."
                aws s3 rm "$legacy_venv_chunks_path" --recursive --exclude "*/" --include "venv_chunk_*" --quiet 2>/dev/null || true
                aws s3 rm "$legacy_venv_chunks_path/venv_chunks.checksums" --quiet 2>/dev/null || true
                aws s3 rm "$legacy_venv_chunks_path/source.checksum" --quiet 2>/dev/null || true
                aws s3 rm "$legacy_venv_chunks_path/venv_other_folders.zip" --quiet 2>/dev/null || true
                echo "    ✅ Legacy venv chunks cleaned up"
            fi
        fi
        
        # Handle failed venvs with traditional archive method (fallback)
        if [[ ${#venv_failures[@]} -gt 0 ]]; then
            echo "  🔄 Using traditional archive method for failed venvs: ${venv_failures[*]}"
            local archive_name="venv.tar.gz"
            local temp_archive_path="/tmp/user_shared_${archive_name}"
            echo "    🗜️ Compressing venv with traditional method..."
            if tar -czf "$temp_archive_path" -C "$NETWORK_VOLUME" "venv"; then
                echo "$temp_archive_path|$S3_USER_SHARED_BASE/$archive_name" >> "$ARCHIVES_LIST_FILE"
                echo "    📝 Added venv to upload queue (fallback method)"
            else
                echo "    ❌ Failed to compress venv"
            fi
        fi
        
        if [[ "$venv_processed" == false ]] && [[ ${#venv_failures[@]} -eq 0 ]]; then
            echo "  ⏭️ No venvs found to process"
        fi
    else
        echo "  ⏭️ Skipping venv (directory missing)"
    fi

    notify_sync_progress "user_data" "PROGRESS" 40

    echo "🗜️ Archiving other user-shared folders..."
    for folder_name in "${OTHER_SHARED_FOLDERS[@]}"; do
        local_folder_path="$NETWORK_VOLUME/$folder_name"
        safe_folder_name="${folder_name#.}"
        [[ "$folder_name" == .* ]] && safe_folder_name="_${safe_folder_name}"
        archive_name="${safe_folder_name//\//_}.tar.gz"
        temp_archive_path="/tmp/user_shared_${archive_name}"

        if [[ -d "$local_folder_path" ]] && [[ -n "$(find "$local_folder_path" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
            echo "  🗜️ Compressing $folder_name..."
            if tar -czf "$temp_archive_path" -C "$NETWORK_VOLUME" "$folder_name"; then
                echo "$temp_archive_path|$S3_USER_SHARED_BASE/$archive_name" >> "$ARCHIVES_LIST_FILE"
            else
                echo "  ❌ Failed to compress $folder_name"
                rm -f "$temp_archive_path"
            fi
        else
            echo "  ⏭️ Skipping $folder_name (missing or empty)"
        fi
    done

    echo "🗜️ Archiving ComfyUI-shared folders..."
    for folder_name in "${COMFYUI_USER_SHARED_FOLDERS_TO_ARCHIVE[@]}"; do
        local_folder_path="$NETWORK_VOLUME/ComfyUI/$folder_name"
        archive_name="${folder_name//\//_}.tar.gz"
        temp_archive_path="/tmp/comfyui_shared_${archive_name}"

        if [[ -d "$local_folder_path" ]] && [[ -n "$(find "$local_folder_path" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
            echo "  🗜️ Compressing ComfyUI/$folder_name..."
            if tar -czf "$temp_archive_path" -C "$NETWORK_VOLUME/ComfyUI" "$folder_name"; then
                echo "$temp_archive_path|$S3_USER_COMFYUI_SHARED_BASE/$archive_name" >> "$ARCHIVES_LIST_FILE"
            else
                echo "  ❌ Failed to compress ComfyUI/$folder_name"
                rm -f "$temp_archive_path"
            fi
        else
            echo "  ⏭️ Skipping ComfyUI/$folder_name (missing or empty)"
        fi
    done

    notify_sync_progress "user_data" "PROGRESS" 60

    total_archives=$(wc -l < "$ARCHIVES_LIST_FILE" 2>/dev/null || echo "0")
    
    if [ "$total_archives" -gt 0 ]; then
        processed_archives=0

        echo "📤 Uploading archived user-shared data to S3 ($total_archives total)..."
        while IFS='|' read -r archive_path s3_dest; do
            if [[ -n "$archive_path" && -n "$s3_dest" ]]; then
                archive_name="$(basename "$archive_path")"

                echo "  📤 Uploading $archive_name to $s3_dest..."
                if sync_to_s3_with_progress "$archive_path" "$s3_dest" "user_data" $((processed_archives + 1)) "$total_archives" "cp"; then
                    echo "  ✅ Successfully uploaded $archive_name"
                else
                    echo "  ❌ Failed to upload $archive_name"
                fi
                rm -f "$archive_path"

                processed_archives=$((processed_archives + 1))
                # Calculate progress from 60% to 95%
                local upload_progress=$((60 + (processed_archives * 35 / total_archives)))
                notify_sync_progress "user_data" "PROGRESS" "$upload_progress"
            fi
        done < "$ARCHIVES_LIST_FILE"
    else
        echo "ℹ️ No additional archives to upload"
        notify_sync_progress "user_data" "PROGRESS" 95
    fi

    # Clean up temp file
    rm -f "$ARCHIVES_LIST_FILE"

    ### REMOVED: call to save_user_shared_sync_state ###

    # Summary of sync operation
    echo "📊 Sync Summary:"
    if [[ "$venv_processed" == true ]]; then
        local venv_count=$(find "$NETWORK_VOLUME/venv" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        echo "  📦 Virtual environments: $venv_count venv(s) synced using chunked optimization"
    fi
    if [[ ${#venv_failures[@]} -gt 0 ]]; then
        echo "  ⚠️ Failed venvs: ${#venv_failures[@]} venv(s) fell back to traditional archive method"
    fi
    if [ "$total_archives" -gt 0 ]; then
        echo "  📁 Traditional archives: $total_archives archive(s) uploaded"
    fi
    
    notify_sync_progress "user_data" "DONE" 100
    echo "✅ User-shared data sync completed (optimized)"
}

# Execute sync with lock management
execute_with_sync_lock "user_shared" "sync_user_shared_data_internal"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_user_shared_data.sh"

# Graceful shutdown script (unchanged)
cat > "$NETWORK_VOLUME/scripts/graceful_shutdown.sh" << 'EOF'
#!/bin/bash
# Graceful shutdown with data sync (no mounting)

echo "🛑 Graceful shutdown initiated at $(date)"

# Source sync lock manager for cleanup
if [ -f "$NETWORK_VOLUME/scripts/sync_lock_manager.sh" ]; then
    source "$NETWORK_VOLUME/scripts/sync_lock_manager.sh"
fi

if [ -f "/tmp/pod_tracker.pid" ]; then
    POD_TRACKER_PID=$(cat /tmp/pod_tracker.pid)
    if [ -n "$POD_TRACKER_PID" ] && kill -0 "$POD_TRACKER_PID" 2>/dev/null; then
        echo "🕐 Stopping pod execution tracker..."
        kill -TERM "$POD_TRACKER_PID" 2>/dev/null || true; sleep 3; kill -9 "$POD_TRACKER_PID" 2>/dev/null || true
    fi; rm -f /tmp/pod_tracker.pid
fi

BACKGROUND_PIDS_FILE="$NETWORK_VOLUME/.background_services.pids"
if [ -f "$BACKGROUND_PIDS_FILE" ]; then
    echo "🔄 Stopping background services from PID file..."
    while IFS=':' read -r service_name pid; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "  Stopping $service_name (PID: $pid)..."
            kill -TERM "$pid" 2>/dev/null || true; sleep 1
            if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
        else echo "  $service_name (PID: $pid) already stopped or invalid"; fi
    done < "$BACKGROUND_PIDS_FILE"; rm -f "$BACKGROUND_PIDS_FILE"
else
    echo "⚠️ No background services PID file found, using fallback cleanup..."
    pkill -f "$NETWORK_VOLUME/scripts/" 2>/dev/null || true
fi

echo "🔄 Performing final data sync..."
# Use shorter timeout for final sync to avoid hanging shutdown
export SYNC_LOCK_TIMEOUT=600  # 1 minute timeout for shutdown syncs
[ -f "$NETWORK_VOLUME/scripts/sync_logs.sh" ] && "$NETWORK_VOLUME/scripts/sync_logs.sh"
[ -f "$NETWORK_VOLUME/scripts/sync_user_data.sh" ] && "$NETWORK_VOLUME/scripts/sync_user_data.sh"
[ -f "$NETWORK_VOLUME/scripts/sync_user_shared_data.sh" ] && "$NETWORK_VOLUME/scripts/sync_user_shared_data.sh"
[ -f "$NETWORK_VOLUME/scripts/sync_global_shared_models.sh" ] && "$NETWORK_VOLUME/scripts/sync_global_shared_models.sh"
[ -f "$NETWORK_VOLUME/scripts/sync_comfyui_assets.sh" ] && "$NETWORK_VOLUME/scripts/sync_comfyui_assets.sh"
[ -f "$NETWORK_VOLUME/scripts/sync_pod_metadata.sh" ] && "$NETWORK_VOLUME/scripts/sync_pod_metadata.sh"

# Force cleanup any remaining sync locks
if [ -d "$NETWORK_VOLUME/.sync_locks" ]; then
    echo "🧹 Cleaning up any remaining sync locks..."
    rm -rf "$NETWORK_VOLUME/.sync_locks"
fi

pkill -f "aws" 2>/dev/null || true
echo "✅ Graceful shutdown completed"
EOF

chmod +x "$NETWORK_VOLUME/scripts/graceful_shutdown.sh"

# Signal handler script (unchanged)
cat > "$NETWORK_VOLUME/scripts/signal_handler.sh" << 'EOF'
#!/bin/bash
# Signal handler for graceful shutdown
handle_signal() {
    echo "📢 Received shutdown signal, initiating graceful shutdown..."
    BACKGROUND_PIDS_FILE="$NETWORK_VOLUME/.background_services.pids"
    if [ -f "$BACKGROUND_PIDS_FILE" ]; then
        echo "🔄 Sending termination signals to background services..."
        while IFS=':' read -r service_name pid; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo "  Signaling $service_name (PID: $pid)..."; kill -TERM "$pid" 2>/dev/null || true; fi
        done < "$BACKGROUND_PIDS_FILE"; sleep 3
        while IFS=':' read -r service_name pid; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo "  Force killing $service_name (PID: $pid)..."; kill -9 "$pid" 2>/dev/null || true; fi
        done < "$BACKGROUND_PIDS_FILE"
    fi
    "$NETWORK_VOLUME/scripts/graceful_shutdown.sh"; exit 0
}
trap handle_signal SIGTERM SIGINT SIGQUIT
echo "📡 Signal handler active, waiting for signals..."; while true; do sleep 1; done
EOF

chmod +x "$NETWORK_VOLUME/scripts/signal_handler.sh"

# Global shared models sync script (unchanged - its sync logic is already robust)
cat > "$NETWORK_VOLUME/scripts/sync_global_shared_models.sh" << 'EOF'
#!/bin/bash
# Sync global shared models and browser session to S3 with API integration and progress reporting

# Source the sync lock manager and model sync integration
source "$NETWORK_VOLUME/scripts/sync_lock_manager.sh"
source "$NETWORK_VOLUME/scripts/model_sync_integration.sh"

sync_global_shared_models_internal() {
    echo "🌐 Syncing global shared resources to S3..."
    
    S3_GLOBAL_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/global_shared/models"
    S3_BROWSER_SESSIONS_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/global_shared/.browser-session"
    LOCAL_MODELS_BASE="$NETWORK_VOLUME/ComfyUI/models"
    LOCAL_BROWSER_SESSIONS_BASE="$NETWORK_VOLUME/ComfyUI/.browser-session"

    # Send initial progress notification
    notify_model_sync_progress "global_shared" "PROGRESS" 0

    # Sync models with API integration using batch processing
    if [[ ! -d "$LOCAL_MODELS_BASE" ]]; then
        echo "⏭️ No models directory found at $LOCAL_MODELS_BASE"
        notify_model_sync_progress "global_shared" "PROGRESS" 80
    else
        echo "📁 Processing global shared models with API integration..."
        
        # Use batch processing for models - this handles API checks, config updates, and progress
        if batch_process_models "$LOCAL_MODELS_BASE" "$S3_GLOBAL_SHARED_BASE" "global_shared"; then
            echo "✅ Model batch processing and sync completed successfully"
        else
            echo "⚠️ Model batch processing completed with some errors"
        fi
        
        notify_model_sync_progress "global_shared" "PROGRESS" 80
    fi

    # Sync browser sessions (non-model data)
    if [[ -d "$LOCAL_BROWSER_SESSIONS_BASE" ]]; then
        if [[ -n "$(find "$LOCAL_BROWSER_SESSIONS_BASE" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
            echo "🌐 Syncing global shared browser sessions to S3..."
            echo "  📤 Syncing browser sessions to $S3_BROWSER_SESSIONS_BASE/"
            # Use sync_to_s3_with_progress for better progress tracking
            if sync_to_s3_with_progress "$LOCAL_BROWSER_SESSIONS_BASE" "$S3_BROWSER_SESSIONS_BASE/" "global_shared" 1 1 "sync"; then
                echo "  ✅ Successfully synced global browser sessions"
            else
                echo "  ❌ Failed to sync global browser sessions"
            fi
        else
            echo "  📭 Skipping empty browser sessions directory"
        fi
    else
        echo "ℹ️ No browser sessions directory found at $LOCAL_BROWSER_SESSIONS_BASE"
    fi

    # Send completion notification
    notify_model_sync_progress "global_shared" "DONE" 100
    echo "✅ Global shared resources sync completed"
}

# Execute sync with lock management
execute_with_sync_lock "global_shared" "sync_global_shared_models_internal"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_global_shared_models.sh"

# ComfyUI assets sync script (Simplified)
cat > "$NETWORK_VOLUME/scripts/sync_comfyui_assets.sh" << 'EOF'
#!/bin/bash
# Sync ComfyUI input/output directories to S3 (one-way: pod to S3 only, with deletions)
# This version syncs every time it is called.

# Source the sync lock manager, API client, and model sync integration for progress notifications
source "$NETWORK_VOLUME/scripts/sync_lock_manager.sh"
source "$NETWORK_VOLUME/scripts/api_client.sh"
source "$NETWORK_VOLUME/scripts/model_sync_integration.sh"

### REMOVED: All hash calculation and cache-checking functions ###

sync_comfyui_assets_internal() {
    # This script now always attempts to sync.
    echo "📁 Syncing ComfyUI assets to S3..."
    
    # Send initial progress notification and ensure tools are available
    notify_sync_progress "user_assets" "PROGRESS" 0
    S3_ASSETS_BASE="s3://$AWS_BUCKET_NAME/assets/$POD_ID"
    LOCAL_INPUT_DIR="$NETWORK_VOLUME/ComfyUI/input"
    LOCAL_OUTPUT_DIR="$NETWORK_VOLUME/ComfyUI/output"

    # Sync input directory (with delete to reflect local deletions)
    if [[ -d "$LOCAL_INPUT_DIR" ]]; then
        echo "  📤 Syncing input assets to S3 (with deletions)..."
        notify_sync_progress "user_assets" "PROGRESS" 25
        s3_input_path="$S3_ASSETS_BASE/input/"
        
        # Use aws s3 sync directly with proper error handling
        if aws s3 sync "$LOCAL_INPUT_DIR" "$s3_input_path" --delete --only-show-errors; then
            echo "  ✅ Successfully synced input assets"
        else
            echo "  ❌ Failed to sync input assets"
        fi
    else
        echo "ℹ️ No input directory found at $LOCAL_INPUT_DIR"
        notify_sync_progress "user_assets" "PROGRESS" 25
        # If local directory doesn't exist, optionally delete all S3 content
        s3_input_path="$S3_ASSETS_BASE/input/"
        if aws s3 ls "$s3_input_path" >/dev/null 2>&1; then
            echo "  🗑️ Local input directory missing, cleaning S3 input directory..."
            aws s3 rm "$s3_input_path" --recursive --only-show-errors || \
                echo "  ⚠️ Failed to clean S3 input directory"
        fi
    fi

    # Sync output directory (with delete to reflect local deletions)
    notify_sync_progress "user_assets" "PROGRESS" 50
    if [[ -d "$LOCAL_OUTPUT_DIR" ]]; then
        echo "  📤 Syncing output assets to S3 (with deletions)..."
        s3_output_path="$S3_ASSETS_BASE/output/"
        
        # Use aws s3 sync directly with proper error handling
        if aws s3 sync "$LOCAL_OUTPUT_DIR" "$s3_output_path" --only-show-errors; then
            echo "  ✅ Successfully synced output assets"
        else
            echo "  ❌ Failed to sync output assets"
        fi
    else
        echo "ℹ️ No output directory found at $LOCAL_OUTPUT_DIR"
        # If local directory doesn't exist, optionally delete all S3 content
        s3_output_path="$S3_ASSETS_BASE/output/"
        if aws s3 ls "$s3_output_path" >/dev/null 2>&1; then
            echo "  🗑️ Local output directory missing, cleaning S3 output directory..."
            aws s3 rm "$s3_output_path" --recursive --only-show-errors || \
                echo "  ⚠️ Failed to clean S3 output directory"
        fi
    fi

    ### REMOVED: call to save_assets_sync_state ###

    notify_sync_progress "user_assets" "DONE" 100
    echo "✅ ComfyUI assets sync completed"
    }

# Execute sync with lock management
execute_with_sync_lock "user_assets" "sync_comfyui_assets_internal"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_comfyui_assets.sh"

# Pod metadata sync script (Simplified)
cat > "$NETWORK_VOLUME/scripts/sync_pod_metadata.sh" << 'EOF'
#!/bin/bash
# Sync pod metadata to S3 (model configuration and user workflows)
# This version syncs every time it is called.

# Source the sync lock manager, API client, and model sync integration for progress notifications
source "$NETWORK_VOLUME/scripts/sync_lock_manager.sh"
source "$NETWORK_VOLUME/scripts/api_client.sh"
source "$NETWORK_VOLUME/scripts/model_sync_integration.sh"


sync_pod_metadata_internal() {
    # This script now always attempts to sync.
    echo "📋 Syncing pod metadata to S3..."
    
    # Send initial progress notification and ensure tools are available
    notify_sync_progress "pod_metadata" "PROGRESS" 0

    S3_METADATA_BASE="s3://$AWS_BUCKET_NAME/metadata/$POD_ID"
    LOCAL_MODEL_CONFIG="$NETWORK_VOLUME/ComfyUI/models_config.json"
    LOCAL_WORKFLOWS_DIR="$NETWORK_VOLUME/ComfyUI/user/default/workflows"

    # Sync model configuration file
    if [[ -f "$LOCAL_MODEL_CONFIG" ]]; then
        echo "  📤 Syncing model configuration to S3..."
        notify_sync_progress "pod_metadata" "PROGRESS" 25
        s3_config_path="$S3_METADATA_BASE/models_config.json"
        
        # Use sync_to_s3_with_progress for better progress tracking
        if sync_to_s3_with_progress "$LOCAL_MODEL_CONFIG" "$s3_config_path" "pod_metadata" 1 2 "cp"; then
            echo "  ✅ Successfully synced model configuration"
        else
            echo "  ❌ Failed to sync model configuration"
        fi
    else
        echo "ℹ️ No model configuration file found at $LOCAL_MODEL_CONFIG"
        notify_sync_progress "pod_metadata" "PROGRESS" 25
    fi

    # Sync workflows directory
    if [[ -d "$LOCAL_WORKFLOWS_DIR" ]]; then
        if [[ -n "$(find "$LOCAL_WORKFLOWS_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
            echo "  📤 Syncing user workflows to S3..."
            notify_sync_progress "pod_metadata" "PROGRESS" 50
            s3_workflows_path="$S3_METADATA_BASE/workflows/"
            
            # Use sync_to_s3_with_progress for better progress tracking
            if sync_to_s3_with_progress "$LOCAL_WORKFLOWS_DIR" "$s3_workflows_path" "pod_metadata" 2 3 "sync-delete"; then
                echo "  ✅ Successfully synced user workflows"
            else
                echo "  ❌ Failed to sync user workflows"
            fi
            notify_sync_progress "pod_metadata" "PROGRESS" 90
        else
            echo "  📭 Skipping empty workflows directory"
            notify_sync_progress "pod_metadata" "PROGRESS" 90
        fi
    else
        echo "ℹ️ No workflows directory found at $LOCAL_WORKFLOWS_DIR"
        notify_sync_progress "pod_metadata" "PROGRESS" 90
        # If local directory doesn't exist, optionally clean S3 workflows directory
        s3_workflows_path="$S3_METADATA_BASE/workflows/"
        if aws s3 ls "$s3_workflows_path" >/dev/null 2>&1; then
            echo "  🗑️ Local workflows directory missing, cleaning S3 workflows directory..."
            aws s3 rm "$s3_workflows_path" --recursive --only-show-errors || \
                echo "  ⚠️ Failed to clean S3 workflows directory"
        fi
    fi

    ### REMOVED: call to save_metadata_sync_state ###

    notify_sync_progress "pod_metadata" "DONE" 100
    echo "✅ Pod metadata sync completed"
}

# Execute sync with lock management
execute_with_sync_lock "pod_metadata" "sync_pod_metadata_internal"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_pod_metadata.sh"

# Models config file watcher script (unchanged - its logic is beneficial)
cat > "$NETWORK_VOLUME/scripts/models_config_watcher.sh" << 'EOF'
#!/bin/bash
# File watcher for models_config.json to auto-trigger global models sync on configuration changes

# Configuration
MODELS_CONFIG_FILE="$NETWORK_VOLUME/ComfyUI/models_config.json"
WATCHER_PID_FILE="$NETWORK_VOLUME/.models_config_watcher.pid"
WATCHER_LOG_FILE="$NETWORK_VOLUME/.models_config_watcher.log"
WATCHER_STATE_FILE="$NETWORK_VOLUME/.models_config_watcher.state"
SYNC_TRIGGER_COOLDOWN=10  # Minimum seconds between sync triggers

# Ensure log file exists
mkdir -p "$(dirname "$WATCHER_LOG_FILE")"
touch "$WATCHER_LOG_FILE"

# Function to log watcher activities
log_watcher() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] Config Watcher: $message" | tee -a "$WATCHER_LOG_FILE" >&2
}

# Function to get file modification time
get_file_mtime() {
    local file="$1"
    if [ -f "$file" ]; then
        stat -f%m "$file" 2>/dev/null || stat -c%Y "$file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Function to get file content hash
get_file_hash() {
    local file="$1"
    if [ -f "$file" ]; then
        sha256sum "$file" 2>/dev/null | cut -d' ' -f1 || echo "missing"
    else
        echo "missing"
    fi
}

# Function to check if sync cooldown period has passed
can_trigger_sync() {
    local current_time=$(date +%s)
    local last_trigger_time=0
    
    if [ -f "$WATCHER_STATE_FILE" ]; then
        last_trigger_time=$(jq -r '.lastTriggerTime // 0' "$WATCHER_STATE_FILE" 2>/dev/null || echo "0")
    fi
    
    local time_since_last=$((current_time - last_trigger_time))
    
    if [ "$time_since_last" -ge "$SYNC_TRIGGER_COOLDOWN" ]; then
        return 0  # Can trigger
    else
        local remaining=$((SYNC_TRIGGER_COOLDOWN - time_since_last))
        log_watcher "DEBUG" "Sync cooldown active, ${remaining}s remaining"
        return 1  # Cannot trigger yet
    fi
}

# Function to update watcher state
update_watcher_state() {
    local file_hash="$1"
    local trigger_time="$2"
    
    local state_data
    state_data=$(jq -n \
        --arg fileHash "$file_hash" \
        --argjson triggerTime "$trigger_time" \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")" \
        '{
            lastFileHash: $fileHash,
            lastTriggerTime: $triggerTime,
            lastUpdated: $timestamp
        }')
    
    echo "$state_data" > "$WATCHER_STATE_FILE"
}

# Function to trigger global models sync
trigger_global_models_sync() {
    local reason="$1"
    local current_time=$(date +%s)
    
    log_watcher "INFO" "Triggering global models sync: $reason"
    
    # Check if sync script exists
    if [ ! -f "$NETWORK_VOLUME/scripts/sync_global_shared_models.sh" ]; then
        log_watcher "ERROR" "Global models sync script not found"
        return 1
    fi
    
    # Update state before triggering sync to prevent rapid re-triggers
    local current_hash
    current_hash=$(get_file_hash "$MODELS_CONFIG_FILE")
    update_watcher_state "$current_hash" "$current_time"
    
    # Trigger sync in background with output capture
    (
        log_watcher "INFO" "Starting background global models sync"
        if "$NETWORK_VOLUME/scripts/sync_global_shared_models.sh" >> "$WATCHER_LOG_FILE" 2>&1; then
            log_watcher "INFO" "Global models sync completed successfully"
        else
            log_watcher "ERROR" "Global models sync failed"
        fi
    ) &
    
    local sync_pid=$!
    log_watcher "INFO" "Global models sync started in background (PID: $sync_pid)"
    
    return 0
}

# Function to start file watcher
start_watcher() {
    # Check if watcher is already running
    if [ -f "$WATCHER_PID_FILE" ]; then
        local existing_pid
        existing_pid=$(cat "$WATCHER_PID_FILE" 2>/dev/null || echo "")
        if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
            log_watcher "INFO" "Watcher already running (PID: $existing_pid)"
            return 0
        else
            log_watcher "INFO" "Removing stale PID file"
            rm -f "$WATCHER_PID_FILE"
        fi
    fi
    
    # Start watcher in background
    (
        # Write PID and setup cleanup
        echo $$ > "$WATCHER_PID_FILE"
        trap "rm -f '$WATCHER_PID_FILE'; exit 0" EXIT INT TERM QUIT
        
        log_watcher "INFO" "Models config file watcher started (PID: $$)"
        log_watcher "INFO" "Monitoring: $MODELS_CONFIG_FILE"
        
        # Initialize state
        local last_hash
        last_hash=$(get_file_hash "$MODELS_CONFIG_FILE")
        local last_mtime
        last_mtime=$(get_file_mtime "$MODELS_CONFIG_FILE")
        
        # Load previous state if available
        local previous_hash=""
        if [ -f "$WATCHER_STATE_FILE" ]; then
            previous_hash=$(jq -r '.lastFileHash // ""' "$WATCHER_STATE_FILE" 2>/dev/null || echo "")
        fi
        
        # Trigger initial sync if file exists and hash differs from previous state
        if [ -f "$MODELS_CONFIG_FILE" ] && [ "$last_hash" != "$previous_hash" ] && [ -n "$previous_hash" ]; then
            log_watcher "INFO" "Models config changed since last watcher run"
            if can_trigger_sync; then
                trigger_global_models_sync "Initial change detection"
            fi
        fi
        
        # Main watcher loop
        while true; do
            if [ ! -f "$MODELS_CONFIG_FILE" ]; then
                # File doesn't exist, wait for it to be created
                sleep 2
                continue
            fi
            
            local current_hash
            current_hash=$(get_file_hash "$MODELS_CONFIG_FILE")
            local current_mtime
            current_mtime=$(get_file_mtime "$MODELS_CONFIG_FILE")
            
            # Check if file has changed (both hash and mtime for reliability)
            if [ "$current_hash" != "$last_hash" ] || [ "$current_mtime" != "$last_mtime" ]; then
                log_watcher "INFO" "Models config file changed detected"
                log_watcher "DEBUG" "Hash: $last_hash -> $current_hash"
                log_watcher "DEBUG" "MTime: $last_mtime -> $current_mtime"
                
                # Wait for file to stabilize (handle multiple rapid writes)
                sleep 1
                local stable_hash
                stable_hash=$(get_file_hash "$MODELS_CONFIG_FILE")
                
                if [ "$stable_hash" = "$current_hash" ] && can_trigger_sync; then
                    trigger_global_models_sync "File modification detected"
                    last_hash="$stable_hash"
                    last_mtime=$(get_file_mtime "$MODELS_CONFIG_FILE")
                elif [ "$stable_hash" != "$current_hash" ]; then
                    log_watcher "DEBUG" "File still changing, waiting for stabilization"
                fi
            fi
            
            # Check every 2 seconds
            sleep 2
        done
    ) &
    
    local watcher_pid=$!
    
    # Give watcher a moment to start and write PID file
    sleep 0.5
    
    if kill -0 "$watcher_pid" 2>/dev/null; then
        log_watcher "INFO" "Models config file watcher started successfully (PID: $watcher_pid)"
        return 0
    else
        log_watcher "ERROR" "Failed to start models config file watcher"
        return 1
    fi
}

# Function to stop file watcher
stop_watcher() {
    log_watcher "INFO" "Stopping models config file watcher"
    
    if [ -f "$WATCHER_PID_FILE" ]; then
        local pid
        pid=$(cat "$WATCHER_PID_FILE" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log_watcher "INFO" "Stopping watcher process (PID: $pid)"
            kill -TERM "$pid" 2>/dev/null || true
            
            # Wait for graceful shutdown
            local wait_count=0
            while [ $wait_count -lt 5 ] && kill -0 "$pid" 2>/dev/null; do
                sleep 1
                wait_count=$((wait_count + 1))
            done
            
            # Force kill if still running
            if kill -0 "$pid" 2>/dev/null; then
                log_watcher "WARN" "Force killing watcher process (PID: $pid)"
                kill -KILL "$pid" 2>/dev/null || true
            fi
            
            log_watcher "INFO" "Watcher stopped successfully"
        fi
        rm -f "$WATCHER_PID_FILE"
    else
        log_watcher "INFO" "No watcher PID file found"
    fi
    
    return 0
}

# Function to get watcher status
get_watcher_status() {
    local output_file="${1:-}"
    if [ -z "$output_file" ]; then
        output_file=$(mktemp)
    fi
    
    local status="stopped"
    local pid=""
    local monitoring_file=""
    local last_trigger=""
    
    if [ -f "$WATCHER_PID_FILE" ]; then
        pid=$(cat "$WATCHER_PID_FILE" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            status="running"
            monitoring_file="$MODELS_CONFIG_FILE"
        else
            status="stale"
        fi
    fi
    
    if [ -f "$WATCHER_STATE_FILE" ]; then
        last_trigger=$(jq -r '.lastUpdated // ""' "$WATCHER_STATE_FILE" 2>/dev/null || echo "")
    fi
    
    jq -n \
        --arg status "$status" \
        --arg pid "$pid" \
        --arg monitoringFile "$monitoring_file" \
        --arg lastTrigger "$last_trigger" \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")" \
        '{
            status: $status,
            pid: $pid,
            monitoringFile: $monitoringFile,
            lastTrigger: $lastTrigger,
            timestamp: $timestamp
        }' > "$output_file"
    
    echo "$output_file"
}

# Function to restart watcher (stop + start)
restart_watcher() {
    log_watcher "INFO" "Restarting models config file watcher"
    stop_watcher
    sleep 1
    start_watcher
}

# Main command handling
case "${1:-}" in
    "start")
        start_watcher
        ;;
    "stop")
        stop_watcher
        ;;
    "restart")
        restart_watcher
        ;;
    "status")
        get_watcher_status
        ;;
    "trigger")
        # Manual trigger for testing
        if can_trigger_sync; then
            trigger_global_models_sync "Manual trigger"
        else
            log_watcher "INFO" "Cannot trigger sync - cooldown period active"
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|trigger}"
        echo "Models Config File Watcher - Auto-triggers global models sync on configuration changes"
        exit 1
        ;;
esac
EOF

chmod +x "$NETWORK_VOLUME/scripts/models_config_watcher.sh"

echo "✅ Simplified sync scripts created"