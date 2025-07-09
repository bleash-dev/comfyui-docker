#!/bin/bash
# Create all sync-related scripts

echo "📝 Creating sync scripts..."

# User data sync script (sync_user_data.sh - from previous correct version)
cat > "$NETWORK_VOLUME/scripts/sync_user_data.sh" << 'EOF'
#!/bin/bash
# Sync user-specific data to S3 by zipping and uploading archives

echo "🔄 Syncing user data to S3 (archived)..."

EXCLUDE_SHARED_FOLDERS=("venv" ".comfyui" ".cache") 
EXCLUDE_COMFYUI_SHARED_FOLDERS=("models" "custom_nodes" ".browser-sessions")

COMFYUI_POD_SPECIFIC_ARCHIVE_NAME="comfyui_pod_specific_data.tar.gz"
S3_COMFYUI_POD_SPECIFIC_PATH="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/$COMFYUI_POD_SPECIFIC_ARCHIVE_NAME"
TEMP_COMFYUI_STAGING_DIR=$(mktemp -d /tmp/comfyui_pod_staging.XXXXXX)
COMFYUI_HAS_DATA_TO_SYNC=false

if [[ -d "$NETWORK_VOLUME/ComfyUI" ]]; then
    echo "📦 Preparing ComfyUI pod-specific data for archival..."
    
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
    
    if [[ "$COMFYUI_HAS_DATA_TO_SYNC" == "true" ]]; then
        echo "  🗜️ Compressing ComfyUI pod-specific data..."
        TEMP_ARCHIVE_PATH="/tmp/$COMFYUI_POD_SPECIFIC_ARCHIVE_NAME"
        (cd "$TEMP_COMFYUI_STAGING_DIR" && tar -czf "$TEMP_ARCHIVE_PATH" .)
        
        echo "  📤 Uploading $COMFYUI_POD_SPECIFIC_ARCHIVE_NAME to S3..."
        aws s3 cp "$TEMP_ARCHIVE_PATH" "$S3_COMFYUI_POD_SPECIFIC_PATH" --only-show-errors || \
            echo "  ❌ Failed to sync $COMFYUI_POD_SPECIFIC_ARCHIVE_NAME"
        rm -f "$TEMP_ARCHIVE_PATH"
    else
        echo "  ℹ️ No ComfyUI pod-specific data found to sync."
    fi
else
    echo "⏭️ ComfyUI directory not found, skipping ComfyUI pod-specific sync."
fi
rm -rf "$TEMP_COMFYUI_STAGING_DIR"
echo "--- ComfyUI pod-specific sync finished ---"


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
    
    echo "  📤 Uploading $OTHER_POD_SPECIFIC_ARCHIVE_NAME to S3..."
    aws s3 cp "$TEMP_ARCHIVE_PATH" "$S3_OTHER_POD_SPECIFIC_PATH" --only-show-errors || \
        echo "  ❌ Failed to sync $OTHER_POD_SPECIFIC_ARCHIVE_NAME"
    rm -f "$TEMP_ARCHIVE_PATH"
else
    echo "  ℹ️ No other pod-specific data found to sync."
fi
rm -rf "$TEMP_OTHER_STAGING_DIR"
echo "--- Other pod-specific sync finished ---"

echo "✅ User data archive sync completed"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_user_data.sh"

# User shared data sync script (CORRECTED)
cat > "$NETWORK_VOLUME/scripts/sync_user_shared_data.sh" << 'EOF'
#!/bin/bash
# Sync user-shared data to S3 (data that persists across different pods for the same user)
# This script will zip each specified shared folder individually.

echo "🔄 Syncing user-shared data to S3 (archived)..."

S3_USER_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/shared"
S3_USER_COMFYUI_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/ComfyUI/shared"

USER_SHARED_FOLDERS_TO_ARCHIVE=("venv" ".comfyui" ".cache")
COMFYUI_USER_SHARED_FOLDERS_TO_ARCHIVE=("custom_nodes") 

