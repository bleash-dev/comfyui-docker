#!/bin/bash
# Create all sync-related scripts

echo "📝 Creating sync scripts..."

# User data sync script (sync_user_data.sh - from previous correct version)
cat > "$NETWORK_VOLUME/scripts/sync_user_data.sh" << 'EOF'
#!/bin/bash
# Sync user-specific data to S3 by zipping and uploading archives

# Source the sync lock manager, API client, and model sync integration for progress notifications
source "$NETWORK_VOLUME/scripts/sync_lock_manager.sh"
source "$NETWORK_VOLUME/scripts/api_client.sh"
source "$NETWORK_VOLUME/scripts/model_sync_integration.sh"

sync_user_data_internal() {
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
        # Use sync_to_s3_with_progress for better progress tracking
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
    # echo "  🔎 Checking top-level folder: $folder_name" # Optional: Less verbose
    
    if [[ "$folder_name" == "ComfyUI" ]]; then
        # echo "    ⏭️ Skipping ComfyUI (handled separately)." # Optional: Less verbose
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
    # Use sync_to_s3_with_progress for better progress tracking
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

notify_sync_progress "user_data" "DONE" 100
echo "✅ User data archive sync completed"
}

# Execute sync with lock management
execute_with_sync_lock "user_data" "sync_user_data_internal"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_user_data.sh"

# User shared data sync script (CORRECTED)
cat > "$NETWORK_VOLUME/scripts/sync_user_shared_data.sh" << 'EOF'
#!/bin/bash
# Sync user-shared data to S3 (data that persists across different pods for the same user)
# This script uses optimized chunking for venv and archives for other folders.

# Source the sync lock manager, API client, model sync integration, and venv chunk manager
source "$NETWORK_VOLUME/scripts/sync_lock_manager.sh"
source "$NETWORK_VOLUME/scripts/api_client.sh"
source "$NETWORK_VOLUME/scripts/model_sync_integration.sh"
source "$NETWORK_VOLUME/scripts/venv_chunk_manager.sh"

