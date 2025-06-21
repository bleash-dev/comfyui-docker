#!/bin/bash
# Create all sync-related scripts

echo "📝 Creating sync scripts..."

# User data sync script
cat > "$NETWORK_VOLUME/scripts/sync_user_data.sh" << 'EOF'
#!/bin/bash
# Sync user-specific data to S3

echo "🔄 Syncing user data to S3..."

SHARED_FOLDERS=("venv" ".comfyui")
COMFYUI_SHARED_FOLDERS=("models" "custom_nodes")

is_shared_folder() {
    local folder="$1"
    for shared in "${SHARED_FOLDERS[@]}"; do
        [[ "$folder" == "$shared" ]] && return 0
    done
    return 1
}

is_comfyui_shared() {
    local item="$1"
    for shared in "${COMFYUI_SHARED_FOLDERS[@]}"; do
        [[ "$item" == "$shared" ]] && return 0
    done
    return 1
}

# Sync ComfyUI user folders (pod-specific)
if [[ -d "$NETWORK_VOLUME/ComfyUI" ]]; then
    for dir in "$NETWORK_VOLUME/ComfyUI"/*; do
        if [[ -d "$dir" ]]; then
            folder_name=$(basename "$dir")
            if ! is_comfyui_shared "$folder_name"; then
                echo "📁 Syncing ComfyUI/$folder_name to S3..."
                s3_path="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/ComfyUI/$folder_name/"
                aws s3 sync "$dir" "$s3_path" --delete || echo "Failed to sync $folder_name"
            else
                echo "⏭️ Skipping shared ComfyUI folder: $folder_name"
            fi
        fi
    done
    
    # Sync ComfyUI root files
    comfyui_files=()
    for item in "$NETWORK_VOLUME/ComfyUI"/*; do
        [[ -f "$item" ]] && comfyui_files+=($(basename "$item"))
    done
    
    if [[ ${#comfyui_files[@]} -gt 0 ]]; then
        echo "📄 Syncing ComfyUI root files to S3..."
        temp_dir="/tmp/comfyui_root_sync"
        mkdir -p "$temp_dir"
        for file in "${comfyui_files[@]}"; do
            cp "$NETWORK_VOLUME/ComfyUI/$file" "$temp_dir/"
        done
        aws s3 sync "$temp_dir" "s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/ComfyUI/_root_files/" --delete
        rm -rf "$temp_dir"
    fi
fi

# Sync other user folders (pod-specific)
echo "🔍 Checking for other user folders to sync..."
find "$NETWORK_VOLUME" -mindepth 1 -maxdepth 1 -type d | while read -r dir; do
    folder_name=$(basename "$dir")
    echo "  Checking folder: $folder_name"
    
    # Skip system/hidden folders that start with . (except explicitly included ones)
    if [[ "$folder_name" =~ ^\. ]] && ! is_shared_folder "$folder_name"; then
        echo "  ⏭️ Skipping hidden folder: $folder_name"
        continue
    fi
    
    # Skip shared folders and ComfyUI folder
    if ! is_shared_folder "$folder_name" && [[ "$folder_name" != "ComfyUI" ]]; then
        # Check if directory has content
        if [[ -n "$(find "$dir" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
            echo "  📁 Syncing user folder: $folder_name to S3..."
            s3_path="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/$folder_name/"
            aws s3 sync "$dir" "$s3_path" --delete || echo "  ❌ Failed to sync $folder_name"
        else
            echo "  📭 Skipping empty folder: $folder_name"
        fi
    else
        echo "  ⏭️ Skipping shared/system folder: $folder_name"
    fi
done

echo "✅ User data sync completed"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_user_data.sh"

# User shared data sync script (new)
cat > "$NETWORK_VOLUME/scripts/sync_user_shared_data.sh" << 'EOF'
#!/bin/bash
# Sync user-shared data to S3 (data that persists across different pods for the same user)

echo "🔄 Syncing user-shared data to S3..."

# User-specific shared data (not pod-specific)
S3_USER_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/shared"
S3_USER_COMFYUI_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/ComfyUI/shared"

# Folders that should be shared across pods for the same user
USER_SHARED_FOLDERS=("venv" ".comfyui")
COMFYUI_USER_SHARED_FOLDERS=("custom_nodes")

# Sync user-shared folders
echo "📁 Syncing user-shared folders..."
for folder_name in "${USER_SHARED_FOLDERS[@]}"; do
    local_folder_path="$NETWORK_VOLUME/$folder_name"
    
    if [[ -d "$local_folder_path" ]]; then
        s3_folder_path="$S3_USER_SHARED_BASE/$folder_name/"
        echo "  📤 Syncing user-shared/$folder_name to S3..."
        aws s3 sync "$local_folder_path" "$s3_folder_path" --delete || \
            echo "  ❌ Failed to sync user-shared/$folder_name"
    else
        echo "  ⏭️ Skipping non-existent folder: $folder_name"
    fi
done

# Sync ComfyUI user-shared folders
echo "📁 Syncing ComfyUI user-shared folders..."
for folder_name in "${COMFYUI_USER_SHARED_FOLDERS[@]}"; do
    local_folder_path="$NETWORK_VOLUME/ComfyUI/$folder_name"
    
    if [[ -d "$local_folder_path" ]]; then
        s3_folder_path="$S3_USER_COMFYUI_SHARED_BASE/$folder_name/"
        echo "  📤 Syncing ComfyUI-user-shared/$folder_name to S3..."
        aws s3 sync "$local_folder_path" "$s3_folder_path" --delete || \
            echo "  ❌ Failed to sync ComfyUI-user-shared/$folder_name"
    else
        echo "  ⏭️ Skipping non-existent ComfyUI folder: $folder_name"
    fi
done

echo "✅ User-shared data sync completed"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_user_shared_data.sh"

# Graceful shutdown script
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

# Signal handler script
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

# Global shared models sync script (new)
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
    return 0
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



chmod +x "$NETWORK_VOLUME/scripts/sync_global_shared_models.sh"chmod +x "$NETWORK_VOLUME/scripts/sync_global_shared_models.sh"

echo "✅ Sync scripts created"