echo "📦 Syncing user-shared folder archives..."
for folder_name in "${USER_SHARED_FOLDERS_TO_ARCHIVE[@]}"; do
    local_folder_path="$NETWORK_VOLUME/$folder_name"
    # Ensure archive_name is filesystem-safe, especially for ".comfyui" -> "_comfyui.tar.gz" and ".cache" -> "_cache.tar.gz"
    # Replacing leading dot with underscore for the archive filename.
    # Using parameter expansion for this.
    safe_folder_name="${folder_name#.}" 
    if [[ "${folder_name}" == .* ]]; then # If it started with a dot
        safe_folder_name="_${safe_folder_name}"
    fi
    archive_name="${safe_folder_name//\//_}.tar.gz"

    temp_archive_path="/tmp/user_shared_${archive_name}"
    s3_archive_destination="$S3_USER_SHARED_BASE/$archive_name"
    
    echo "  ℹ️ Checking user-shared folder: $folder_name (local: $local_folder_path)"
    if [[ -d "$local_folder_path" ]]; then
        if [[ -n "$(find "$local_folder_path" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
            echo "    🗜️ Compressing user-shared/$folder_name..."
            tar -czf "$temp_archive_path" -C "$NETWORK_VOLUME" "$folder_name" # folder_name here is correct (e.g. ".comfyui")
            
            echo "    📤 Uploading $archive_name to $s3_archive_destination..."
            aws s3 cp "$temp_archive_path" "$s3_archive_destination" --only-show-errors || \
                echo "    ❌ Failed to sync user-shared/$archive_name"
            rm -f "$temp_archive_path"
        else
            echo "    📭 Skipping empty user-shared folder: $folder_name"
        fi
    else
        echo "    ⏭️ Skipping non-existent user-shared folder: $folder_name"
    fi
done

echo "📦 Syncing ComfyUI user-shared folder archives..."
for folder_name in "${COMFYUI_USER_SHARED_FOLDERS_TO_ARCHIVE[@]}"; do
    local_folder_path="$NETWORK_VOLUME/ComfyUI/$folder_name"
    archive_name="${folder_name//\//_}.tar.gz"
    temp_archive_path="/tmp/comfyui_shared_${archive_name}"
    s3_archive_destination="$S3_USER_COMFYUI_SHARED_BASE/$archive_name"

    echo "  ℹ️ Checking ComfyUI-user-shared folder: $folder_name (local: $local_folder_path)"
    # THIS IS THE CORRECTED LINE:
    if [[ -d "$local_folder_path" ]]; then 
        if [[ -n "$(find "$local_folder_path" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
            echo "    🗜️ Compressing ComfyUI-user-shared/$folder_name..."
            tar -czf "$temp_archive_path" -C "$NETWORK_VOLUME/ComfyUI" "$folder_name"
            
            echo "    📤 Uploading $archive_name to $s3_archive_destination..."
            aws s3 cp "$temp_archive_path" "$s3_archive_destination" --only-show-errors || \
                echo "    ❌ Failed to sync ComfyUI-user-shared/$archive_name"
            rm -f "$temp_archive_path"
        else
            echo "    📭 Skipping empty ComfyUI-user-shared folder: $folder_name"
        fi
    else
        echo "    ⏭️ Skipping non-existent ComfyUI-user-shared folder: $folder_name"
    fi
done

echo "✅ User-shared data archive sync completed"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_user_shared_data.sh"

# Graceful shutdown script (graceful_shutdown.sh - from previous correct version)
cat > "$NETWORK_VOLUME/scripts/graceful_shutdown.sh" << 'EOF'
#!/bin/bash
# Graceful shutdown with data sync (no mounting)

echo "🛑 Graceful shutdown initiated at $(date)"

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
[ -f "$NETWORK_VOLUME/scripts/sync_logs.sh" ] && "$NETWORK_VOLUME/scripts/sync_logs.sh"
[ -f "$NETWORK_VOLUME/scripts/sync_user_data.sh" ] && "$NETWORK_VOLUME/scripts/sync_user_data.sh"
[ -f "$NETWORK_VOLUME/scripts/sync_user_shared_data.sh" ] && "$NETWORK_VOLUME/scripts/sync_user_shared_data.sh"
[ -f "$NETWORK_VOLUME/scripts/sync_global_shared_models.sh" ] && "$NETWORK_VOLUME/scripts/sync_global_shared_models.sh"
[ -f "$NETWORK_VOLUME/scripts/sync_comfyui_assets.sh" ] && "$NETWORK_VOLUME/scripts/sync_comfyui_assets.sh"

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

# Global shared models sync script (sync_global_shared_models.sh - from previous correct version)
cat > "$NETWORK_VOLUME/scripts/sync_global_shared_models.sh" << 'EOF'
#!/bin/bash
# Sync global shared models and browser session to S3 (without delete to preserve shared resources)

echo "🌐 Syncing global shared resources to S3..."
S3_GLOBAL_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/global_shared/models"
S3_BROWSER_SESSIONS_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/global_shared/.browser-session"
LOCAL_MODELS_BASE="$NETWORK_VOLUME/ComfyUI/models"
LOCAL_BROWSER_SESSIONS_BASE="$NETWORK_VOLUME/ComfyUI/.browser-session"

# Sync models
if [[ ! -d "$LOCAL_MODELS_BASE" ]]; then
    echo "⏭️ No models directory found at $LOCAL_MODELS_BASE"
else
    echo "📁 Syncing global shared model folders..."
    for model_dir in "$LOCAL_MODELS_BASE"/*; do
        if [[ -d "$model_dir" ]]; then
            folder_name=$(basename "$model_dir")
            if [[ -n "$(find "$model_dir" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
                echo "  📤 Syncing global models/$folder_name to S3..."
                s3_folder_path="$S3_GLOBAL_SHARED_BASE/$folder_name/"
                aws s3 sync "$model_dir" "$s3_folder_path" --only-show-errors || \
                    echo "  ❌ Failed to sync global models/$folder_name"
            else echo "  📭 Skipping empty models folder: $folder_name"; fi
        fi
    done
fi

# Sync browser sessions
if [[ -d "$LOCAL_BROWSER_SESSIONS_BASE" ]]; then
    if [[ -n "$(find "$LOCAL_BROWSER_SESSIONS_BASE" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        echo "🌐 Syncing global shared browser sessions to S3..."
        echo "  📤 Syncing browser sessions to $S3_BROWSER_SESSIONS_BASE/"
        aws s3 sync "$LOCAL_BROWSER_SESSIONS_BASE" "$S3_BROWSER_SESSIONS_BASE/" --only-show-errors || \
            echo "  ❌ Failed to sync global browser sessions"
    else
        echo "  📭 Skipping empty browser sessions directory"
    fi
else
    echo "ℹ️ No browser sessions directory found at $LOCAL_BROWSER_SESSIONS_BASE"
fi

echo "✅ Global shared resources sync completed"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_global_shared_models.sh"

# ComfyUI assets sync script (input/output directories)
cat > "$NETWORK_VOLUME/scripts/sync_comfyui_assets.sh" << 'EOF'
#!/bin/bash
# Sync ComfyUI input/output directories to S3 (one-way: pod to S3 only)

echo "📁 Syncing ComfyUI assets to S3..."
S3_ASSETS_BASE="s3://$AWS_BUCKET_NAME/assets/$POD_ID"
LOCAL_INPUT_DIR="$NETWORK_VOLUME/ComfyUI/input"
LOCAL_OUTPUT_DIR="$NETWORK_VOLUME/ComfyUI/output"

# Sync input directory
if [[ -d "$LOCAL_INPUT_DIR" ]]; then
    if [[ -n "$(find "$LOCAL_INPUT_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        echo "  📤 Syncing input assets to S3..."
        s3_input_path="$S3_ASSETS_BASE/input/"
        aws s3 sync "$LOCAL_INPUT_DIR" "$s3_input_path" --only-show-errors || \
            echo "  ❌ Failed to sync input assets"
    else
        echo "  📭 Skipping empty input directory"
    fi
else
    echo "ℹ️ No input directory found at $LOCAL_INPUT_DIR"
fi

# Sync output directory
if [[ -d "$LOCAL_OUTPUT_DIR" ]]; then
    if [[ -n "$(find "$LOCAL_OUTPUT_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        echo "  📤 Syncing output assets to S3..."
        s3_output_path="$S3_ASSETS_BASE/output/"
        aws s3 sync "$LOCAL_OUTPUT_DIR" "$s3_output_path" --only-show-errors || \
            echo "  ❌ Failed to sync output assets"
    else
        echo "  📭 Skipping empty output directory"
    fi
else
    echo "ℹ️ No output directory found at $LOCAL_OUTPUT_DIR"
fi

echo "✅ ComfyUI assets sync completed"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_comfyui_assets.sh"

echo "✅ Sync scripts created"