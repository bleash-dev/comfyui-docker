#!/bin/bash
# Create model download integration script

# Get the target directory from the first argument
TARGET_DIR="${1:-$NETWORK_VOLUME/scripts}"
mkdir -p "$TARGET_DIR"

echo "📦 Creating model download integration script..."

# Create the model download integration script
cat > "$TARGET_DIR/model_download_integration.sh" << 'EOF'
#!/bin/bash
# Model Download Integration Script
# Provides robust model download system using S3 storage

# Source required scripts
source "$NETWORK_VOLUME/scripts/api_client.sh"
source "$NETWORK_VOLUME/scripts/model_config_manager.sh"

# Configuration
MODEL_DOWNLOAD_LOG="$NETWORK_VOLUME/.model_download_integration.log"
MODEL_DOWNLOAD_DIR="$NETWORK_VOLUME"

# Download system configuration
DOWNLOAD_QUEUE_FILE="$NETWORK_VOLUME/.download_queue.json"
DOWNLOAD_PROGRESS_FILE="$NETWORK_VOLUME/.download_progress.json"
DOWNLOAD_LOCK_DIR="$NETWORK_VOLUME/.download_locks"
DOWNLOAD_PID_FILE="$NETWORK_VOLUME/.download_worker.pid"
MAX_CONCURRENT_DOWNLOADS=3

# Ensure log file exists
mkdir -p "$(dirname "$MODEL_DOWNLOAD_LOG")"
touch "$MODEL_DOWNLOAD_LOG"

# Function to log download activities
log_download() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] Download: $message" | tee -a "$MODEL_DOWNLOAD_LOG" >&2
}

# =============================================================================
# MODEL DOWNLOAD SYSTEM
# =============================================================================

# Function to initialize download system
initialize_download_system() {
    # Create necessary directories
    mkdir -p "$(dirname "$DOWNLOAD_QUEUE_FILE")"
    mkdir -p "$(dirname "$DOWNLOAD_PROGRESS_FILE")"
    mkdir -p "$DOWNLOAD_LOCK_DIR"
    
    # Initialize queue file if it doesn't exist
    if [ ! -f "$DOWNLOAD_QUEUE_FILE" ]; then
        echo '[]' > "$DOWNLOAD_QUEUE_FILE"
    fi
    
    # Initialize progress file if it doesn't exist
    if [ ! -f "$DOWNLOAD_PROGRESS_FILE" ]; then
        echo '{}' > "$DOWNLOAD_PROGRESS_FILE"
    fi
    
    # Validate JSON files
    if ! jq empty "$DOWNLOAD_QUEUE_FILE" >/dev/null 2>&1; then
        echo '[]' > "$DOWNLOAD_QUEUE_FILE"
    fi
    
    if ! jq empty "$DOWNLOAD_PROGRESS_FILE" >/dev/null 2>&1; then
        echo '{}' > "$DOWNLOAD_PROGRESS_FILE"
    fi
    
    log_download "INFO" "Download system initialized"
}

# Function to acquire download lock
acquire_download_lock() {
    local operation="$1"
    local timeout="${2:-30}"
    local lock_file="$DOWNLOAD_LOCK_DIR/${operation}.lock"
    local end_time=$(($(date +%s) + timeout))
    
    while [ $(date +%s) -lt $end_time ]; do
        if (set -C; echo $$ > "$lock_file") 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    
    log_download "ERROR" "Failed to acquire lock for operation: $operation"
    return 1
}

# Function to release download lock
release_download_lock() {
    local operation="$1"
    local lock_file="$DOWNLOAD_LOCK_DIR/${operation}.lock"
    
    if [ -f "$lock_file" ]; then
        local lock_pid
        lock_pid=$(cat "$lock_file" 2>/dev/null || echo "")
        if [ "$lock_pid" = "$$" ]; then
            rm -f "$lock_file"
        fi
    fi
}

# Function to add download to queue (prevents duplicates)
add_to_download_queue() {
    local group="$1"
    local model_name="$2"
    local s3_path="$3"
    local local_path="$4"
    local total_size="$5"
    
    if [ -z "$group" ] || [ -z "$model_name" ] || [ -z "$s3_path" ] || [ -z "$local_path" ]; then
        log_download "ERROR" "Missing required parameters for queue addition"
        return 1
    fi
    
    initialize_download_system
    
    if ! acquire_download_lock "queue" 30; then
        log_download "ERROR" "Failed to acquire queue lock"
        return 1
    fi
    
    trap "release_download_lock 'queue'" EXIT INT TERM QUIT
    
    # Check if download already exists in queue
    local existing_count
    existing_count=$(jq --arg group "$group" --arg modelName "$model_name" \
        '[.[] | select(.group == $group and .modelName == $modelName)] | length' \
        "$DOWNLOAD_QUEUE_FILE" 2>/dev/null || echo "0")
    
    if [ "$existing_count" -gt 0 ]; then
        log_download "INFO" "Download already in queue: $group/$model_name"
        release_download_lock "queue"
        trap - EXIT INT TERM QUIT
        return 0
    fi
    
    # Add to queue with S3 path
    local temp_file
    temp_file=$(mktemp)
    
    jq --arg group "$group" \
       --arg modelName "$model_name" \
       --arg s3Path "$s3_path" \
       --arg localPath "$local_path" \
       --argjson totalSize "${total_size:-0}" \
       --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")" \
       '. + [{
           "group": $group,
           "modelName": $modelName,
           "s3Path": $s3Path,
           "localPath": $localPath,
           "totalSize": $totalSize,
           "queuedAt": $timestamp
       }]' "$DOWNLOAD_QUEUE_FILE" > "$temp_file"
    
    if [ $? -eq 0 ] && jq empty "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$DOWNLOAD_QUEUE_FILE"
        log_download "INFO" "Added to download queue: $group/$model_name (S3: $s3_path)"
        
        # Update progress status to queued
        update_download_progress "$group" "$model_name" "$local_path" "${total_size:-0}" 0 "queued"
        
        release_download_lock "queue"
        trap - EXIT INT TERM QUIT
        return 0
    else
        rm -f "$temp_file"
        log_download "ERROR" "Failed to add to download queue"
        release_download_lock "queue"
        trap - EXIT INT TERM QUIT
        return 1
    fi
}