sync_user_shared_data_internal() {
    echo "🔄 Syncing user-shared data to S3 (optimized)..."

    # Send initial progress notification and ensure tools are available
    notify_sync_progress "user_data" "PROGRESS" 0

    S3_USER_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/shared"
    S3_USER_COMFYUI_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/ComfyUI/shared"

    # Separate venv handling from other folders for optimization
    OTHER_SHARED_FOLDERS=(".comfyui" ".cache")
    COMFYUI_USER_SHARED_FOLDERS_TO_ARCHIVE=("custom_nodes")

    declare -A ARCHIVES_TO_UPLOAD

    # Handle venv with chunked optimization
    local venv_dir="$NETWORK_VOLUME/venv"
    if [[ -d "$venv_dir" ]] && [[ -n "$(find "$venv_dir" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        echo "📦 Processing venv with chunked optimization..."
        notify_sync_progress "user_data" "PROGRESS" 10
        
        # Use chunked upload for venv
        local s3_venv_chunks_path="$S3_USER_SHARED_BASE/venv_chunks"
        if chunk_and_upload_venv "$venv_dir" "$s3_venv_chunks_path" "user_data"; then
            echo "  ✅ Successfully uploaded venv using chunked method"
        else
            echo "  ⚠️ Chunked venv upload failed, falling back to traditional archive method"
            # Fallback to traditional archiving
            local archive_name="venv.tar.gz"
            local temp_archive_path="/tmp/user_shared_${archive_name}"
            echo "  🗜️ Compressing venv with traditional method..."
            if tar -czf "$temp_archive_path" -C "$NETWORK_VOLUME" "venv"; then
                ARCHIVES_TO_UPLOAD["$temp_archive_path"]="$S3_USER_SHARED_BASE/$archive_name"
                echo "  📝 Added venv to upload queue (fallback method)"
            else
                echo "  ❌ Failed to compress venv"
            fi
        fi
    else
        echo "  ⏭️ Skipping venv (missing or empty)"
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
                ARCHIVES_TO_UPLOAD["$temp_archive_path"]="$S3_USER_SHARED_BASE/$archive_name"
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
                ARCHIVES_TO_UPLOAD["$temp_archive_path"]="$S3_USER_COMFYUI_SHARED_BASE/$archive_name"
            else
                echo "  ❌ Failed to compress ComfyUI/$folder_name"
                rm -f "$temp_archive_path"
            fi
        else
            echo "  ⏭️ Skipping ComfyUI/$folder_name (missing or empty)"
        fi
    done

    notify_sync_progress "user_data" "PROGRESS" 60

    total_archives=${#ARCHIVES_TO_UPLOAD[@]}
    
    if [ "$total_archives" -gt 0 ]; then
        processed_archives=0

        echo "📤 Uploading archived user-shared data to S3 ($total_archives total)..."
        for archive_path in "${!ARCHIVES_TO_UPLOAD[@]}"; do
            s3_dest="${ARCHIVES_TO_UPLOAD[$archive_path]}"
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
        done
    else
        echo "ℹ️ No additional archives to upload"
        notify_sync_progress "user_data" "PROGRESS" 95
    fi

    notify_sync_progress "user_data" "DONE" 100
    echo "✅ User-shared data sync completed (optimized)"
}

# Execute sync with lock management
execute_with_sync_lock "user_shared" "sync_user_shared_data_internal"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_user_shared_data.sh"

# Graceful shutdown script (graceful_shutdown.sh - from previous correct version)
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

# Signal handler script (signal_handler.sh - from previous correct version)
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

# Global shared models sync script (sync_global_shared_models.sh - with model sync integration)
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

# ComfyUI assets sync script (input/output directories)
cat > "$NETWORK_VOLUME/scripts/sync_comfyui_assets.sh" << 'EOF'
#!/bin/bash
# Sync ComfyUI input/output directories to S3 (one-way: pod to S3 only, with deletions)

# Source the sync lock manager, API client, and model sync integration for progress notifications
source "$NETWORK_VOLUME/scripts/sync_lock_manager.sh"
source "$NETWORK_VOLUME/scripts/api_client.sh"
source "$NETWORK_VOLUME/scripts/model_sync_integration.sh"

sync_comfyui_assets_internal() {
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
        
        # Use enhanced directory sync with progress tracking
        if sync_directory_with_progress "$LOCAL_INPUT_DIR" "$s3_input_path" "user_assets" 25 25; then
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
        
        # Use enhanced directory sync with progress tracking
        if sync_directory_with_progress "$LOCAL_OUTPUT_DIR" "$s3_output_path" "user_assets" 50 40; then
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

    notify_sync_progress "user_assets" "DONE" 100
    echo "✅ ComfyUI assets sync completed"
    }

# Execute sync with lock management
execute_with_sync_lock "user_assets" "sync_comfyui_assets_internal"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_comfyui_assets.sh"

# Pod metadata sync script (model config and workflows)
cat > "$NETWORK_VOLUME/scripts/sync_pod_metadata.sh" << 'EOF'
#!/bin/bash
# Sync pod metadata to S3 (model configuration and user workflows)

# Source the sync lock manager, API client, and model sync integration for progress notifications
source "$NETWORK_VOLUME/scripts/sync_lock_manager.sh"
source "$NETWORK_VOLUME/scripts/api_client.sh"
source "$NETWORK_VOLUME/scripts/model_sync_integration.sh"

sync_pod_metadata_internal() {
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

    notify_sync_progress "pod_metadata" "DONE" 100
    echo "✅ Pod metadata sync completed"
}

# Execute sync with lock management
execute_with_sync_lock "pod_metadata" "sync_pod_metadata_internal"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_pod_metadata.sh"

echo "✅ Sync scripts created"