#!/bin/bash
# Create all sync-related scripts

echo "📝 Creating sync scripts..."

# User data sync script
cat > "$NETWORK_VOLUME/scripts/sync_user_data.sh" << 'EOF'
#!/bin/bash
# Sync user-specific data to S3 by zipping and uploading archives

echo "🔄 Syncing user data to S3 (archived)..."

# These are handled by sync_user_shared_data.sh
# SHARED_FOLDERS_TO_SKIP=("venv" ".comfyui")
# COMFYUI_SHARED_FOLDERS_TO_SKIP=("models" "custom_nodes") # 'models' are handled by global_shared_models

# We need to define what is NOT pod-specific to exclude it from pod-specific archives
EXCLUDE_SHARED_FOLDERS=("venv" ".comfyui") # Top-level shared
EXCLUDE_COMFYUI_SHARED_FOLDERS=("models" "custom_nodes") # ComfyUI shared

# --- Sync ComfyUI pod-specific data ---
COMFYUI_POD_SPECIFIC_ARCHIVE_NAME="comfyui_pod_specific_data.tar.gz"
S3_COMFYUI_POD_SPECIFIC_PATH="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/$COMFYUI_POD_SPECIFIC_ARCHIVE_NAME"
TEMP_COMFYUI_STAGING_DIR=$(mktemp -d /tmp/comfyui_pod_staging.XXXXXX)
COMFYUI_HAS_DATA_TO_SYNC=false

if [[ -d "$NETWORK_VOLUME/ComfyUI" ]]; then
    echo "📦 Preparing ComfyUI pod-specific data for archival..."
    
    # 1. Sync ComfyUI user sub-folders (pod-specific)
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
            # Check if directory has content before copying
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
        aws s3 cp "$TEMP_ARCHIVE_PATH" "$S3_COMFYUI_POD_SPECIFIC_PATH" || \
            echo "  ❌ Failed to sync $COMFYUI_POD_SPECIFIC_ARCHIVE_NAME"
        rm -f "$TEMP_ARCHIVE_PATH"
    else
        echo "  ℹ️ No ComfyUI pod-specific data found to sync."
        # Optionally, delete the archive from S3 if no data exists locally
        # aws s3 rm "$S3_COMFYUI_POD_SPECIFIC_PATH" 2>/dev/null || true
    fi
else
    echo "⏭️ ComfyUI directory not found, skipping ComfyUI pod-specific sync."
fi
rm -rf "$TEMP_COMFYUI_STAGING_DIR"
echo "--- ComfyUI pod-specific sync finished ---"


# --- Sync other user folders (pod-specific, non-ComfyUI, non-shared) ---
OTHER_POD_SPECIFIC_ARCHIVE_NAME="other_pod_specific_data.tar.gz"
S3_OTHER_POD_SPECIFIC_PATH="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/$OTHER_POD_SPECIFIC_ARCHIVE_NAME"
TEMP_OTHER_STAGING_DIR=$(mktemp -d /tmp/other_pod_staging.XXXXXX)
OTHER_HAS_DATA_TO_SYNC=false

echo "📦 Preparing other pod-specific data for archival..."
find "$NETWORK_VOLUME" -mindepth 1 -maxdepth 1 -type d | while read -r dir_path; do
    folder_name=$(basename "$dir_path")
    echo "  🔎 Checking top-level folder: $folder_name"
    
    # Skip ComfyUI folder (handled above)
    if [[ "$folder_name" == "ComfyUI" ]]; then
        echo "    ⏭️ Skipping ComfyUI (handled separately)."
        continue
    fi
    
    # Skip explicitly shared folders (handled by sync_user_shared_data.sh)
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
    
    # Skip other system/hidden folders (but allow .comfyui if it wasn't in EXCLUDE_SHARED_FOLDERS)
    if [[ "$folder_name" =~ ^\. ]] && [[ "$folder_name" != ".comfyui" ]]; then # .comfyui is explicitly handled
        echo "    ⏭️ Skipping hidden folder: $folder_name"
        continue
    fi
        
    # Check if directory has content before copying
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
    aws s3 cp "$TEMP_ARCHIVE_PATH" "$S3_OTHER_POD_SPECIFIC_PATH" || \
        echo "  ❌ Failed to sync $OTHER_POD_SPECIFIC_ARCHIVE_NAME"
    rm -f "$TEMP_ARCHIVE_PATH"
