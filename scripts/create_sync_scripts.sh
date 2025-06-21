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

# Sync ComfyUI user folders
if [[ -d "$NETWORK_VOLUME/ComfyUI" ]]; then
    for dir in $NETWORK_VOLUME/ComfyUI/*/; do
        if [[ -d "$dir" ]]; then
            folder_name=$(basename "$dir")
            if ! is_comfyui_shared "$folder_name"; then
                s3_path="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/ComfyUI/$folder_name/"
                aws s3 sync "$dir" "$s3_path" --delete || echo "Failed to sync $folder_name"
            fi
        fi
    done
    
    # Sync ComfyUI root files
    comfyui_files=()
    for item in $NETWORK_VOLUME/ComfyUI/*; do
        [[ -f "$item" ]] && comfyui_files+=($(basename "$item"))
    done
    
    if [[ ${#comfyui_files[@]} -gt 0 ]]; then
        temp_dir="/tmp/comfyui_root_sync"
        mkdir -p "$temp_dir"
        for file in "${comfyui_files[@]}"; do
            cp "$NETWORK_VOLUME/ComfyUI/$file" "$temp_dir/"
        done
        aws s3 sync "$temp_dir" "s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/ComfyUI/_root_files/" --delete
        rm -rf "$temp_dir"
    fi
fi

# Sync other user folders
for dir in $NETWORK_VOLUME/*/; do
    if [[ -d "$dir" ]]; then
        folder_name=$(basename "$dir")
        if ! is_shared_folder "$folder_name" && [[ "$folder_name" != "ComfyUI" ]] && [[ -n "$(ls -A "$dir" 2>/dev/null)" ]]; then
            s3_path="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/$folder_name/"
            aws s3 sync "$dir" "$s3_path" --delete || echo "Failed to sync $folder_name"
        fi
    fi
done

echo "✅ User data sync completed"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_user_data.sh"

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

# Stop background processes
pkill -f "$NETWORK_VOLUME/scripts/" 2>/dev/null || true

# Final syncs
[ -f "$NETWORK_VOLUME/scripts/sync_logs.sh" ] && "$NETWORK_VOLUME/scripts/sync_logs.sh"
[ -f "$NETWORK_VOLUME/scripts/sync_user_data.sh" ] && "$NETWORK_VOLUME/scripts/sync_user_data.sh"

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
    $NETWORK_VOLUME/scripts/graceful_shutdown.sh
    exit 0
}

trap handle_signal SIGTERM SIGINT SIGQUIT

while true; do
    sleep 1
done
EOF

chmod +x "$NETWORK_VOLUME/scripts/signal_handler.sh"

echo "✅ Sync scripts created"
done
EOF

chmod +x "$NETWORK_VOLUME/scripts/signal_handler.sh"

echo "✅ Sync scripts created"