# Function to remove from download queue
remove_from_download_queue() {
    local group="$1"
    local model_name="$2"
    
    if [ -z "$group" ] || [ -z "$model_name" ]; then
        log_download "ERROR" "Missing required parameters for queue removal"
        return 1
    fi
    
    if ! acquire_download_lock "queue" 30; then
        log_download "ERROR" "Failed to acquire queue lock"
        return 1
    fi
    
    trap "release_download_lock 'queue'" EXIT INT TERM QUIT
    
    local temp_file
    temp_file=$(mktemp)
    
    jq --arg group "$group" --arg modelName "$model_name" \
       'map(select(.group != $group or .modelName != $modelName))' \
       "$DOWNLOAD_QUEUE_FILE" > "$temp_file"
    
    if [ $? -eq 0 ] && jq empty "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$DOWNLOAD_QUEUE_FILE"
        log_download "INFO" "Removed from download queue: $group/$model_name"
        
        release_download_lock "queue"
        trap - EXIT INT TERM QUIT
        return 0
    else
        rm -f "$temp_file"
        log_download "ERROR" "Failed to remove from download queue"
        release_download_lock "queue"
        trap - EXIT INT TERM QUIT
        return 1
    fi
}

# Function to get next download from queue
get_next_download() {
    local output_file="${1:-}"
    
    if [ -z "$output_file" ]; then
        output_file=$(mktemp)
    fi
    
    if ! acquire_download_lock "queue" 30; then
        log_download "ERROR" "Failed to acquire queue lock"
        return 1
    fi
    
    trap "release_download_lock 'queue'" EXIT INT TERM QUIT
    
    # Get first item from queue
    jq '.[0] // empty' "$DOWNLOAD_QUEUE_FILE" > "$output_file" 2>/dev/null
    
    if [ -s "$output_file" ]; then
        # Remove first item from queue
        local temp_file
        temp_file=$(mktemp)
        
        jq '.[1:]' "$DOWNLOAD_QUEUE_FILE" > "$temp_file"
        
        if [ $? -eq 0 ] && jq empty "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$DOWNLOAD_QUEUE_FILE"
        else
            rm -f "$temp_file"
        fi
        
        release_download_lock "queue"
        trap - EXIT INT TERM QUIT
        echo "$output_file"
        return 0
    else
        release_download_lock "queue"
        trap - EXIT INT TERM QUIT
        rm -f "$output_file"
        return 1
    fi
}

# Function to count active downloads
count_active_downloads() {
    if [ ! -f "$DOWNLOAD_PROGRESS_FILE" ]; then
        echo "0"
        return 0
    fi
    
    # Count downloads with 'progress' status across all groups
    local count
    count=$(jq '[.. | objects | select(.status == "progress")] | length' "$DOWNLOAD_PROGRESS_FILE" 2>/dev/null || echo "0")
    echo "$count"
}

