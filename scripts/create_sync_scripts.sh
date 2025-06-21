#!/bin/bash
# Create all sync-related scripts

echo "📝 Creating sync scripts..."

# User data sync script
cat > "$NETWORK_VOLUME/scripts/sync_user_data.sh" << 'EOF'
#!/bin/bash
# Sync user-specific data to S3 by zipping folders...

echo "🔄 Syncing user data to S3 by zipping folders..."

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

# --- Zip and upload function ---
zip_and_upload() {
    local local_folder_path="$1"
    local s3_base_path="$2"
    local folder_name="$3"
    
    if [[ ! -d "$local_folder_path" ]]; then
        echo "  ⏭️ Skipping non-existent folder: $folder_name"
        return
    fi

    # Check if directory has content
    if [[ -z "$(find "$local_folder_path" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        echo "  📭 Skipping empty folder: $folder_name"
        return
    fi

    local zip_file_name="${folder_name}.zip"
    local temp_zip_path="/tmp/${zip_file_name}"
    local s3_zip_path="$s3_base_path/${zip_file_name}"

    echo "  📦 Zipping $folder_name..."
    if (cd "$local_folder_path" && zip -r -q "$temp_zip_path" .); then
        echo "  📤 Uploading $zip_file_name to $s3_zip_path..."
        aws s3 cp "$temp_zip_path" "$s3_zip_path" --delete || echo "  ❌ Failed to upload $zip_file_name"
        rm "$temp_zip_path"
    else
        echo "  ❌ Failed to zip $folder_name"
        rm -f "$temp_zip_path"
    fi
}

# Sync ComfyUI user folders (pod-specific)
if [[ -d "$NETWORK_VOLUME/ComfyUI" ]]; then
    for dir in "$NETWORK_VOLUME/ComfyUI"/*; do
        if [[ -d "$dir" ]]; then
            folder_name=$(basename "$dir")
            if ! is_comfyui_shared "$folder_name"; then
                echo "📁 Syncing ComfyUI/$folder_name to S3..."
                s3_path="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/ComfyUI"
                zip_and_upload "$dir" "$s3_path" "$folder_name"
            else
                echo "⏭️ Skipping shared ComfyUI folder: $folder_name"
            fi
        fi
    done
    
    # Sync ComfyUI root files by zipping them
    comfyui_files=()
    for item in "$NETWORK_VOLUME/ComfyUI"/*; do
        [[ -f "$item" ]] && comfyui_files+=("$item")
    done
    
    if [[ ${#comfyui_files[@]} -gt 0 ]]; then
        echo "📄 Syncing ComfyUI root files to S3..."
        temp_dir="/tmp/comfyui_root_sync_$$"
        mkdir -p "$temp_dir"
        
        for file in "${comfyui_files[@]}"; do
            cp "$file" "$temp_dir/"
        done

        local zip_file_name="_root_files.zip"
        local temp_zip_path="/tmp/${zip_file_name}"
        local s3_zip_path="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID/ComfyUI/${zip_file_name}"

        echo "  📦 Zipping root files..."
        if (cd "$temp_dir" && zip -r -q "$temp_zip_path" .); then
            echo "  📤 Uploading $zip_file_name to $s3_zip_path..."
            aws s3 cp "$temp_zip_path" "$s3_zip_path" || echo "  ❌ Failed to upload $zip_file_name"
        else
            echo "  ❌ Failed to zip root files"
        fi
        
        rm -rf "$temp_dir"
        rm -f "$temp_zip_path"
    fi
fi

# Sync other user folders (pod-specific)
echo "🔍 Checking for other user folders to sync..."
find "$NETWORK_VOLUME" -mindepth 1 -maxdepth 1 -type d | while read -r dir; do
    folder_name=$(basename "$dir")
    echo "  Checking folder: $folder_name"
    
    if [[ "$folder_name" =~ ^\. ]] && ! is_shared_folder "$folder_name"; then
        echo "  ⏭️ Skipping hidden folder: $folder_name"
        continue
    fi
    
    if ! is_shared_folder "$folder_name" && [[ "$folder_name" != "ComfyUI" ]]; then
        echo "  📁 Syncing user folder: $folder_name to S3..."
        s3_path="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID"
        zip_and_upload "$dir" "$s3_path" "$folder_name"
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

echo "🔄 Syncing user-shared data to S3 by zipping folders..."

# User-specific shared data (not pod-specific)
S3_USER_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/shared"
S3_USER_COMFYUI_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/ComfyUI/shared"

# Folders that should be shared across pods for the same user
USER_SHARED_FOLDERS=("venv" ".comfyui")
COMFYUI_USER_SHARED_FOLDERS=("custom_nodes")

# --- Zip and upload function ---
zip_and_upload() {
    local local_folder_path="$1"
    local s3_base_path="$2"
    local folder_name="$3"
    
    if [[ ! -d "$local_folder_path" ]]; then
        echo "  ⏭️ Skipping non-existent folder: $folder_name"
        return
    fi

    local zip_file_name="${folder_name}.zip"
    local temp_zip_path="/tmp/${zip_file_name}"
    local s3_zip_path="$s3_base_path/${zip_file_name}"

    echo "  📦 Zipping $folder_name..."
    # Use -r to recurse into directories, and -q for quiet operation
    # The 'cd' is important to avoid including the parent directory structure in the zip
    if (cd "$local_folder_path" && zip -r -q "$temp_zip_path" .); then
        echo "  📤 Uploading $zip_file_name to $s3_zip_path..."
        aws s3 cp "$temp_zip_path" "$s3_zip_path" || \
            echo "  ❌ Failed to upload $zip_file_name"
        rm "$temp_zip_path"
    else
        echo "  ❌ Failed to zip $folder_name"
        rm -f "$temp_zip_path"
    fi
}

# Sync user-shared folders
echo "📁 Syncing user-shared folders..."
for folder_name in "${USER_SHARED_FOLDERS[@]}"; do
    local_folder_path="$NETWORK_VOLUME/$folder_name"
    zip_and_upload "$local_folder_path" "$S3_USER_SHARED_BASE" "$folder_name"
done

# Sync ComfyUI user-shared folders
echo "📁 Syncing ComfyUI user-shared folders..."
for folder_name in "${COMFYUI_USER_SHARED_FOLDERS[@]}"; do
    local_folder_path="$NETWORK_VOLUME/ComfyUI/$folder_name"
    zip_and_upload "$local_folder_path" "$S3_USER_COMFYUI_SHARED_BASE" "$folder_name"
done

echo "✅ User-shared data sync completed"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_user_shared_data.sh"

# User data sync from S3 script (new)
cat > "$NETWORK_VOLUME/scripts/sync_user_data_from_s3.sh" << 'EOF'
#!/bin/bash
# Sync user data from S3 on startup

echo "📥 Syncing user data from S3..."

# --- Configuration & Validation ---
set -eo pipefail
required_vars=("AWS_BUCKET_NAME" "POD_USER_NAME" "POD_ID" "NETWORK_VOLUME")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ ERROR: Required environment variable $var is not set."
        exit 1
    fi
done

S3_POD_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID"
S3_USER_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/shared"
S3_USER_COMFYUI_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/ComfyUI/shared"
mkdir -p "$NETWORK_VOLUME"

# --- Download and unzip function ---
download_and_unzip() {
    local s3_base_path="$1"
    local local_base_path="$2"
    local folder_name="$3"
    
    local zip_file_name="${folder_name}.zip"
    local s3_zip_path="$s3_base_path/${zip_file_name}"
    local temp_zip_path="/tmp/${zip_file_name}"
    local local_folder_path="$local_base_path/$folder_name"

    echo "  ℹ️ Checking for $zip_file_name in S3 at $s3_zip_path..."
    if aws s3 ls "$s3_zip_path" >/dev/null 2>&1; then
        echo "  📥 Downloading $zip_file_name from S3..."
        if aws s3 cp "$s3_zip_path" "$temp_zip_path"; then
            echo "  📦 Unzipping $zip_file_name to $local_folder_path..."
            mkdir -p "$local_folder_path"
            if unzip -o -q "$temp_zip_path" -d "$local_folder_path"; then
                echo "  ✅ Successfully unzipped $folder_name"
            else
                echo "  ❌ Failed to unzip $zip_file_name"
            fi
            rm "$temp_zip_path"
        else
            echo "  ❌ Failed to download $zip_file_name"
        fi
    else
        echo "  ℹ️ No zip file for $folder_name found. Falling back to directory sync."
        local s3_folder_path="$s3_base_path/$folder_name/"
        if aws s3 ls "$s3_folder_path" >/dev/null 2>&1; then
            echo "  📥 Syncing folder '$folder_name' from S3 (fallback)..."
            mkdir -p "$local_folder_path"
            aws s3 sync "$s3_folder_path" "$local_folder_path" || \
                echo "⚠️ WARNING: Failed to sync folder '$folder_name'."
        else
            echo "  ℹ️ No data for '$folder_name' found to sync."
        fi
    fi
}

# --- ComfyUI Specific Sync ---
S3_COMFYUI_BASE="$S3_POD_BASE/ComfyUI"
LOCAL_COMFYUI_BASE="$NETWORK_VOLUME/ComfyUI"
echo "ℹ️ Checking for user-specific ComfyUI data in S3 at $S3_COMFYUI_BASE/"
if aws s3 ls "$S3_COMFYUI_BASE/" >/dev/null 2>&1; then
    echo "👍 Found user ComfyUI data in S3. Starting sync..."
    mkdir -p "$LOCAL_COMFYUI_BASE"
    comfyui_user_sync_folders=("input" "output")
    for folder_name in "${comfyui_user_sync_folders[@]}"; do
        download_and_unzip "$S3_COMFYUI_BASE" "$LOCAL_COMFYUI_BASE" "$folder_name"
    done

    # Sync ComfyUI root files
    root_zip_file_name="_root_files.zip"
    s3_root_zip_path="$S3_COMFYUI_BASE/$root_zip_file_name"
    temp_root_zip_path="/tmp/$root_zip_file_name"
    echo "  ℹ️ Checking for ComfyUI root files zip at $s3_root_zip_path..."
    if aws s3 ls "$s3_root_zip_path" >/dev/null 2>&1; then
        echo "  📥 Downloading $root_zip_file_name..."
        if aws s3 cp "$s3_root_zip_path" "$temp_root_zip_path"; then
            echo "  📦 Unzipping root files to $LOCAL_COMFYUI_BASE..."
            unzip -o -q "$temp_root_zip_path" -d "$LOCAL_COMFYUI_BASE" || echo "  ❌ Failed to unzip root files."
            rm "$temp_root_zip_path"
        else
            echo "  ❌ Failed to download root files zip."
        fi
    else
        echo "  ℹ️ No root files zip found. Falling back to directory sync for _root_files..."
        s3_comfyui_root_files_path="$S3_COMFYUI_BASE/_root_files/"
        if aws s3 ls "$s3_comfyui_root_files_path" >/dev/null 2>&1; then
            aws s3 sync "$s3_comfyui_root_files_path" "$LOCAL_COMFYUI_BASE/" || echo "⚠️ WARNING: Failed to sync ComfyUI root files."
        else
            echo "  ℹ️ No ComfyUI _root_files data found in S3."
        fi
    fi
else
    echo "ℹ️ No user-specific ComfyUI directory found in S3 for this pod session."
fi
echo ""

# --- General User Data Sync ---
echo "ℹ️ Checking for other user-specific data in S3 at $S3_POD_BASE/"
if aws s3 ls "$S3_POD_BASE/" >/dev/null 2>&1; then
    declare -A exclude_folders_map
    exclude_folders_map["ComfyUI"]=1
    exclude_folders_map["_pod_tracking"]=1
    aws s3 ls "$S3_POD_BASE/" | grep "PRE" | awk '{print $2}' | sed 's/\///g' | while IFS= read -r folder_name; do
        if [[ -z "${exclude_folders_map[$folder_name]}" ]]; then
            download_and_unzip "$S3_POD_BASE" "$NETWORK_VOLUME" "$folder_name"
        else
            echo "  ↪️ Skipping folder '$folder_name' (handled separately)."
        fi
    done
else
    echo "ℹ️ No S3 data found at the pod session base: $S3_POD_BASE/"
fi
echo ""

# --- User-Specific Shared Data Sync ---
echo "ℹ️ Checking for user-specific shared data in S3 at $S3_USER_SHARED_BASE/"
if aws s3 ls "$S3_USER_SHARED_BASE/" >/dev/null 2>&1; then
    user_shared_sync_folders=("venv" ".comfyui")
    for folder_name in "${user_shared_sync_folders[@]}"; do
        download_and_unzip "$S3_USER_SHARED_BASE" "$NETWORK_VOLUME" "$folder_name"
    done
else
    echo "ℹ️ No user-specific shared directory found in S3."
fi
echo ""

# --- User-Specific ComfyUI Shared Data Sync ---
echo "ℹ️ Checking for user-specific ComfyUI shared data in S3 at $S3_USER_COMFYUI_SHARED_BASE/"
if aws s3 ls "$S3_USER_COMFYUI_SHARED_BASE/" >/dev/null 2>&1; then
    mkdir -p "$NETWORK_VOLUME/ComfyUI"
    comfyui_user_shared_sync_folders=("custom_nodes")
    for folder_name in "${comfyui_user_shared_sync_folders[@]}"; do
        download_and_unzip "$S3_USER_COMFYUI_SHARED_BASE" "$NETWORK_VOLUME/ComfyUI" "$folder_name"
    done
else
    echo "ℹ️ No user-specific ComfyUI shared directory found in S3."
fi
echo ""

echo "✅ User data sync from S3 completed."
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_user_data_from_s3.sh"

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
    
    BACKGROUND_PIDS_FILE="$NETWORK_VOLUME/.background_services.pids"
    if [ -f "$BACKGROUND_PIDS_FILE" ]; then
        echo "🔄 Sending termination signals to background services..."
        while IFS=':' read -r service_name pid; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                echo "  Signaling $service_name (PID: $pid)..."
                kill -TERM "$pid" 2>/dev/null || true
            fi
        done < "$BACKGROUND_PIDS_FILE"
        
        sleep 3
        
        while IFS=':' read -r service_name pid; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                echo "  Force killing $service_name (PID: $pid)..."
                kill -9 "$pid" 2>/dev/null || true
            fi
        done < "$BACKGROUND_PIDS_FILE"
    fi
    
    "$NETWORK_VOLUME/scripts/graceful_shutdown.sh"
    exit 0
}

trap handle_signal SIGTERM SIGINT SIGQUIT

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

S3_GLOBAL_SHARED_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/global_shared/models"
LOCAL_MODELS_BASE="$NETWORK_VOLUME/ComfyUI/models"

if [[ ! -d "$LOCAL_MODELS_BASE" ]]; then
    echo "⏭️ No models directory found at $LOCAL_MODELS_BASE"
    return 0
fi

echo "📁 Syncing global shared model folders..."

for model_dir in "$LOCAL_MODELS_BASE"/*; do
    if [[ -d "$model_dir" ]]; then
        folder_name=$(basename "$model_dir")
        
        if [[ -n "$(find "$model_dir" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
            echo "  📤 Syncing global models/$folder_name to S3..."
            s3_folder_path="$S3_GLOBAL_SHARED_BASE/$folder_name/"
            
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