else
    echo "  ℹ️ No other pod-specific data found to sync."
    # Optionally, delete the archive from S3 if no data exists locally
    # aws s3 rm "$S3_OTHER_POD_SPECIFIC_PATH" 2>/dev/null || true
fi
rm -rf "$TEMP_OTHER_STAGING_DIR"
echo "--- Other pod-specific sync finished ---"

echo "✅ User data archive sync completed"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_user_data.sh"

# User shared data sync script (modified for zipping)
cat > "$NETWORK_VOLUME/scripts/sync_user_shared_data.sh" << 'EOF'
#!/bin/bash
# Sync user-shared data to S3 (data that persists across different pods for the same user)
# This script will zip each specified shared folder individually.

echo "🔄 Syncing user-shared data to S3 (archived)..."

# User-specific shared data (not pod-specific)
S3_USER_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/shared"
S3_USER_COMFYUI_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/ComfyUI/shared"

# Folders that should be shared across pods for the same user
# These will each become their own .tar.gz archive
USER_SHARED_FOLDERS_TO_ARCHIVE=("venv" ".comfyui")
COMFYUI_USER_SHARED_FOLDERS_TO_ARCHIVE=("custom_nodes") # Note: 'models' is handled by global shared sync

# Sync user-shared folder archives
echo "📦 Syncing user-shared folder archives..."
for folder_name in "${USER_SHARED_FOLDERS_TO_ARCHIVE[@]}"; do
    local_folder_path="$NETWORK_VOLUME/$folder_name"
    archive_name="${folder_name//\//_}.tar.gz" # Replace / with _ if folder_name could have it (e.g. .config/foo)
    temp_archive_path="/tmp/user_shared_${archive_name}"
    s3_archive_destination="$S3_USER_SHARED_BASE/$archive_name"
    
    if [[ -d "$local_folder_path" ]]; then
        # Check if directory has content
        if [[ -n "$(find "$local_folder_path" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
            echo "  🗜️ Compressing user-shared/$folder_name..."
            # Use -C to change directory so the archive contains 'folder_name/*' and not 'full_path/folder_name/*'
            # However, for restore, it might be better to have the folder name itself in the archive.
            # tar -czf "$temp_archive_path" -C "$(dirname "$local_folder_path")" "$folder_name"
            # This creates an archive with 'folder_name' as the top-level item.
            # To restore, extract in $NETWORK_VOLUME
            tar -czf "$temp_archive_path" -C "$NETWORK_VOLUME" "$folder_name"

            echo "  📤 Uploading $archive_name to $s3_archive_destination..."
            aws s3 cp "$temp_archive_path" "$s3_archive_destination" || \
                echo "  ❌ Failed to sync user-shared/$archive_name"
            rm -f "$temp_archive_path"
        else
            echo "  📭 Skipping empty user-shared folder: $folder_name (no archive created/uploaded)"
            # Optionally, delete the archive from S3 if it exists but local folder is now empty
            # aws s3 rm "$s3_archive_destination" 2>/dev/null || true
        fi
    else
        echo "  ⏭️ Skipping non-existent user-shared folder: $folder_name"
        # Optionally, delete the archive from S3 if it exists but local folder is gone
        # aws s3 rm "$s3_archive_destination" 2>/dev/null || true
    fi
done

# Sync ComfyUI user-shared folder archives
echo "📦 Syncing ComfyUI user-shared folder archives..."
for folder_name in "${COMFYUI_USER_SHARED_FOLDERS_TO_ARCHIVE[@]}"; do
    local_folder_path="$NETWORK_VOLUME/ComfyUI/$folder_name"
    archive_name="${folder_name//\//_}.tar.gz"
    temp_archive_path="/tmp/comfyui_shared_${archive_name}"
    s3_archive_destination="$S3_USER_COMFYUI_SHARED_BASE/$archive_name"

    if [[ -d "$local_folder_path" ]]; ]]; then
        if [[ -n "$(find "$local_folder_path" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
            echo "  🗜️ Compressing ComfyUI-user-shared/$folder_name..."
            # tar -czf "$temp_archive_path" -C "$(dirname "$local_folder_path")" "$folder_name"
            # This creates an archive with 'folder_name' as the top-level item.
            # To restore, extract in $NETWORK_VOLUME/ComfyUI
            tar -czf "$temp_archive_path" -C "$NETWORK_VOLUME/ComfyUI" "$folder_name"
            
            echo "  📤 Uploading $archive_name to $s3_archive_destination..."
            aws s3 cp "$temp_archive_path" "$s3_archive_destination" || \
                echo "  ❌ Failed to sync ComfyUI-user-shared/$archive_name"
            rm -f "$temp_archive_path"
        else
            echo "  📭 Skipping empty ComfyUI-user-shared folder: $folder_name (no archive created/uploaded)"
            # Optionally, delete the archive from S3 if it exists but local folder is now empty
            # aws s3 rm "$s3_archive_destination" 2>/dev/null || true
        fi
    else
        echo "  ⏭️ Skipping non-existent ComfyUI-user-shared folder: $folder_name"
        # Optionally, delete the archive from S3 if it exists but local folder is gone
        # aws s3 rm "$s3_archive_destination" 2>/dev/null || true
    fi
done

echo "✅ User-shared data archive sync completed"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_user_shared_data.sh"

# Graceful shutdown script (no changes needed here, it just calls the other scripts)
cat > "$NETWORK_VOLUME/scripts/graceful_shutdown.sh" << 'EOF'
#!/bin/bash
# Graceful shutdown with data sync (no mounting)

echo "🛑 Graceful shutdown initiated at $(date)"

# Stop pod execution tracker
if [ -f "/tmp/pod_tracker.pid" ]; then
    POD_TRACKER_PID=$(cat /tmp/pod_tracker.pid)
    if [ -n "$POD_TRACKER_PID" ] && kill -0 "$POD_TRACKER_PID" 2>/dev/null; then
        echo "🕐 Stopping pod execution tracker..."
        kill -TERM "$POD_TRACKER_PID" 2>/dev/null || true
        sleep 3
        kill -9 "$POD_TRACKER_PID" 2>/dev/null || true
    fi
    rm -f /tmp/pod_tracker.pid
fi

# Stop background services using PID file
BACKGROUND_PIDS_FILE="$NETWORK_VOLUME/.background_services.pids"
if [ -f "$BACKGROUND_PIDS_FILE" ]; then
    echo "🔄 Stopping background services from PID file..."
    while IFS=':' read -r service_name pid; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "  Stopping $service_name (PID: $pid)..."
            kill -TERM "$pid" 2>/dev/null || true
            sleep 1
            # Force kill if still running
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null || true
            fi
        else
            echo "  $service_name (PID: $pid) already stopped or invalid"
        fi
    done < "$BACKGROUND_PIDS_FILE"
    rm -f "$BACKGROUND_PIDS_FILE"
else
    echo "⚠️ No background services PID file found, using fallback cleanup..."
    # Fallback: Stop background processes by pattern matching
    pkill -f "$NETWORK_VOLUME/scripts/" 2>/dev/null || true
fi

# Final syncs
echo "🔄 Performing final data sync..."
[ -f "$NETWORK_VOLUME/scripts/sync_logs.sh" ] && "$NETWORK_VOLUME/scripts/sync_logs.sh"
[ -f "$NETWORK_VOLUME/scripts/sync_user_data.sh" ] && "$NETWORK_VOLUME/scripts/sync_user_data.sh"
[ -f "$NETWORK_VOLUME/scripts/sync_user_shared_data.sh" ] && "$NETWORK_VOLUME/scripts/sync_user_shared_data.sh"
[ -f "$NETWORK_VOLUME/scripts/sync_global_shared_models.sh" ] && "$NETWORK_VOLUME/scripts/sync_global_shared_models.sh"

# Stop any remaining AWS processes
pkill -f "aws" 2>/dev/null || true

echo "✅ Graceful shutdown completed"
EOF

chmod +x "$NETWORK_VOLUME/scripts/graceful_shutdown.sh"

# Signal handler script (no changes needed here)
cat > "$NETWORK_VOLUME/scripts/signal_handler.sh" << 'EOF'
#!/bin/bash
# Signal handler for graceful shutdown

handle_signal() {
    echo "📢 Received shutdown signal, initiating graceful shutdown..."
    
    # Send signals to all background services
    BACKGROUND_PIDS_FILE="$NETWORK_VOLUME/.background_services.pids"
    if [ -f "$BACKGROUND_PIDS_FILE" ]; then
        echo "🔄 Sending termination signals to background services..."
        while IFS=':' read -r service_name pid; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                echo "  Signaling $service_name (PID: $pid)..."
                kill -TERM "$pid" 2>/dev/null || true
            fi
        done < "$BACKGROUND_PIDS_FILE"
        
        # Give services time to shut down gracefully
        sleep 3
        
        # Force kill any remaining services
        while IFS=':' read -r service_name pid; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                echo "  Force killing $service_name (PID: $pid)..."
                kill -9 "$pid" 2>/dev/null || true
            fi
        done < "$BACKGROUND_PIDS_FILE"
    fi
    
    # Run graceful shutdown
    "$NETWORK_VOLUME/scripts/graceful_shutdown.sh"
    exit 0
}

trap handle_signal SIGTERM SIGINT SIGQUIT

# Forward signals to background processes when we receive them
echo "📡 Signal handler active, waiting for signals..."
while true; do
    sleep 1
done
EOF

chmod +x "$NETWORK_VOLUME/scripts/signal_handler.sh"

# Global shared models sync script (leaving as is, models are often large & may not benefit from zipping or are already compressed)
# If you also want to zip models, the logic would be similar to sync_user_shared_data.sh but likely per model category.
cat > "$NETWORK_VOLUME/scripts/sync_global_shared_models.sh" << 'EOF'
#!/bin/bash
# Sync global shared models to S3 (without delete to preserve shared resources)

echo "🌐 Syncing global shared models to S3..."

# Global shared models base path
S3_GLOBAL_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/global_shared/models"
LOCAL_MODELS_BASE="$NETWORK_VOLUME/ComfyUI/models"

# Check if models directory exists
if [[ ! -d "$LOCAL_MODELS_BASE" ]]; then
    echo "⏭️ No models directory found at $LOCAL_MODELS_BASE"
    exit 0 # Use exit 0 for sourced scripts, or return 0 if it's a function
fi

echo "📁 Syncing global shared model folders..."

# Sync all model subdirectories without delete
for model_dir in "$LOCAL_MODELS_BASE"/*; do
    if [[ -d "$model_dir" ]]; then
        folder_name=$(basename "$model_dir")
        
        # Check if directory has content
        if [[ -n "$(find "$model_dir" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
            echo "  📤 Syncing global models/$folder_name to S3..."
            s3_folder_path="$S3_GLOBAL_SHARED_BASE/$folder_name/"
            
            # Sync without --delete to preserve shared resources
            aws s3 sync "$model_dir" "$s3_folder_path" || \
                echo "  ❌ Failed to sync global models/$folder_name"
        else
            echo "  📭 Skipping empty models folder: $folder_name"
        fi
    fi
done

echo "✅ Global shared models sync completed"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_global_shared_models.sh"

echo "✅ Sync scripts created"