# Function to update download progress
update_download_progress() {
    local group="$1"
    local model_name="$2"
    local local_path="$3"
    local total_size="$4"
    local downloaded="$5"
    local status="$6"
    
    if [ -z "$group" ] || [ -z "$model_name" ] || [ -z "$status" ]; then
        log_download "ERROR" "Missing required parameters for progress update"
        return 1
    fi
    
    if ! acquire_download_lock "progress" 30; then
        log_download "ERROR" "Failed to acquire progress lock"
        return 1
    fi
    
    trap "release_download_lock 'progress'" EXIT INT TERM QUIT
    
    local temp_file
    temp_file=$(mktemp)
    
    jq --arg group "$group" \
       --arg modelName "$model_name" \
       --arg localPath "${local_path:-}" \
       --argjson totalSize "${total_size:-0}" \
       --argjson downloaded "${downloaded:-0}" \
       --arg status "$status" \
       --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")" \
       '
       .[$group] = (.[$group] // {}) |
       .[$group][$modelName] = {
           "totalSize": $totalSize,
           "localPath": $localPath,
           "downloaded": $downloaded,
           "status": $status,
           "lastUpdated": $timestamp
       }' "$DOWNLOAD_PROGRESS_FILE" > "$temp_file"
    
    if [ $? -eq 0 ] && jq empty "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$DOWNLOAD_PROGRESS_FILE"
        
        release_download_lock "progress"
        trap - EXIT INT TERM QUIT
        return 0
    else
        rm -f "$temp_file"
        log_download "ERROR" "Failed to update download progress"
        release_download_lock "progress"
        trap - EXIT INT TERM QUIT
        return 1
    fi
}

# Function to download a single model with progress tracking from S3
download_model_with_progress() {
    local group="$1"
    local model_name="$2"
    local s3_path="$3"  # This is the originalS3Path from config
    local local_path="$4"
    local total_size="$5"
    
    if [ -z "$group" ] || [ -z "$model_name" ] || [ -z "$s3_path" ] || [ -z "$local_path" ]; then
        log_download "ERROR" "Missing required parameters for model download"
        return 1
    fi
    
    # Check for cancellation before starting
    if is_download_cancelled "$group" "$model_name"; then
        log_download "INFO" "Download cancelled before starting: $group/$model_name"
        update_download_progress "$group" "$model_name" "$local_path" "$total_size" 0 "cancelled"
        return 1
    fi
    
    # Ensure s3_path is properly formatted
    local full_s3_path="$s3_path"
    if [[ "$s3_path" != s3://* ]]; then
        if [[ "$s3_path" == /* ]]; then
            # Remove leading slash and prepend bucket
            full_s3_path="s3://$AWS_BUCKET_NAME${s3_path}"
        else
            full_s3_path="s3://$AWS_BUCKET_NAME/$s3_path"
        fi
    fi
    
    log_download "INFO" "Starting S3 download: $group/$model_name from $full_s3_path"
    
    # Create directory if needed
    local dir_path
    dir_path=$(dirname "$local_path")
    if [ ! -d "$dir_path" ]; then
        mkdir -p "$dir_path"
    fi
    
    # Update status to in progress
    update_download_progress "$group" "$model_name" "$local_path" "$total_size" 0 "progress"
    
    # Create a temporary file for download
    local temp_download_path="${local_path}.downloading"
    
    # Download from S3 with progress tracking and cancellation checks
    local download_success=false
    
    log_download "INFO" "Downloading from S3: $full_s3_path -> $temp_download_path"
    
    # Start AWS CLI download in background so we can monitor for cancellation
    # Use AWS_CLI_OVERRIDE if set (for testing)
    local aws_cmd="aws"
    if [ -n "${AWS_CLI_OVERRIDE:-}" ] && [ -x "$AWS_CLI_OVERRIDE" ]; then
        aws_cmd="$AWS_CLI_OVERRIDE"
    fi
    
    "$aws_cmd" s3 cp "$full_s3_path" "$temp_download_path" --only-show-errors &
    local aws_pid=$!
    
    # Monitor download progress and check for cancellation
    local check_interval=1
    local last_size=0
    local stall_count=0
    local max_stalls=30  # 30 seconds without progress
    
    while kill -0 "$aws_pid" 2>/dev/null; do
        # Check for cancellation
        if is_download_cancelled "$group" "$model_name"; then
            log_download "INFO" "Download cancelled during progress: $group/$model_name"
            kill "$aws_pid" 2>/dev/null || true
            rm -f "$temp_download_path"
            update_download_progress "$group" "$model_name" "$local_path" "$total_size" 0 "cancelled"
            return 1
        fi
        
        # Check download progress for large files
        if [ -f "$temp_download_path" ]; then
            local current_size
            current_size=$(stat -f%z "$temp_download_path" 2>/dev/null || stat -c%s "$temp_download_path" 2>/dev/null || echo "0")
            
            # Update progress
            if [ "$total_size" -gt 0 ]; then
                local percentage=$((current_size * 100 / total_size))
                update_download_progress "$group" "$model_name" "$local_path" "$total_size" "$current_size" "progress"
                
                # Log progress for large files (every 10% or if over 10MB)
                if [ "$total_size" -gt 10485760 ] && [ $((current_size % (total_size / 10))) -lt $((last_size % (total_size / 10))) ]; then
                    log_download "INFO" "Download progress: $group/$model_name ($percentage%)"
                fi
            fi
            
            # Check for stalled download
            if [ "$current_size" -eq "$last_size" ]; then
                stall_count=$((stall_count + 1))
                if [ "$stall_count" -ge "$max_stalls" ]; then
                    log_download "WARN" "Download appears stalled, terminating: $group/$model_name"
                    kill "$aws_pid" 2>/dev/null || true
                    break
                fi
            else
                stall_count=0
            fi
            
            last_size="$current_size"
        fi
        
        sleep "$check_interval"
    done
    
    # Wait for AWS CLI to complete and get exit status
    wait "$aws_pid" 2>/dev/null
    local aws_exit_code=$?
    
    # Check final cancellation state
    if is_download_cancelled "$group" "$model_name"; then
        log_download "INFO" "Download was cancelled: $group/$model_name"
        rm -f "$temp_download_path"
        update_download_progress "$group" "$model_name" "$local_path" "$total_size" 0 "cancelled"
        return 1
    fi
    
    # Check if download succeeded
    if [ "$aws_exit_code" -eq 0 ] && [ -f "$temp_download_path" ]; then
        download_success=true
        log_download "INFO" "S3 download completed: $full_s3_path"
    else
        download_success=false
        log_download "ERROR" "S3 download failed for $full_s3_path (exit code: $aws_exit_code)"
    fi
    
    if [ "$download_success" = true ] && [ -f "$temp_download_path" ]; then
        # Verify download size if total_size was provided
        local actual_size
        actual_size=$(stat -f%z "$temp_download_path" 2>/dev/null || stat -c%s "$temp_download_path" 2>/dev/null || echo "0")
        
        if [ "$total_size" -gt 0 ] && [ "$actual_size" -ne "$total_size" ]; then
            log_download "WARN" "Downloaded size ($actual_size) doesn't match expected size ($total_size) for $model_name"
        fi
        
        # Move temp file to final location
        if mv "$temp_download_path" "$local_path"; then
            local final_size
            final_size=$(stat -f%z "$local_path" 2>/dev/null || stat -c%s "$local_path" 2>/dev/null || echo "0")
            
            # Update final progress
            update_download_progress "$group" "$model_name" "$local_path" "$final_size" "$final_size" "completed"
            
            log_download "INFO" "Download completed successfully: $group/$model_name ($final_size bytes)"
            
            # Resolve symlinks for this model
            log_download "INFO" "Resolving symlinks for downloaded model: $group/$model_name"
            if command -v resolve_symlinks >/dev/null 2>&1; then
                resolve_symlinks "" "$model_name" false
            else
                log_download "WARN" "resolve_symlinks function not available"
            fi
            
            return 0
        else
            log_download "ERROR" "Failed to move downloaded file to final location: $local_path"
            rm -f "$temp_download_path"
            update_download_progress "$group" "$model_name" "$local_path" "$total_size" 0 "failed"
            return 1
        fi
    else
        log_download "ERROR" "Download failed: $group/$model_name"
        rm -f "$temp_download_path"
        update_download_progress "$group" "$model_name" "$local_path" "$total_size" 0 "failed"
        return 1
    fi
}

# Function to start download worker (processes queue)
start_download_worker() {
    # Skip worker for testing
    if [ "${SKIP_BACKGROUND_WORKER:-false}" = "true" ]; then
        log_download "INFO" "Skipping background worker (test mode)"
        return 0
    fi
    
    # Check if worker is already running
    if [ -f "$DOWNLOAD_PID_FILE" ]; then
        local pid
        pid=$(cat "$DOWNLOAD_PID_FILE" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log_download "INFO" "Download worker already running (PID: $pid)"
            return 0
        else
            rm -f "$DOWNLOAD_PID_FILE"
        fi
    fi
    
    # Start worker in background
    (
        echo $$ > "$DOWNLOAD_PID_FILE"
        trap "rm -f '$DOWNLOAD_PID_FILE'" EXIT INT TERM QUIT
        
        log_download "INFO" "Download worker started (PID: $$)"
        
        # Track background download processes using simple arrays
        local download_pids=()
        local download_keys=()
        
        while true; do
            # Check for global stop signal
            if should_stop_all_downloads; then
                log_download "INFO" "Global stop signal received, shutting down worker"
                # Wait for active downloads to finish
                for pid in "${download_pids[@]}"; do
                    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                        log_download "INFO" "Waiting for download process $pid to finish"
                        wait "$pid" 2>/dev/null || true
                    fi
                done
                break
            fi
            
            # Clean up completed downloads
            local new_pids=()
            local new_keys=()
            for i in "${!download_pids[@]}"; do
                local pid="${download_pids[$i]}"
                local key="${download_keys[$i]}"
                if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                    new_pids+=("$pid")
                    new_keys+=("$key")
                else
                    if [ -n "$key" ]; then
                        log_download "DEBUG" "Download process $pid for $key completed"
                    fi
                fi
            done
            # Handle empty arrays properly
            if [ ${#new_pids[@]} -eq 0 ]; then
                download_pids=()
                download_keys=()
            else
                download_pids=("${new_pids[@]}")
                download_keys=("${new_keys[@]}")
            fi
            
            # Check if we can start more downloads
            local running_count=${#download_pids[@]}
            
            if [ "$running_count" -lt "$MAX_CONCURRENT_DOWNLOADS" ]; then
                local next_download_file
                next_download_file=$(get_next_download)
                
                if [ $? -eq 0 ] && [ -f "$next_download_file" ]; then
                    local group model_name s3_path local_path total_size
                    group=$(jq -r '.group // empty' "$next_download_file")
                    model_name=$(jq -r '.modelName // empty' "$next_download_file")
                    s3_path=$(jq -r '.s3Path // empty' "$next_download_file")
                    local_path=$(jq -r '.localPath // empty' "$next_download_file")
                    total_size=$(jq -r '.totalSize // 0' "$next_download_file")
                    
                    rm -f "$next_download_file"
                    
                    if [ -n "$group" ] && [ -n "$model_name" ] && [ -n "$s3_path" ] && [ -n "$local_path" ]; then
                        # Start download in background
                        (
                            download_model_with_progress "$group" "$model_name" "$s3_path" "$local_path" "$total_size"
                        ) &
                        local download_pid=$!
                        download_pids+=("$download_pid")
                        download_keys+=("${group}/${model_name}")
                        log_download "INFO" "Started download ${group}/${model_name} (PID: $download_pid, Active: $((running_count + 1))/$MAX_CONCURRENT_DOWNLOADS)"
                    else
                        log_download "ERROR" "Invalid download entry in queue"
                    fi
                else
                    # No downloads in queue, sleep and check again
                    sleep 2
                fi
            else
                # At max capacity, wait a bit before checking again
                sleep 1
            fi
        done
    ) &
    
    local worker_pid=$!
    log_download "INFO" "Download worker started in background (PID: $worker_pid)"
    
    return 0
}

# Function to stop download worker
# Works independently regardless of execution scope
stop_download_worker() {
    local force_stop="${1:-false}"
    
    # Multiple strategies to find and stop the download worker
    local stopped=false
    
    # Strategy 1: Use PID file if it exists
    if [ -f "$DOWNLOAD_PID_FILE" ]; then
        local pid
        pid=$(cat "$DOWNLOAD_PID_FILE" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log_download "INFO" "Stopping download worker via PID file (PID: $pid)"
            kill -TERM "$pid" 2>/dev/null || true
            
            # Give it time to shutdown gracefully
            local wait_count=0
            while [ $wait_count -lt 5 ] && kill -0 "$pid" 2>/dev/null; do
                sleep 1
                wait_count=$((wait_count + 1))
            done
            
            # Force kill if still running
            if kill -0 "$pid" 2>/dev/null; then
                log_download "WARN" "Force killing download worker (PID: $pid)"
                kill -KILL "$pid" 2>/dev/null || true
            fi
            
            stopped=true
        fi
        rm -f "$DOWNLOAD_PID_FILE"
    fi
    
    # Strategy 2: Find download worker processes by pattern
    if [ "$stopped" = false ] || [ "$force_stop" = true ]; then
        local worker_pids
        worker_pids=$(pgrep -f "download.*worker" 2>/dev/null || true)
        
        if [ -z "$worker_pids" ]; then
            # Look for AWS CLI processes that might be downloading (handle both real and mock aws)
            worker_pids=$(pgrep -f "s3.*cp" 2>/dev/null || true)
            if [ -z "$worker_pids" ]; then
                worker_pids=$(pgrep -f "aws.*s3.*cp" 2>/dev/null || true)
            fi
        fi
        
        if [ -n "$worker_pids" ]; then
            log_download "INFO" "Stopping download processes found by pattern"
            echo "$worker_pids" | xargs kill -TERM 2>/dev/null || true
            sleep 2
            # Force kill any remaining
            echo "$worker_pids" | xargs kill -KILL 2>/dev/null || true
            stopped=true
        fi
    fi
    
    # Strategy 3: Create a global stop signal
    local stop_signal_file="$MODEL_DOWNLOAD_DIR/.stop_all_downloads"
    touch "$stop_signal_file"
    
    # Clean up stop signal after a delay
    (sleep 10; rm -f "$stop_signal_file") &
    
    # Cancel all pending downloads if force stop
    if [ "$force_stop" = true ]; then
        log_download "INFO" "Force stopping - cancelling all pending downloads"
        if [ -f "$DOWNLOAD_QUEUE_FILE" ]; then
            # Cancel each queued download
            local queue_items
            queue_items=$(jq -r '.[] | @base64' "$DOWNLOAD_QUEUE_FILE" 2>/dev/null || true)
            
            if [ -n "$queue_items" ]; then
                while IFS= read -r item; do
                    if [ -n "$item" ]; then
                        local decoded
                        decoded=$(echo "$item" | base64 -d 2>/dev/null || true)
                        if [ -n "$decoded" ]; then
                            local group model_name
                            group=$(echo "$decoded" | jq -r '.group // empty')
                            model_name=$(echo "$decoded" | jq -r '.modelName // empty')
                            
                            if [ -n "$group" ] && [ -n "$model_name" ]; then
                                cancel_download "$group" "$model_name" ""
                            fi
                        fi
                    fi
                done <<< "$queue_items"
            fi
        fi
    fi
    
    if [ "$stopped" = true ]; then
        log_download "INFO" "Download worker stopped successfully"
    else
        log_download "INFO" "No active download worker found to stop"
    fi
    
    return 0
}

# Function to check if all downloads should be stopped (global stop signal)
should_stop_all_downloads() {
    local stop_signal_file="$MODEL_DOWNLOAD_DIR/.stop_all_downloads"
    [ -f "$stop_signal_file" ]
}

# Function to download models (main API function)
# Supports downloading all models, only missing models, a list of models, or a single model
# Uses originalS3Path from model config for S3 downloads
download_models() {
    local mode="${1:-}"        # "all", "missing", "list", or "single"
    local models_param="${2:-}" # JSON array for "list" mode, or single model object for "single" mode
    local output_file="${3:-}"  # Optional: file to write progress JSON to
    
    if [ -z "$mode" ]; then
        log_download "ERROR" "Download mode is required (all, missing, list, single)"
        return 1
    fi
    
    # Default output file if not provided
    if [ -z "$output_file" ]; then
        output_file=$(mktemp)
    fi
    
    initialize_download_system
    
    log_download "INFO" "Starting model download in mode: $mode"
    
    # Start download worker if not running
    start_download_worker
    
    local models_to_download=()
    local total_models=0
    
    case "$mode" in
        "all")
            # Load all local models from config
            local all_models_file
            if command -v load_local_models >/dev/null 2>&1; then
                all_models_file=$(load_local_models)
                
                if [ $? -eq 0 ] && [ -f "$all_models_file" ]; then
                    while IFS= read -r model; do
                        models_to_download+=("$model")
                    done < <(jq -c '.[]' "$all_models_file" 2>/dev/null)
                    rm -f "$all_models_file"
                fi
            else
                log_download "WARN" "load_local_models function not available"
            fi
            ;;
            
        "missing")
            # Load all local models and check which ones don't exist locally
            local all_models_file
            if command -v load_local_models >/dev/null 2>&1; then
                all_models_file=$(load_local_models)
                
                if [ $? -eq 0 ] && [ -f "$all_models_file" ]; then
                    while IFS= read -r model; do
                        local local_path
                        local_path=$(echo "$model" | jq -r '.localPath // empty')
                        
                        if [ -n "$local_path" ] && [ ! -f "$local_path" ]; then
                            models_to_download+=("$model")
                        fi
                    done < <(jq -c '.[]' "$all_models_file" 2>/dev/null)
                    rm -f "$all_models_file"
                fi
            else
                log_download "WARN" "load_local_models function not available"
            fi
            ;;
            
        "list")
            if [ -z "$models_param" ]; then
                log_download "ERROR" "Models list is required for 'list' mode"
                return 1
            fi
            
            # Validate JSON array
            if ! echo "$models_param" | jq -e 'type == "array"' >/dev/null 2>&1; then
                log_download "ERROR" "Models parameter must be a JSON array for 'list' mode"
                return 1
            fi
            
            while IFS= read -r model; do
                models_to_download+=("$model")
            done < <(echo "$models_param" | jq -c '.[]' 2>/dev/null)
            ;;
            
        "single")
            if [ -z "$models_param" ]; then
                log_download "ERROR" "Model object is required for 'single' mode"
                return 1
            fi
            
            # Validate JSON object
            if ! echo "$models_param" | jq -e 'type == "object"' >/dev/null 2>&1; then
                log_download "ERROR" "Models parameter must be a JSON object for 'single' mode"
                return 1
            fi
            
            models_to_download+=("$models_param")
            ;;
            
        *)
            log_download "ERROR" "Invalid download mode: $mode"
            return 1
            ;;
    esac
    
    total_models=${#models_to_download[@]}
    
    if [ $total_models -eq 0 ]; then
        log_download "INFO" "No models to download for mode: $mode"
        # Return current progress file
        cp "$DOWNLOAD_PROGRESS_FILE" "$output_file"
        echo "$output_file"
        return 0
    fi
    
    log_download "INFO" "Found $total_models model(s) to download"
    
    # Add models to download queue using originalS3Path
    local queued_count=0
    for model in "${models_to_download[@]}"; do
        local group model_name original_s3_path local_path model_size
        
        group=$(echo "$model" | jq -r '.directoryGroup // empty')
        model_name=$(echo "$model" | jq -r '.modelName // empty')
        original_s3_path=$(echo "$model" | jq -r '.originalS3Path // empty')
        local_path=$(echo "$model" | jq -r '.localPath // empty')
        model_size=$(echo "$model" | jq -r '.modelSize // 0')
        
        if [ -z "$group" ] || [ -z "$model_name" ] || [ -z "$original_s3_path" ] || [ -z "$local_path" ]; then
            log_download "WARN" "Skipping model with missing required fields: $model_name"
            continue
        fi
        
        # Skip if file already exists (unless this is "all" mode)
        if [ "$mode" != "all" ] && [ -f "$local_path" ]; then
            log_download "INFO" "Skipping existing file: $local_path"
            continue
        fi
        
        if add_to_download_queue "$group" "$model_name" "$original_s3_path" "$local_path" "$model_size"; then
            queued_count=$((queued_count + 1))
        fi
    done
    
    log_download "INFO" "Queued $queued_count model(s) for download"
    
    # Return current progress file
    cp "$DOWNLOAD_PROGRESS_FILE" "$output_file"
    echo "$output_file"
    return 0
}

# Function to get download progress for a specific model
get_download_progress() {
    local group="${1:-}"
    local model_name="${2:-}"
    local local_path="${3:-}"
    local output_file="${4:-}"
    
    # Support both modes: by group/name or by local path
    if [ -z "$output_file" ]; then
        output_file=$(mktemp)
    fi
    
    initialize_download_system
    
    if [ -n "$group" ] && [ -n "$model_name" ] && [ "$group" != "" ] && [ "$model_name" != "" ]; then
        # Search by group and model name
        jq --arg group "$group" --arg modelName "$model_name" \
           '.[$group][$modelName] // {}' "$DOWNLOAD_PROGRESS_FILE" > "$output_file" 2>/dev/null
    elif [ -n "$local_path" ] && [ "$local_path" != "" ]; then
        # Search by local path across all groups
        jq --arg localPath "$local_path" \
           '[.. | objects | select(.localPath == $localPath)][0] // {}' \
           "$DOWNLOAD_PROGRESS_FILE" > "$output_file" 2>/dev/null
    else
        log_download "ERROR" "Either group/model_name or local_path must be provided"
        return 1
    fi
    
    if [ -s "$output_file" ]; then
        echo "$output_file"
        return 0
    else
        echo "{}" > "$output_file"
        echo "$output_file"
        return 1
    fi
}

# Function to get all download progress
get_all_download_progress() {
    local output_file="$1"
    
    if [ -z "$output_file" ]; then
        output_file=$(mktemp)
    fi
    
    initialize_download_system
    
    cp "$DOWNLOAD_PROGRESS_FILE" "$output_file"
    echo "$output_file"
    return 0
}

# Function to check if download is cancelled
is_download_cancelled() {
    local group="$1"
    local model_name="$2"
    
    if [ -z "$group" ] || [ -z "$model_name" ]; then
        return 1
    fi
    
    # Check for cancellation signal file
    local cancel_signal_file="$MODEL_DOWNLOAD_DIR/.cancel_${group}_${model_name}"
    if [ -f "$cancel_signal_file" ]; then
        return 0
    fi
    
    # Check for global stop signal
    if [ -f "$MODEL_DOWNLOAD_DIR/.stop_all_downloads" ]; then
        return 0
    fi
    
    return 1
}

# Function to terminate active download processes
terminate_active_download() {
    local group="$1"
    local model_name="$2"
    
    if [ -z "$group" ] || [ -z "$model_name" ]; then
        log_download "ERROR" "Group and model name required for termination"
        return 1
    fi
    
    # Look for AWS CLI processes downloading this specific model
    # Use a more specific pattern to avoid killing unrelated processes
    local download_pattern="${group}.*${model_name}"
    
    # Find and kill AWS CLI download processes for this model
    # Handle both real aws and mock_aws patterns
    local pids
    pids=$(pgrep -f "s3 cp.*${download_pattern}" 2>/dev/null || true)
    
    if [ -z "$pids" ]; then
        # Try alternative pattern matching
        pids=$(pgrep -f "aws.*${download_pattern}" 2>/dev/null || true)
    fi
    
    if [ -n "$pids" ]; then
        echo "$pids" | while read -r pid; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                log_download "INFO" "Terminating download process $pid for $group/$model_name"
                kill -TERM "$pid" 2>/dev/null || true
                # Give it a moment, then force kill if necessary
                sleep 1
                if kill -0 "$pid" 2>/dev/null; then
                    kill -KILL "$pid" 2>/dev/null || true
                fi
            fi
        done
    fi
    
    # Also look for any background download processes that might be running
    local worker_pids
    worker_pids=$(pgrep -f "download_worker.*${group}.*${model_name}" 2>/dev/null || true)
    
    if [ -n "$worker_pids" ]; then
        echo "$worker_pids" | while read -r pid; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                log_download "INFO" "Terminating worker process $pid for $group/$model_name"
                kill -TERM "$pid" 2>/dev/null || true
                sleep 1
                if kill -0 "$pid" 2>/dev/null; then
                    kill -KILL "$pid" 2>/dev/null || true
                fi
            fi
        done
    fi
    
    return 0
}

# Function to cancel download
# Supports cancellation by group/model_name or by local_path
# Works independently regardless of worker state or execution scope
cancel_download() {
    local group="$1"
    local model_name="$2"
    local local_path="$3"
    
    # Support both modes: by group/name or by local path
    if [ -z "$model_name" ] && [ -z "$local_path" ]; then
        log_download "ERROR" "Either group/model_name or local_path must be provided for cancellation"
        return 1
    fi
    
    initialize_download_system
    
    # Find the download to cancel
    local target_group="$group"
    local target_model_name="$model_name"
    
    if [ -z "$target_group" ] || [ -z "$target_model_name" ]; then
        # Find by local path in queue or progress
        if [ -n "$local_path" ]; then
            # Search in queue first
            local queue_entry
            if [ -f "$DOWNLOAD_QUEUE_FILE" ]; then
                queue_entry=$(jq --arg localPath "$local_path" '.[] | select(.localPath == $localPath)' "$DOWNLOAD_QUEUE_FILE" 2>/dev/null)
                if [ -n "$queue_entry" ]; then
                    target_group=$(echo "$queue_entry" | jq -r '.group // empty')
                    target_model_name=$(echo "$queue_entry" | jq -r '.modelName // empty')
                fi
            fi
            
            # If not in queue, search in progress files
            if [ -z "$target_group" ] || [ -z "$target_model_name" ]; then
                if [ -f "$DOWNLOAD_PROGRESS_FILE" ]; then
                    # Search all groups and models for matching local path
                    local found_entry
                    found_entry=$(jq -r --arg localPath "$local_path" '
                        to_entries[] | 
                        select(.value | type == "object") |
                        .key as $group |
                        (.value | to_entries[] | 
                         select(.value.localPath == $localPath) |
                         {group: $group, modelName: .key, data: .value})
                    ' "$DOWNLOAD_PROGRESS_FILE" 2>/dev/null | head -1)
                    
                    if [ -n "$found_entry" ]; then
                        target_group=$(echo "$found_entry" | jq -r '.group // empty')
                        target_model_name=$(echo "$found_entry" | jq -r '.modelName // empty')
                    fi
                fi
            fi
        fi
    fi
    
    if [ -z "$target_group" ] || [ -z "$target_model_name" ]; then
        log_download "ERROR" "Could not find download to cancel for: ${local_path:-$group/$model_name}"
        return 1
    fi
    
    log_download "INFO" "Cancelling download: $target_group/$target_model_name"
    
    # Create cancellation signal file for active downloads
    local cancel_signal_file="$MODEL_DOWNLOAD_DIR/.cancel_${target_group}_${target_model_name}"
    touch "$cancel_signal_file"
    
    # Remove from queue (if queued)
    remove_from_download_queue "$target_group" "$target_model_name"
    
    # Kill any active download processes for this model
    terminate_active_download "$target_group" "$target_model_name"
    
    # Update progress status to cancelled
    local current_local_path current_total_size current_downloaded
    
    # Get current progress if available
    if [ -f "$DOWNLOAD_PROGRESS_FILE" ]; then
        local progress_data
        progress_data=$(jq -r --arg group "$target_group" --arg model "$target_model_name" '
            .[$group][$model] // {}
        ' "$DOWNLOAD_PROGRESS_FILE" 2>/dev/null)
        
        if [ "$progress_data" != "{}" ] && [ "$progress_data" != "null" ]; then
            current_local_path=$(echo "$progress_data" | jq -r '.localPath // empty')
            current_total_size=$(echo "$progress_data" | jq -r '.totalSize // 0')
            current_downloaded=$(echo "$progress_data" | jq -r '.downloaded // 0')
        fi
    fi
    
    # Use provided local_path if not found in progress
    if [ -z "$current_local_path" ] && [ -n "$local_path" ]; then
        current_local_path="$local_path"
    fi
    
    # Clean up any partial download files
    if [ -n "$current_local_path" ]; then
        rm -f "${current_local_path}.downloading"
        rm -f "${current_local_path}.download_progress"
    fi
    
    # Update progress to cancelled
    update_download_progress "$target_group" "$target_model_name" "$current_local_path" "${current_total_size:-0}" "${current_downloaded:-0}" "cancelled"
    
    # Clean up cancellation signal after a delay (in background)
    (sleep 5; rm -f "$cancel_signal_file") &
    
    log_download "INFO" "Download cancelled: $target_group/$target_model_name"
    return 0
}

# Convenience function to cancel download by local path only
cancel_download_by_path() {
    local local_path="$1"
    
    if [ -z "$local_path" ]; then
        log_download "ERROR" "Local path is required for cancellation"
        return 1
    fi
    
    cancel_download "" "" "$local_path"
}

# Convenience function to cancel all downloads
cancel_all_downloads() {
    log_download "INFO" "Cancelling all active and queued downloads"
    
    # Stop worker with force flag
    stop_download_worker true
    
    # Clear the queue
    if [ -f "$DOWNLOAD_QUEUE_FILE" ]; then
        echo '[]' > "$DOWNLOAD_QUEUE_FILE"
    fi
    
    # Update all in-progress downloads to cancelled
    if [ -f "$DOWNLOAD_PROGRESS_FILE" ]; then
        local temp_file
        temp_file=$(mktemp)
        
        jq '
            to_entries | map(
                .value = (
                    .value | to_entries | map(
                        if .value.status == "progress" then
                            .value.status = "cancelled"
                        else
                            .
                        end
                    ) | from_entries
                )
            ) | from_entries
        ' "$DOWNLOAD_PROGRESS_FILE" > "$temp_file" && mv "$temp_file" "$DOWNLOAD_PROGRESS_FILE"
    fi
    
    log_download "INFO" "All downloads cancelled"
    return 0
}

# Function to list active downloads (for monitoring/management)
list_active_downloads() {
    local format="${1:-json}"  # json, table, or simple
    
    initialize_download_system
    
    local active_count=0
    local queued_count=0
    local output=""
    
    # Count queued downloads
    if [ -f "$DOWNLOAD_QUEUE_FILE" ]; then
        queued_count=$(jq 'length' "$DOWNLOAD_QUEUE_FILE" 2>/dev/null || echo "0")
    fi
    
    # Process active downloads from progress file
    if [ -f "$DOWNLOAD_PROGRESS_FILE" ]; then
        if [ "$format" = "json" ]; then
            # Return full JSON structure
            jq '.' "$DOWNLOAD_PROGRESS_FILE"
            return 0
        fi
        
        # Parse for other formats
        local progress_data
        progress_data=$(jq -r '
            to_entries[] |
            select(.value | type == "object") |
            .key as $group |
            (.value | to_entries[] |
             select(.value.status and (.value.status == "progress" or .value.status == "queued")) |
             [$group, .key, .value.status, .value.localPath, .value.downloaded, .value.totalSize] |
             @tsv)
        ' "$DOWNLOAD_PROGRESS_FILE" 2>/dev/null)
        
        if [ -n "$progress_data" ]; then
            if [ "$format" = "table" ]; then
                output="Group\tModel\tStatus\tLocal Path\tProgress\n"
                output="$output$(echo "$progress_data" | while IFS=$'\t' read -r group model status path downloaded total; do
                    local progress_pct=0
                    if [ "$total" -gt 0 ] && [ "$downloaded" -gt 0 ]; then
                        progress_pct=$((downloaded * 100 / total))
                    fi
                    echo "$group\t$model\t$status\t$path\t${progress_pct}%"
                done)"
                echo -e "$output" | column -t
            else
                # Simple format
                echo "$progress_data" | while IFS=$'\t' read -r group model status path downloaded total; do
                    local progress_pct=0
                    if [ "$total" -gt 0 ] && [ "$downloaded" -gt 0 ]; then
                        progress_pct=$((downloaded * 100 / total))
                    fi
                    echo "$group/$model: $status (${progress_pct}%)"
                done
            fi
            
            active_count=$(echo "$progress_data" | wc -l)
        fi
    fi
    
    if [ "$format" != "json" ]; then
        echo ""
        echo "Summary: $active_count active downloads, $queued_count queued"
    fi
    
    return 0
}

EOF

chmod +x "$NETWORK_VOLUME/scripts/model_download_integration.sh"

echo "✅ Model download integration script created at $NETWORK_VOLUME/scripts/model_download_integration.sh"
