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
source "$NETWORK_VOLUME/scripts/s3_interactor.sh"

# Configuration
MODEL_DOWNLOAD_LOG="$NETWORK_VOLUME/.model_download_integration.log"
MODEL_DOWNLOAD_DIR="$NETWORK_VOLUME"

# Download system configuration
DOWNLOAD_QUEUE_FILE="$NETWORK_VOLUME/.download_queue.json"
DOWNLOAD_PROGRESS_FILE="$NETWORK_VOLUME/.download_progress.json"
DOWNLOAD_LOCK_DIR="$NETWORK_VOLUME/.download_locks"
DOWNLOAD_PID_FILE="$NETWORK_VOLUME/.download_worker.pid"
MODEL_REGISTRATION_FILE="$NETWORK_VOLUME/.model_destination_registry.json"
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

# Function to compress model file to .tar.zst format
compress_model_file() {
    local source_file="$1"
    local temp_dir="$2"

    if [ -z "$source_file" ] || [ -z "$temp_dir" ]; then
        log_download "ERROR" "Missing parameters for compress_model_file"
        return 1
    fi

    if [ ! -f "$source_file" ]; then
        log_download "ERROR" "Source file does not exist: $source_file"
        return 1
    fi

    # Check if zstd is available
    if ! command -v zstd >/dev/null 2>&1; then
        log_download "ERROR" "zstd command not found. Cannot compress model."
        return 1
    fi

    local file_name=$(basename "$source_file")
    local compressed_file="$temp_dir/${file_name}.tar.zst"

    log_download "INFO" "Compressing model file: $file_name"

    # Create a tar archive and compress it with zstd in one step
    # Use moderate compression level (6) for good ratio without excessive CPU usage
    # Limit CPU threads to prevent system freeze
    # Redirect zstd progress output to stderr to avoid mixing with function return value
    local cpu_limit=$(($(nproc) / 2))  # Use half available CPUs
    [ "$cpu_limit" -lt 1 ] && cpu_limit=1
    [ "$cpu_limit" -gt 4 ] && cpu_limit=4  # Cap at 4 threads max
    
    if timeout 300 tar -cf - -C "$(dirname "$source_file")" "$(basename "$source_file")" | timeout 300 zstd -6 -T"$cpu_limit" -o "$compressed_file" 2>&2; then
        log_download "INFO" "Successfully compressed $file_name to $(basename "$compressed_file")"

        # Get compressed file size
        local compressed_size
        compressed_size=$(stat -f%z "$compressed_file" 2>/dev/null || stat -c%s "$compressed_file" 2>/dev/null || echo "0")

        # Get original file size
        local original_size
        original_size=$(stat -f%z "$source_file" 2>/dev/null || stat -c%s "$source_file" 2>/dev/null || echo "0")

        # Calculate compression ratio
        local compression_ratio=0
        if [ "$original_size" -gt 0 ]; then
            compression_ratio=$(echo "scale=2; $compressed_size * 100 / $original_size" | bc 2>/dev/null || echo "0")
        fi

        log_download "INFO" "Compression: $original_size bytes -> $compressed_size bytes (${compression_ratio}%)"

        # Return the compressed file path via standard output
        echo "$compressed_file"
        return 0
    else
        log_download "ERROR" "Failed to compress model file: $file_name"
        rm -f "$compressed_file"
        return 1
    fi
}

# Function to decompress model file from .tar.zst format
decompress_model_file() {
    local compressed_file="$1"
    local output_dir="$2"

    if [ -z "$compressed_file" ] || [ -z "$output_dir" ]; then
        log_download "ERROR" "Missing parameters for decompress_model_file"
        return 1
    fi

    if [ ! -f "$compressed_file" ]; then
        log_download "ERROR" "Compressed file does not exist: $compressed_file"
        return 1
    fi

    # Check if zstd is available
    if ! command -v zstd >/dev/null 2>&1; then
        log_download "ERROR" "zstd command not found. Cannot decompress model."
        return 1
    fi

    log_download "INFO" "Decompressing model file: $(basename "$compressed_file")"

    # Create output directory
    mkdir -p "$output_dir"

    # Decompress and extract in one step
    # Redirect zstd output to stderr to avoid mixing with function return value
    if zstd -d -c "$compressed_file" 2>&2 | tar -xf - -C "$output_dir" 2>&2; then
        # Find the extracted file (should be the only file in the output directory)
        local extracted_file
        extracted_file=$(find "$output_dir" -type f -maxdepth 1 | head -1)

        if [ -n "$extracted_file" ] && [ -f "$extracted_file" ]; then
            log_download "INFO" "Successfully decompressed to: $(basename "$extracted_file")"
            # Return the decompressed file path via standard output
            echo "$extracted_file"
            return 0
        else
            log_download "ERROR" "No file found after decompression"
            return 1
        fi
    else
        log_download "ERROR" "Failed to decompress model file: $(basename "$compressed_file")"
        return 1
    fi
}

# Function to send download progress notification over API
notify_download_progress() {
    local download_type="$1"   # Type of download (e.g., "model_download", "batch_download")
    local status="$2"          # PROGRESS | DONE | FAILED
    local percentage="$3"      # 0-100
    local model_name="$4"      # Optional: specific model name
    local details="$5"         # Optional: additional details
    
    if [ -z "$POD_ID" ] || [ -z "$POD_USER_NAME" ]; then
        log_download "DEBUG" "POD_ID or POD_USER_NAME not set for download progress notification"
        return 1
    fi
    
    # Skip API notifications if explicitly disabled
    if [ "${SKIP_API_NOTIFICATIONS:-false}" = "true" ]; then
        log_download "DEBUG" "API notifications disabled, skipping download progress notification"
        return 0
    fi
    
    local payload
    payload=$(jq -n \
        --arg userId "$POD_USER_NAME" \
        --arg download_type "$download_type" \
        --arg status "$status" \
        --argjson percentage "${percentage:-0}" \
        --arg modelName "${model_name:-}" \
        --arg details "${details:-}" \
        '{
            userId: $userId,
            download_type: $download_type,
            status: $status,
            percentage: $percentage
        } + (if $modelName != "" then {modelName: $modelName} else {} end)
          + (if $details != "" then {details: $details} else {} end)')
    
    # Use the API client function if available
    if command -v make_api_request >/dev/null 2>&1; then
        local response_file
        response_file=$(mktemp)
        
        local http_code
        http_code=$(make_api_request "POST" "/pods/$POD_ID/download-progress" "$payload" "$response_file" 2>/dev/null || echo "000")
        
        if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
            log_download "DEBUG" "Download progress notification sent successfully: $download_type $status $percentage%"
            rm -f "$response_file"
            return 0
        else
            log_download "WARN" "Failed to send download progress notification (HTTP $http_code)"
            rm -f "$response_file"
            return 1
        fi
    else
        log_download "WARN" "make_api_request function not available for download progress notification"
        return 1
    fi
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
    
    # Initialize registration file if it doesn't exist
    if [ ! -f "$MODEL_REGISTRATION_FILE" ]; then
        echo '{}' > "$MODEL_REGISTRATION_FILE"
    fi
    
    # Validate JSON files
    if ! jq empty "$DOWNLOAD_QUEUE_FILE" >/dev/null 2>&1; then
        echo '[]' > "$DOWNLOAD_QUEUE_FILE"
    fi
    
    if ! jq empty "$DOWNLOAD_PROGRESS_FILE" >/dev/null 2>&1; then
        echo '{}' > "$DOWNLOAD_PROGRESS_FILE"
    fi
    
    if ! jq empty "$MODEL_REGISTRATION_FILE" >/dev/null 2>&1; then
        echo '{}' > "$MODEL_REGISTRATION_FILE"
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

# Function to convert size with units to bytes
convert_to_bytes() {
    local value="$1"
    local unit="$2"
    
    # Remove any leading/trailing whitespace
    value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    unit=$(echo "$unit" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # Handle fractional values by using awk for floating point arithmetic
    case "$unit" in
        "B"|"bytes")
            echo "$value" | awk '{printf "%.0f", $1}'
            ;;
        "KB"|"KiB")
            echo "$value" | awk '{printf "%.0f", $1 * 1024}'
            ;;
        "MB"|"MiB")
            echo "$value" | awk '{printf "%.0f", $1 * 1024 * 1024}'
            ;;
        "GB"|"GiB")
            echo "$value" | awk '{printf "%.0f", $1 * 1024 * 1024 * 1024}'
            ;;
        "TB"|"TiB")
            echo "$value" | awk '{printf "%.0f", $1 * 1024 * 1024 * 1024 * 1024}'
            ;;
        *)
            # If unknown unit, assume bytes
            echo "$value" | awk '{printf "%.0f", $1}'
            ;;
    esac
}

# Function to add download to queue (prevents duplicates by destination)
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
    
    # Determine download destination to prevent concurrent downloads to same destination
    local download_destination="$local_path"  # Default fallback
    if command -v determine_download_destination >/dev/null 2>&1; then
        download_destination=$(determine_download_destination "$local_path" "$s3_path")
        if [ -z "$download_destination" ]; then
            download_destination="$local_path"  # Fallback to original logic
        fi
    fi
    
    initialize_download_system
    
    if ! acquire_download_lock "queue" 30; then
        log_download "ERROR" "Failed to acquire queue lock"
        return 1
    fi
    
    trap "release_download_lock 'queue'" EXIT INT TERM QUIT
    
    # Check if download already exists in queue by destination (prevent concurrent downloads to same file)
    local existing_count
    existing_count=$(jq --arg downloadDest "$download_destination" \
        '[.[] | select(.downloadDestination == $downloadDest)] | length' \
        "$DOWNLOAD_QUEUE_FILE" 2>/dev/null || echo "0")
    
    if [ "$existing_count" -gt 0 ]; then
        log_download "INFO" "Download already queued for destination: $download_destination"
        release_download_lock "queue"
        trap - EXIT INT TERM QUIT
        return 0
    fi
    
    # Also check if download is in progress for this destination
    local progress_count
    progress_count=$(jq --arg downloadDest "$download_destination" \
        '[.. | objects | select(.downloadDestination == $downloadDest and .status == "progress")] | length' \
        "$DOWNLOAD_PROGRESS_FILE" 2>/dev/null || echo "0")
    
    if [ "$progress_count" -gt 0 ]; then
        log_download "INFO" "Download already in progress for destination: $download_destination"
        release_download_lock "queue"
        trap - EXIT INT TERM QUIT
        return 0
    fi
    
    # Add to queue with S3 path and download destination
    local temp_file
    temp_file=$(mktemp)
    
    jq --arg group "$group" \
       --arg modelName "$model_name" \
       --arg s3Path "$s3_path" \
       --arg localPath "$local_path" \
       --arg downloadDestination "$download_destination" \
       --argjson totalSize "${total_size:-0}" \
       --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")" \
       '. + [{
           "group": $group,
           "modelName": $modelName,
           "s3Path": $s3Path,
           "localPath": $localPath,
           "downloadDestination": $downloadDestination,
           "totalSize": $totalSize,
           "queuedAt": $timestamp
       }]' "$DOWNLOAD_QUEUE_FILE" > "$temp_file"
    
    if [ $? -eq 0 ] && jq empty "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$DOWNLOAD_QUEUE_FILE"
        log_download "INFO" "Added to download queue: $group/$model_name (S3: $s3_path, Dest: $download_destination)"
        
        # Register this model for the download destination
        register_model_for_destination "$group" "$model_name" "$local_path" "$download_destination"
        
        # Update progress status to queued
        update_download_progress "$group" "$model_name" "$local_path" "${total_size:-0}" 0 "queued" "$download_destination"
        
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
    local progress_status="$6"
    local download_destination="$7"  # Optional: download destination if different from local_path
    
    # Log every call to update_download_progress to a dedicated progress log file
    local progress_log_file="$NETWORK_VOLUME/.download_progress_calls.log"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] PROGRESS_CALL: group='$group', model='$model_name', status='$progress_status', downloaded=${downloaded:-0}/${total_size:-0} bytes, path='$local_path', dest='${download_destination:-$local_path}'" >> "$progress_log_file"
    
    if [ -z "$group" ] || [ -z "$model_name" ] || [ -z "$progress_status" ]; then
        log_download "ERROR" "Missing required parameters for progress update"
        return 1
    fi
    
    # Use local_path as fallback for download_destination
    if [ -z "$download_destination" ]; then
        download_destination="$local_path"
    fi
    
    # Ensure progress file exists before proceeding
    if [ ! -f "$DOWNLOAD_PROGRESS_FILE" ]; then
        mkdir -p "$(dirname "$DOWNLOAD_PROGRESS_FILE")"
        echo '{}' > "$DOWNLOAD_PROGRESS_FILE"
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
       --arg downloadDestination "${download_destination:-}" \
       --argjson totalSize "${total_size:-0}" \
       --argjson downloaded "${downloaded:-0}" \
       --arg status "$progress_status" \
       --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")" \
       '
       .[$group] = (.[$group] // {}) |
       .[$group][$modelName] = {
           "totalSize": $totalSize,
           "localPath": $localPath,
           "downloadDestination": $downloadDestination,
           "downloaded": $downloaded,
           "status": $status,
           "lastUpdated": $timestamp
       }' "$DOWNLOAD_PROGRESS_FILE" > "$temp_file"
    
    if [ $? -eq 0 ] && jq empty "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$DOWNLOAD_PROGRESS_FILE"
        
        # Calculate overall download progress across all models and send notification
        # Debug: Log the current download progress file content
        log_download "DEBUG" "Current download progress file content: $(cat "$DOWNLOAD_PROGRESS_FILE" 2>/dev/null || echo 'FILE_NOT_READABLE')"
        
        local overall_progress_data
        overall_progress_data=$(jq -r '
            # Flatten the nested structure: group -> model -> progress_data
            [
                to_entries[]
                | .value as $group_data
                | $group_data
                | to_entries[]
                | .value
                | select(.totalSize != null and .downloaded != null and .totalSize > 0)
            ] as $all_models |
            if ($all_models | length) == 0 then
                { totalBytes: 0, downloadedBytes: 0, percentage: 0, activeDownloads: 0 }
            else
                {
                    totalBytes: ($all_models | map(.totalSize) | add),
                    downloadedBytes: ($all_models | map(.downloaded) | add),
                    activeDownloads: ($all_models | map(select(.status == "progress" or .status == "queued")) | length)
                } |
                .percentage = (if .totalBytes > 0 then ((.downloadedBytes * 100) / .totalBytes) else 0 end)
            end
        ' "$DOWNLOAD_PROGRESS_FILE" 2>/dev/null)
        
        # Debug: Log overall progress data calculation
        log_download "DEBUG" "Overall progress data calculation result: '$overall_progress_data'"
        
        if [ -n "$overall_progress_data" ]; then
            log_download "DEBUG" "Processing overall progress data for notifications"
            local overall_percentage active_downloads total_bytes downloaded_bytes
            overall_percentage=$(echo "$overall_progress_data" | jq -r '.percentage // 0')
            active_downloads=$(echo "$overall_progress_data" | jq -r '.activeDownloads // 0')
            total_bytes=$(echo "$overall_progress_data" | jq -r '.totalBytes // 0')
            downloaded_bytes=$(echo "$overall_progress_data" | jq -r '.downloadedBytes // 0')
            
            # Round percentage to nearest integer
            overall_percentage=$(printf "%.0f" "$overall_percentage")
            
            # Determine notification status based on progress status and active downloads
            local notification_status="PROGRESS"
            if [ "$active_downloads" -eq 0 ]; then
                if [ "$overall_percentage" -eq 100 ]; then
                    notification_status="DONE"
                elif [ "$progress_status" = "failed" ] || [ "$progress_status" = "cancelled" ]; then
                    notification_status="FAILED"
                fi
            fi
            
            # Create details object with current model info and overall progress data
            local details
            details=$(jq -n \
                --arg currentGroup "$group" \
                --arg currentModel "$model_name" \
                --arg currentStatus "$progress_status" \
                --argjson currentTotalSize "${total_size:-0}" \
                --argjson currentDownloaded "${downloaded:-0}" \
                --argjson overallData "$overall_progress_data" \
                '{
                    currentModel: {
                        group: $currentGroup,
                        modelName: $currentModel,
                        status: $currentStatus,
                        totalSize: $currentTotalSize,
                        downloaded: $currentDownloaded
                    },
                    overallProgress: $overallData
                }')
            
            # Send download progress notification with actual progress data as details
            # Note: Notification failure should not break the download progress update system
            if ! notify_download_progress "model_download" "$notification_status" "$overall_percentage" "$model_name" "$details"; then
                log_download "WARN" "Failed to send download progress notification for $group/$model_name (status: $notification_status, percentage: $overall_percentage%). Download progress update continues normally."
            else
                log_download "DEBUG" "Successfully sent download progress notification for $group/$model_name (status: $notification_status, percentage: $overall_percentage%)"
            fi
        else
            log_download "DEBUG" "Skipping notification: overall_progress_data is empty or null"
        fi
        
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

# Function to check if compressed version exists and get metadata
check_compressed_version() {
    local s3_path="$1"
    local compressed_metadata_output="$2"  # Variable name to store metadata
    
    # Create compressed S3 path by adding .tar.zst extension
    local compressed_s3_path="${s3_path}.tar.zst"
    
    log_download "DEBUG" "Checking for compressed version: $compressed_s3_path"
    
    # Check if compressed version exists and get its metadata
    if s3_object_exists "$compressed_s3_path"; then
        log_download "INFO" "Found compressed version: $compressed_s3_path"
        
        # Get metadata including uncompressed-size
        local metadata
        metadata=$(s3_get_object_metadata "$compressed_s3_path" 2>/dev/null || echo "{}")
        
        if [ -n "$metadata" ] && [ "$metadata" != "{}" ]; then
            eval "$compressed_metadata_output='$metadata'"
            echo "$compressed_s3_path"  # Return compressed path
            return 0
        else
            log_download "WARN" "Compressed version exists but metadata could not be retrieved"
        fi
    fi
    
    log_download "DEBUG" "No compressed version found, will use original: $s3_path"
    echo "$s3_path"  # Return original path
    return 1
}

# Function to download and decompress model if needed
download_and_decompress_model() {
    local s3_uri="$1"
    local final_output_path="$2"
    local group="$3"
    local model_name="$4"
    local is_compressed="$5"
    local uncompressed_size="$6"
    
    if [ -z "$s3_uri" ] || [ -z "$final_output_path" ] || [ -z "$group" ] || [ -z "$model_name" ]; then
        log_download "ERROR" "Missing parameters for download_and_decompress_model"
        return 1
    fi
    
    # Create temporary file for download
    local temp_download_path="${final_output_path}.download.tmp"
    local temp_decompress_dir
    
    # Download the file (compressed or uncompressed)
    log_download "INFO" "Downloading: $s3_uri"
    if ! s3_copy_from "$s3_uri" "$temp_download_path" "--no-progress"; then
        log_download "ERROR" "Failed to download: $s3_uri"
        rm -f "$temp_download_path"
        return 1
    fi
    
    # If it's compressed, decompress it
    if [ "$is_compressed" = "true" ]; then
        log_download "INFO" "Decompressing downloaded file: $(basename "$temp_download_path")"
        
        # Create temporary directory for decompression
        temp_decompress_dir=$(mktemp -d)
        trap "rm -rf '$temp_decompress_dir'" EXIT INT TERM QUIT
        
        local decompressed_file
        decompressed_file=$(decompress_model_file "$temp_download_path" "$temp_decompress_dir")
        
        if [ $? -eq 0 ] && [ -n "$decompressed_file" ]; then
            # Move decompressed file to final location
            if mv "$decompressed_file" "$final_output_path"; then
                log_download "INFO" "Successfully decompressed and moved to: $final_output_path"
                
                # Verify uncompressed size if provided
                if [ -n "$uncompressed_size" ] && [ "$uncompressed_size" -gt 0 ]; then
                    local actual_size
                    actual_size=$(stat -f%z "$final_output_path" 2>/dev/null || stat -c%s "$final_output_path" 2>/dev/null || echo "0")
                    
                    if [ "$actual_size" -ne "$uncompressed_size" ]; then
                        log_download "WARN" "Decompressed size ($actual_size) doesn't match expected size ($uncompressed_size)"
                    else
                        log_download "INFO" "Decompressed size verified: $actual_size bytes"
                    fi
                fi
                
                # Clean up
                rm -f "$temp_download_path"
                rm -rf "$temp_decompress_dir"
                return 0
            else
                log_download "ERROR" "Failed to move decompressed file to final location"
                rm -f "$temp_download_path"
                rm -rf "$temp_decompress_dir"
                return 1
            fi
        else
            log_download "ERROR" "Failed to decompress downloaded file"
            rm -f "$temp_download_path"
            rm -rf "$temp_decompress_dir"
            return 1
        fi
    else
        # Not compressed, just move to final location
        if mv "$temp_download_path" "$final_output_path"; then
            log_download "INFO" "Successfully moved uncompressed file to: $final_output_path"
            return 0
        else
            log_download "ERROR" "Failed to move file to final location"
            rm -f "$temp_download_path"
            return 1
        fi
    fi
}

# This is the simplest and most robust method, keeping the original function name.
download_model_with_progress() {
    local group="$1"
    local model_name="$2"
    local s3_path="$3"
    local local_path="$4"
    local provided_size="$5"

    if [ -z "$group" ] || [ -z "$model_name" ] || [ -z "$s3_path" ] || [ -z "$local_path" ]; then
        log_download "ERROR" "Missing required parameters for model download"
        return 1
    fi

    # Before starting, check if the download has been cancelled.
    if is_download_cancelled "$group" "$model_name"; then
        log_download "INFO" "Download cancelled before starting: $group/$model_name"
        update_download_progress "$group" "$model_name" "$local_path" "${provided_size:-0}" 0 "cancelled" "$local_path"
        return 1
    fi

    # Determine download destination and check if symlink is needed
    local symlink_info
    if command -v check_symlink_requirement >/dev/null 2>&1; then
        symlink_info=$(check_symlink_requirement "$local_path" "$s3_path")
    else
        log_download "WARN" "check_symlink_requirement function not available, using local_path as download destination"
        symlink_info="no_symlink|${local_path}"
    fi

    if [ -z "$symlink_info" ]; then
        log_download "ERROR" "Failed to determine download destination for: $local_path"
        update_download_progress "$group" "$model_name" "$local_path" "${provided_size:-0}" 0 "failed" "$local_path"
        return 1
    fi

    local needs_symlink download_destination target_symlink_path
    IFS='|' read -r needs_symlink download_destination target_symlink_path <<< "$symlink_info"

    log_download "INFO" "Download destination: $download_destination"
    if [ "$needs_symlink" = "symlink_needed" ]; then
        log_download "INFO" "Will create symlink: $target_symlink_path -> $download_destination"
    fi

    # Check if download destination already exists
    if [ -f "$download_destination" ]; then
        local existing_size
        existing_size=$(stat -f%z "$download_destination" 2>/dev/null || stat -c%s "$download_destination" 2>/dev/null || echo "0")
        
        log_download "INFO" "Model already exists at download destination: $download_destination ($existing_size bytes)"
        
        # If symlink is needed and doesn't exist, create it
        if [ "$needs_symlink" = "symlink_needed" ] && [ -n "$target_symlink_path" ]; then
            if [ ! -e "$target_symlink_path" ] && [ ! -L "$target_symlink_path" ]; then
                log_download "INFO" "Creating symlink for existing model: $target_symlink_path -> $download_destination"
                mkdir -p "$(dirname "$target_symlink_path")"
                if ln -sf "$download_destination" "$target_symlink_path" 2>/dev/null; then
                    log_download "INFO" "Symlink created successfully"
                else
                    log_download "WARN" "Failed to create symlink, but model file exists"
                fi
            else
                log_download "DEBUG" "Symlink already exists or target path is occupied"
            fi
        fi
        
        # Update progress to completed
        update_download_progress "$group" "$model_name" "$local_path" "$existing_size" "$existing_size" "completed" "$download_destination"
        return 0
    fi

    # Parse S3 path to get bucket and key
    local bucket key
    if [[ "$s3_path" =~ ^s3://([^/]+)/(.*)$ ]]; then
        bucket="${BASH_REMATCH[1]}"
        key="${BASH_REMATCH[2]}"
    elif [[ "$s3_path" =~ ^/(.*)$ ]]; then
        bucket="${AWS_BUCKET_NAME:-}"
        key="${BASH_REMATCH[1]}"
    else
        bucket="${AWS_BUCKET_NAME:-}"
        key="$s3_path"
    fi

    if [ -z "$bucket" ] || [ -z "$key" ]; then
        log_download "ERROR" "Could not parse S3 path: $s3_path"
        update_download_progress "$group" "$model_name" "$local_path" 0 0 "failed" "$download_destination"
        return 1
    fi

    # Check for compressed version first
    local download_s3_path="s3://${bucket}/${key}"
    local compressed_metadata=""
    local actual_download_path
    local is_compressed=false
    local uncompressed_size="$provided_size"
    
    actual_download_path=$(check_compressed_version "$download_s3_path" compressed_metadata)
    
    if [ "$actual_download_path" != "$download_s3_path" ]; then
        # Found compressed version
        is_compressed=true
        log_download "INFO" "Using compressed version for download: $(basename "$actual_download_path")"
        
        # Extract uncompressed size from metadata if available
        if [ -n "$compressed_metadata" ]; then
            local metadata_uncompressed_size
            metadata_uncompressed_size=$(echo "$compressed_metadata" | jq -r '.uncompressed-size // empty' 2>/dev/null)
            if [ -n "$metadata_uncompressed_size" ] && [ "$metadata_uncompressed_size" != "null" ]; then
                uncompressed_size="$metadata_uncompressed_size"
                log_download "INFO" "Using uncompressed size from metadata: $uncompressed_size bytes"
            fi
        fi
    else
        log_download "INFO" "Using uncompressed version for download: $(basename "$actual_download_path")"
    fi

    # Create the download destination directory if it doesn't exist
    mkdir -p "$(dirname "$download_destination")"

    # Get the actual file size for progress tracking (of the file we're downloading)
    local download_file_size
    download_file_size=$(s3_get_object_size "$actual_download_path" || echo "${provided_size:-0}")
    
    log_download "INFO" "Starting download via S3 for $group/$model_name to $download_destination"
    log_download "INFO" "Download size: $download_file_size bytes, Final size: ${uncompressed_size:-$download_file_size} bytes"

    # Update status to "in progress" using the final uncompressed size for progress reporting
    update_download_progress "$group" "$model_name" "$local_path" "${uncompressed_size:-$download_file_size}" 0 "progress" "$download_destination"
    
    # Download and decompress if needed to the download destination
    if download_and_decompress_model "$actual_download_path" "$download_destination" "$group" "$model_name" "$is_compressed" "$uncompressed_size"; then
        local final_size
        final_size=$(stat -f%z "$download_destination" 2>/dev/null || stat -c%s "$download_destination" 2>/dev/null || echo "${uncompressed_size:-$download_file_size}")
        
        log_download "INFO" "Download completed successfully: $group/$model_name ($final_size bytes) at $download_destination"
        
        # Create symlink if needed for this specific model
        if [ "$needs_symlink" = "symlink_needed" ] && [ -n "$target_symlink_path" ]; then
            log_download "INFO" "Creating symlink: $target_symlink_path -> $download_destination"
            mkdir -p "$(dirname "$target_symlink_path")"
            
            # Remove existing file/symlink if it exists
            if [ -e "$target_symlink_path" ] || [ -L "$target_symlink_path" ]; then
                log_download "DEBUG" "Removing existing file/symlink: $target_symlink_path"
                rm -f "$target_symlink_path"
            fi
            
            if ln -sf "$download_destination" "$target_symlink_path" 2>/dev/null; then
                log_download "INFO" "Symlink created successfully: $target_symlink_path -> $download_destination"
            else
                log_download "ERROR" "Failed to create symlink: $target_symlink_path -> $download_destination"
                # Don't fail the entire download just because symlink creation failed
            fi
        fi
        
        # Create symlinks for any other models that should point to this same destination
        complete_models_for_destination "$download_destination"
        return 0
    else
        log_download "ERROR" "Download/decompression failed for: $group/$model_name"
        update_download_progress "$group" "$model_name" "$local_path" "${uncompressed_size:-$download_file_size}" 0 "failed" "$download_destination"
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
    
    # Enhanced locking mechanism to prevent multiple workers
    local lock_file="${DOWNLOAD_PID_FILE}.lock"
    local start_lock_file="${DOWNLOAD_PID_FILE}.start.lock"
    local max_wait=10
    local wait_count=0
    local lock_acquired=false
    
    # First, acquire the start lock to prevent multiple start attempts
    while [ $wait_count -lt $max_wait ]; do
        if (
            set -C  # noclobber - fail if file exists
            echo "$$:$(date +%s)" > "$start_lock_file"
        ) 2>/dev/null; then
            lock_acquired=true
            break
        fi
        
        # Check if existing lock is stale (older than 30 seconds)
        if [ -f "$start_lock_file" ]; then
            local lock_info lock_pid lock_time current_time
            lock_info=$(cat "$start_lock_file" 2>/dev/null || echo "")
            if [ -n "$lock_info" ]; then
                lock_pid="${lock_info%%:*}"
                lock_time="${lock_info##*:}"
                current_time=$(date +%s)
                
                # If lock is stale or process doesn't exist, remove it
                if [ -n "$lock_time" ] && [ $((current_time - lock_time)) -gt 30 ]; then
                    log_download "WARN" "Removing stale start lock (age: $((current_time - lock_time))s)"
                    rm -f "$start_lock_file"
                elif [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
                    log_download "WARN" "Removing start lock for dead process $lock_pid"
                    rm -f "$start_lock_file"
                fi
            else
                # Empty or corrupted lock file
                rm -f "$start_lock_file"
            fi
        fi
        
        sleep 0.5
        wait_count=$((wait_count + 1))
    done
    
    if [ "$lock_acquired" != "true" ]; then
        log_download "WARN" "Could not acquire start lock after ${max_wait} attempts"
        return 0
    fi
    
    # Clean up start lock on exit
    trap "rm -f '$start_lock_file'" EXIT INT TERM QUIT
    
    # Now check if worker is already running (double-check with start lock held)
    if [ -f "$DOWNLOAD_PID_FILE" ]; then
        local pid
        pid=$(cat "$DOWNLOAD_PID_FILE" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log_download "DEBUG" "Download worker already running (PID: $pid)"
            rm -f "$start_lock_file"
            return 0
        else
            log_download "INFO" "Cleaning up stale worker PID file"
            rm -f "$DOWNLOAD_PID_FILE"
        fi
    fi
    
    # Acquire the main worker lock for the duration of the worker process
    local current_time
    current_time=$(date +%s)
    
    if ! (
        set -C  # noclobber - fail if file exists
        echo "$$:$current_time" > "$lock_file"
    ) 2>/dev/null; then
        log_download "DEBUG" "Could not acquire worker lock - another worker may have started"
        rm -f "$start_lock_file"
        return 0
    fi
    
    # Start worker in background - enhanced approach with robust PID and lock management
    (
        # Remove the start lock since we're now committed to starting the worker
        rm -f "$start_lock_file"
        
        # Write our PID and ensure cleanup of both PID file and worker lock
        echo $$ > "$DOWNLOAD_PID_FILE"
        trap "rm -f '$DOWNLOAD_PID_FILE' '$lock_file'" EXIT INT TERM QUIT
        
        log_download "INFO" "Download worker started (PID: $$)"
        
        # Track background download processes using simple arrays
        local download_pids=()
        local download_keys=()
        local empty_queue_checks=0
        local max_empty_checks=6  # Stop after 3 seconds of empty queue (6 * 0.5s)
        
        # Worker heartbeat for monitoring
        local last_heartbeat=$(date +%s)
        local heartbeat_interval=30  # Update heartbeat every 30 seconds
        
        while true; do
            local current_time=$(date +%s)
            
            # Update heartbeat in lock file periodically
            if [ $((current_time - last_heartbeat)) -ge $heartbeat_interval ]; then
                echo "$$:$current_time" > "$lock_file" 2>/dev/null || true
                last_heartbeat=$current_time
            fi
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
                local get_result=$?
                
                if [ "$get_result" -eq 0 ] && [ -f "$next_download_file" ]; then
                    local group model_name s3_path local_path total_size
                    group=$(jq -r ".group // empty" "$next_download_file")
                    model_name=$(jq -r ".modelName // empty" "$next_download_file")
                    s3_path=$(jq -r ".s3Path // empty" "$next_download_file")
                    local_path=$(jq -r ".localPath // empty" "$next_download_file")
                    download_destination=$(jq -r ".downloadDestination // empty" "$next_download_file")
                    total_size=$(jq -r ".totalSize // 0" "$next_download_file")
                    
                    rm -f "$next_download_file"
                    
                    # Check if this download was cancelled while in queue
                    if is_download_cancelled "$group" "$model_name"; then
                        log_download "INFO" "Skipping cancelled download from queue: $group/$model_name"
                        update_download_progress "$group" "$model_name" "$local_path" "$total_size" 0 "cancelled" "$download_destination"
                        # Continue to next iteration without incrementing empty_queue_checks
                        continue
                    fi
                    
                    if [ -n "$group" ] && [ -n "$model_name" ] && [ -n "$s3_path" ] && [ -n "$local_path" ]; then
                        log_download "INFO" "Starting download: $group/$model_name from $s3_path"
                        
                        # Start download in background
                        (
                            download_model_with_progress "$group" "$model_name" "$s3_path" "$local_path" "$total_size"
                        ) &
                        local download_pid=$!
                        download_pids+=("$download_pid")
                        download_keys+=("${group}/${model_name}")
                        log_download "INFO" "Started download ${group}/${model_name} (PID: $download_pid, Active: $((running_count + 1))/$MAX_CONCURRENT_DOWNLOADS)"
                        
                        # Reset empty queue counter when we start a new download
                        empty_queue_checks=0
                    else
                        log_download "ERROR" "Invalid download entry in queue"
                    fi
                else
                    # No downloads in queue
                    empty_queue_checks=$((empty_queue_checks + 1))
                    
                    # If queue has been empty for a while and no active downloads, stop worker
                    if [ "$empty_queue_checks" -ge "$max_empty_checks" ] && [ "$running_count" -eq 0 ]; then
                        log_download "INFO" "Queue empty and no active downloads, worker shutting down"
                        break
                    fi
                    
                    # Sleep briefly and check again
                    sleep 0.5
                fi
            else
                # At max capacity, wait a bit before checking again
                sleep 1
            fi
        done
        
        log_download "INFO" "Download worker finished"
    ) &
    
    # Give the worker a moment to start
    sleep 0.1
    
    log_download "INFO" "Download worker started in background"
    return 0
}

# Function to stop download worker
# Works independently regardless of execution scope and cleans up locks
stop_download_worker() {
    local force_stop="${1:-false}"
    
    # Clean up lock files first
    local lock_file="${DOWNLOAD_PID_FILE}.lock"
    local start_lock_file="${DOWNLOAD_PID_FILE}.start.lock"
    
    log_download "INFO" "Stopping download worker and cleaning up locks"
    
    # Multiple strategies to find and stop the download worker
    local stopped=false
    
    # Strategy 1: Use PID file if it exists
    if [ -f "$DOWNLOAD_PID_FILE" ]; then
        local pid
        pid=$(cat "$DOWNLOAD_PID_FILE" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            # Safety check: don't kill the current process or its parent
            local current_pid=$$
            local parent_pid=$(ps -p $$ -o ppid= 2>/dev/null | tr -d ' ' || echo "")
            
            if [ "$pid" != "$current_pid" ] && [ "$pid" != "$parent_pid" ]; then
                log_download "INFO" "Stopping download worker via PID file (PID: $pid)"
                kill -TERM "$pid" 2>/dev/null || true
                
                # Give it time to shutdown gracefully
                local wait_count=0
                while [ $wait_count -lt 5 ] && kill -0 "$pid" 2>/dev/null; do
                    sleep 1
                    wait_count=$((wait_count + 1))
                done
                
                # Force kill if still running and not in test environment
                if kill -0 "$pid" 2>/dev/null; then
                    if [ "${SKIP_FORCE_KILL:-false}" != "true" ]; then
                        log_download "WARN" "Force killing download worker (PID: $pid)"
                        kill -KILL "$pid" 2>/dev/null || true
                        sleep 1
                    else
                        log_download "INFO" "Skipping force kill in test environment"
                    fi
                fi
                
                stopped=true
            else
                log_download "WARN" "Skipping worker stop to avoid killing test process (PID: $pid)"
            fi
        fi
        rm -f "$DOWNLOAD_PID_FILE"
    fi
    
    # Strategy 2: Find download worker processes by pattern (be more specific)
    if [ "$stopped" = false ] || [ "$force_stop" = true ]; then
        local worker_pids
        # Look for specific worker function calls, not just "download"
        worker_pids=$(pgrep -f "run_download_worker_loop" 2>/dev/null || true)
        
        if [ -z "$worker_pids" ]; then
            # Look for AWS CLI processes that might be downloading (handle both real and mock aws)
            worker_pids=$(pgrep -f "s3.*cp" 2>/dev/null || true)
            if [ -z "$worker_pids" ]; then
                worker_pids=$(pgrep -f "aws.*s3.*cp" 2>/dev/null || true)
            fi
        fi
        
        if [ -n "$worker_pids" ]; then
            # Filter out the current test process and its parent to avoid killing the test
            local current_pid=$$
            local parent_pid=$(ps -p $$ -o ppid= 2>/dev/null | tr -d ' ' || echo "")
            local filtered_pids=""
            for pid in $worker_pids; do
                if [ "$pid" != "$current_pid" ] && [ "$pid" != "$parent_pid" ]; then
                    filtered_pids="$filtered_pids $pid"
                fi
            done
            
            if [ -n "$filtered_pids" ]; then
                log_download "INFO" "Stopping download processes found by pattern"
                echo "$filtered_pids" | xargs kill -TERM 2>/dev/null || true
                sleep 2
                # Force kill any remaining (only if not in test environment)
                if [ "${SKIP_FORCE_KILL:-false}" != "true" ]; then
                    echo "$filtered_pids" | xargs kill -KILL 2>/dev/null || true
                else
                    log_download "INFO" "Skipping force kill in test environment"
                fi
                stopped=true
            fi
        fi
    fi
    
    # Strategy 3: Create a global stop signal (skip in test environments)
    if [ "${SKIP_GLOBAL_STOP_SIGNAL:-false}" != "true" ]; then
        local stop_signal_file="$MODEL_DOWNLOAD_DIR/.stop_all_downloads"
        touch "$stop_signal_file"
        
        # Clean up stop signal after a delay
        (sleep 10; rm -f "$stop_signal_file") &
    fi
    
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
    
    # Clean up all lock files regardless of stop success
    rm -f "$lock_file" "$start_lock_file" 2>/dev/null || true
    log_download "DEBUG" "Cleaned up worker lock files"
    
    return 0
}

# Function to check if all downloads should be stopped (global stop signal)
should_stop_all_downloads() {
    local stop_signal_file="$MODEL_DOWNLOAD_DIR/.stop_all_downloads"
    [ -f "$stop_signal_file" ]
}

# Function to check worker status including lock information
get_worker_status() {
    local output_file="${1:-}"
    if [ -z "$output_file" ]; then
        output_file=$(mktemp)
    fi
    
    local lock_file="${DOWNLOAD_PID_FILE}.lock"
    local start_lock_file="${DOWNLOAD_PID_FILE}.start.lock"
    local status="stopped"
    local pid=""
    local lock_status="none"
    local lock_age=0
    
    # Check PID file
    if [ -f "$DOWNLOAD_PID_FILE" ]; then
        pid=$(cat "$DOWNLOAD_PID_FILE" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            status="running"
        else
            status="stale"
        fi
    fi
    
    # Check lock files
    if [ -f "$lock_file" ]; then
        local lock_info current_time lock_time
        lock_info=$(cat "$lock_file" 2>/dev/null || echo "")
        current_time=$(date +%s)
        
        if [[ "$lock_info" == *":"* ]]; then
            lock_time="${lock_info##*:}"
            lock_age=$((current_time - lock_time))
            lock_status="active"
        else
            lock_status="legacy"
        fi
    fi
    
    if [ -f "$start_lock_file" ]; then
        lock_status="starting"
    fi
    
    # Get queue status
    local queue_length=0
    if [ -f "$DOWNLOAD_QUEUE_FILE" ]; then
        queue_length=$(jq 'length' "$DOWNLOAD_QUEUE_FILE" 2>/dev/null || echo "0")
    fi
    
    # Write status to output file
    jq -n \
        --arg status "$status" \
        --arg pid "$pid" \
        --arg lockStatus "$lock_status" \
        --argjson lockAge "$lock_age" \
        --argjson queueLength "$queue_length" \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")" \
        '{
            status: $status,
            pid: $pid,
            lockStatus: $lockStatus,
            lockAge: $lockAge,
            queueLength: $queueLength,
            timestamp: $timestamp
        }' > "$output_file"
    
    echo "$output_file"
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
    
    local models_to_download=()
    local total_models=0
    
    case "$mode" in
        "all")
            # Load all local models from config
            local all_models_file
            if command -v get_downloadable_models >/dev/null 2>&1; then
                all_models_file=$(get_downloadable_models)
                
                if [ $? -eq 0 ] && [ -f "$all_models_file" ]; then
                    while IFS= read -r model; do
                        models_to_download+=("$model")
                    done < <(jq -c '.[]' "$all_models_file" 2>/dev/null)
                    rm -f "$all_models_file"
                fi
            else
                log_download "WARN" "get_downloadable_models function not available"
            fi
            ;;
            
        "missing")
            # Get downloadable models that don't exist locally 
            local downloadable_output
            downloadable_output=$(get_downloadable_models)
            
            if [ $? -eq 0 ] && [ -n "$downloadable_output" ]; then
                while IFS= read -r model; do
                    if [ -n "$model" ] && [ "$model" != "null" ]; then
                        models_to_download+=("$model")
                    fi
                done < <(echo "$downloadable_output" | jq -c '.[]' 2>/dev/null)
            else
                log_download "WARN" "Could not get downloadable models"
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
        
        # Check if model already exists at download destination
        local skip_model=false
        if [ "$mode" != "all" ]; then
            # Determine where the file would be downloaded to
            local download_destination="$local_path"  # Default fallback
            if command -v determine_download_destination >/dev/null 2>&1; then
                download_destination=$(determine_download_destination "$local_path" "$original_s3_path")
                if [ -z "$download_destination" ]; then
                    download_destination="$local_path"  # Fallback to original logic
                fi
            fi
            
            # Check if download destination exists
            if [ -f "$download_destination" ]; then
                log_download "INFO" "Skipping existing file at download destination: $download_destination"
                skip_model=true
            fi
            
            # Also check the local_path if it's different from download destination
            if [ "$local_path" != "$download_destination" ] && [ -f "$local_path" ]; then
                log_download "INFO" "Skipping - target file already exists: $local_path"
                skip_model=true
            fi
        fi
        
        if [ "$skip_model" = "true" ]; then
            continue
        fi
        
        if add_to_download_queue "$group" "$model_name" "$original_s3_path" "$local_path" "$model_size"; then
            queued_count=$((queued_count + 1))
        fi
    done
    
    log_download "INFO" "Queued $queued_count model(s) for download"

    # Return current progress file before starting worker (to avoid lock contention)
    cp "$DOWNLOAD_PROGRESS_FILE" "$output_file"

    # Start download worker if not running
    start_download_worker
    
    # Ensure output file exists and is readable
    if [ ! -f "$output_file" ]; then
        log_download "WARN" "Output file does not exist: $output_file"
        echo '{}' > "$output_file"
    fi
    
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

# Function to get download progress by local path only
get_download_progress_by_path() {
    local local_path="${1:-}"
    local output_file="${2:-}"
    
    if [ -z "$local_path" ]; then
        log_download "ERROR" "Local path must be provided"
        return 1
    fi
    
    # Support both modes: return file path or content
    if [ -z "$output_file" ]; then
        output_file=$(mktemp)
    fi
    
    initialize_download_system
    
    # Search by local path across all groups
    jq --arg localPath "$local_path" \
       '[.. | objects | select(.localPath == $localPath)][0] // {}' \
       "$DOWNLOAD_PROGRESS_FILE" > "$output_file" 2>/dev/null
    
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
    pids=$(pgrep -f "s3.*get-object.*${download_pattern}" 2>/dev/null || true)
    
    if [ -z "$pids" ]; then
        # Try alternative patterns for chunked downloads
        pids=$(pgrep -f "aws.*s3api.*get-object" 2>/dev/null || true)
        if [ -z "$pids" ]; then
            pids=$(pgrep -f "mock_aws.*s3api.*get-object" 2>/dev/null || true)
        fi
    fi
    
    if [ -n "$pids" ]; then
        echo "$pids" | while read -r pid; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                log_download "INFO" "Terminating download process $pid for $group/$model_name"
                kill -TERM "$pid" 2>/dev/null || true
                # Give it a moment, then force kill if necessary
                sleep 0.5
                if kill -0 "$pid" 2>/dev/null; then
                    kill -KILL "$pid" 2>/dev/null || true
                fi
            fi
        done
    fi
    
    # Look for chunk directory and clean it up
    local chunk_dir_file="$MODEL_DOWNLOAD_DIR/.chunk_dir_${group}_${model_name}"
    if [ -f "$chunk_dir_file" ]; then
        local chunk_dir
        chunk_dir=$(cat "$chunk_dir_file" 2>/dev/null || echo "")
        if [ -n "$chunk_dir" ] && [ -d "$chunk_dir" ]; then
            log_download "INFO" "Cleaning up chunk directory for $group/$model_name"
            rm -rf "$chunk_dir"
        fi
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
        return  1
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
    local current_local_path current_total_size current_downloaded current_download_destination
    
    # Get current progress if available
    if [ -f "$DOWNLOAD_PROGRESS_FILE" ]; then
        local progress_data
        progress_data=$(jq -r --arg group "$target_group" --arg model "$target_model_name" '
            .[$group][$model] // {}
        ' "$DOWNLOAD_PROGRESS_FILE" 2>/dev/null)
        
        if [ "$progress_data" != "{}" ] && [ "$progress_data" != "null" ]; then
            current_local_path=$(echo "$progress_data" | jq -r '.localPath // empty')
            current_download_destination=$(echo "$progress_data" | jq -r '.downloadDestination // empty')
            current_total_size=$(echo "$progress_data" | jq -r '.totalSize // 0')
            current_downloaded=$(echo "$progress_data" | jq -r '.downloaded // 0')
        fi
    fi
    
    # Use provided local_path if not found in progress
    if [ -z "$current_local_path" ] && [ -n "$local_path" ]; then
        current_local_path="$local_path"
    fi
    
    # Use local_path as fallback for download destination
    if [ -z "$current_download_destination" ]; then
        current_download_destination="$current_local_path"
    fi
    
    # Clean up any partial download files
    if [ -n "$current_local_path" ]; then
        rm -f "${current_local_path}.downloading"
        rm -f "${current_local_path}.download_progress"
    fi
    
    # Update progress to cancelled
    update_download_progress "$target_group" "$target_model_name" "$current_local_path" "${current_total_size:-0}" "${current_downloaded:-0}" "cancelled" "$current_download_destination"
    
    # Remove from registrations since it's cancelled
    remove_model_from_registrations "$target_group" "$target_model_name" "$current_local_path"
    
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
    
    # Update all in-progress and queued downloads to cancelled
    if [ -f "$DOWNLOAD_PROGRESS_FILE" ]; then
        local temp_file
        temp_file=$(mktemp)
        
        jq '
            to_entries | map(
                .value = (
                    .value | to_entries | map(
                        if (.value.status == "progress" or .value.status == "queued") then
                            .value.status = "cancelled"
                        else
                            .
                        end
                    ) | from_entries
                )
            ) | from_entries
        ' "$DOWNLOAD_PROGRESS_FILE" > "$temp_file" && mv "$temp_file" "$DOWNLOAD_PROGRESS_FILE"
    fi
    
    # Send cancellation notification via API
    local details
    details=$(jq -n \
        --arg reason "user_cancelled_all" \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")" \
        '{
            reason: $reason,
            timestamp: $timestamp,
            message: "All downloads cancelled by user request"
        }')
    
    # Note: Notification failure should not break the cancellation process
    if ! notify_download_progress "model_download" "FAILED" 0 "all_downloads" "$details"; then
        log_download "WARN" "Failed to send cancellation notification. Downloads were cancelled successfully."
    else
        log_download "DEBUG" "Successfully sent cancellation notification"
    fi
    
    log_download "INFO" "All downloads cancelled"
    return 0
}

# Model destination registration system
# This tracks which models should point to each download destination,
# allowing us to handle symlinks without scanning all configs

# Register a model for a specific download destination
register_model_for_destination() {
    local group="$1"
    local model_name="$2"
    local local_path="$3"
    local download_destination="$4"
    
    if [ -z "$group" ] || [ -z "$model_name" ] || [ -z "$local_path" ] || [ -z "$download_destination" ]; then
        log_download "ERROR" "Missing required parameters for model registration"
        return 1
    fi
    
    initialize_download_system
    
    if ! acquire_download_lock "registration" 30; then
        log_download "ERROR" "Failed to acquire registration lock"
        return 1
    fi
    
    trap "release_download_lock 'registration'" EXIT INT TERM QUIT
    
    local temp_file
    temp_file=$(mktemp)
    
    # Create or update the registration file
    # Structure: { "download_destination": [{ "group": "", "modelName": "", "localPath": "" }, ...] }
    jq --arg dest "$download_destination" \
       --arg group "$group" \
       --arg modelName "$model_name" \
       --arg localPath "$local_path" \
       '
       # Initialize the destination array if it does not exist
       .[$dest] = (.[$dest] // []) |
       # Check if this model is already registered for this destination
       if (.[$dest] | any(.group == $group and .modelName == $modelName and .localPath == $localPath)) then
           .
       else
           # Add the new model registration
           .[$dest] += [{
               "group": $group,
               "modelName": $modelName,
               "localPath": $localPath
           }]
       end
       ' "${MODEL_REGISTRATION_FILE:-/tmp/model_destination_registry.json}" 2>/dev/null > "$temp_file"
    
    if [ $? -eq 0 ] && jq empty "$temp_file" 2>/dev/null; then
        mv "$temp_file" "${MODEL_REGISTRATION_FILE:-/tmp/model_destination_registry.json}"
        log_download "DEBUG" "Registered model $group/$model_name for destination: $download_destination"
        release_download_lock "registration"
        trap - EXIT INT TERM QUIT
        return 0
    else
        rm -f "$temp_file"
        log_download "ERROR" "Failed to register model for destination"
        release_download_lock "registration"
        trap - EXIT INT TERM QUIT
        return 1
    fi
}

# Complete all models registered for a specific download destination
complete_models_for_destination() {
    local download_destination="$1"
    
    if [ -z "$download_destination" ]; then
        log_download "ERROR" "Missing download destination for completion"
        return 1
    fi
    
    if [ ! -f "${MODEL_REGISTRATION_FILE:-/tmp/model_destination_registry.json}" ]; then
        log_download "DEBUG" "No registration file found, nothing to complete"
        return 0
    fi
    
    if ! acquire_download_lock "registration" 30; then
        log_download "ERROR" "Failed to acquire registration lock for completion"
        return 1
    fi
    
    trap "release_download_lock 'registration'" EXIT INT TERM QUIT
    
    # Get all models registered for this destination
    local registered_models
    registered_models=$(jq -r --arg dest "$download_destination" \
        '.[$dest] // []' \
        "${MODEL_REGISTRATION_FILE:-/tmp/model_destination_registry.json}" 2>/dev/null)
    
    if [ -z "$registered_models" ] || [ "$registered_models" = "[]" ]; then
        log_download "DEBUG" "No models registered for destination: $download_destination"
        release_download_lock "registration"
        trap - EXIT INT TERM QUIT
        return 0
    fi
    
    log_download "INFO" "Completing models for destination: $download_destination"
    
    # Process each registered model
    echo "$registered_models" | jq -r '.[] | @base64' | while read -r encoded_model; do
        if [ -z "$encoded_model" ]; then
            continue
        fi
        
        local model_data
        model_data=$(echo "$encoded_model" | base64 -d 2>/dev/null)
        if [ -z "$model_data" ]; then
            continue
        fi
        
        local group model_name local_path
        group=$(echo "$model_data" | jq -r '.group // empty')
        model_name=$(echo "$model_data" | jq -r '.modelName // empty')
        local_path=$(echo "$model_data" | jq -r '.localPath // empty')
        
        if [ -z "$group" ] || [ -z "$model_name" ] || [ -z "$local_path" ]; then
            log_download "WARNING" "Invalid model data in registration: $model_data"
            continue
        fi
        
        log_download "DEBUG" "Processing registered model: $group/$model_name -> $local_path"
        
        # Check if symlink is needed (local_path != download_destination)
        if [ "$local_path" != "$download_destination" ]; then
            log_download "INFO" "Creating symlink for $group/$model_name: $local_path -> $download_destination"
            
            # Create directory if needed
            local target_dir
            target_dir=$(dirname "$local_path")
            if [ ! -d "$target_dir" ]; then
                mkdir -p "$target_dir" 2>/dev/null || {
                    log_download "WARNING" "Failed to create directory: $target_dir"
                    continue
                }
            fi
            
            # Remove existing file/symlink if it exists
            if [ -e "$local_path" ] || [ -L "$local_path" ]; then
                log_download "DEBUG" "Removing existing file/symlink: $local_path"
                rm -f "$local_path"
            fi
            
            # Create the symlink
            if ln -sf "$download_destination" "$local_path" 2>/dev/null; then
                log_download "INFO" "Symlink created successfully: $local_path -> $download_destination"
            else
                log_download "ERROR" "Failed to create symlink: $local_path -> $download_destination"
                continue
            fi
        fi
        
        # Get the final file size for progress update
        local final_size=0
        if [ -f "$download_destination" ]; then
            final_size=$(stat -f%z "$download_destination" 2>/dev/null || stat -c%s "$download_destination" 2>/dev/null || echo "0")
        fi
        
        # Update status to completed
        update_download_progress "$group" "$model_name" "$local_path" "$final_size" "$final_size" "completed" "$download_destination"
    done
    
    # Remove the registration for this destination
    local temp_file
    temp_file=$(mktemp)
    
    jq --arg dest "$download_destination" \
       'del(.[$dest])' \
       "${MODEL_REGISTRATION_FILE:-/tmp/model_destination_registry.json}" > "$temp_file"
    
    if [ $? -eq 0 ] && jq empty "$temp_file" 2>/dev/null; then
        mv "$temp_file" "${MODEL_REGISTRATION_FILE:-/tmp/model_destination_registry.json}"
        log_download "DEBUG" "Removed registration for destination: $download_destination"
    else
        rm -f "$temp_file"
        log_download "WARNING" "Failed to clean up registration for destination: $download_destination"
    fi
    
    release_download_lock "registration"
    trap - EXIT INT TERM QUIT
    return 0
}

# Remove a specific model from destination registrations
remove_model_from_registrations() {
    local group="$1"
    local model_name="$2"
    local local_path="$3"
    
    if [ -z "$group" ] || [ -z "$model_name" ] || [ -z "$local_path" ]; then
        log_download "DEBUG" "Missing parameters for registration removal, skipping"
        return 0
    fi
    
    if [ ! -f "$MODEL_REGISTRATION_FILE" ]; then
        log_download "DEBUG" "No registration file found, nothing to remove"
        return 0
    fi
    
    if ! acquire_download_lock "registration" 30; then
        log_download "WARNING" "Failed to acquire registration lock for removal"
        return 0
    fi
    
    trap "release_download_lock 'registration'" EXIT INT TERM QUIT
    
    local temp_file
    temp_file=$(mktemp)
    
    # Remove the model from all destinations it might be registered for
    jq --arg group "$group" \
       --arg modelName "$model_name" \
       --arg localPath "$local_path" \
       '
       to_entries |
       map({
           key: .key,
           value: [.value[] | select(.group != $group or .modelName != $modelName or .localPath != $localPath)]
       }) |
       map(select(.value | length > 0)) |
       from_entries
       ' "$MODEL_REGISTRATION_FILE" > "$temp_file"
    
    if [ $? -eq 0 ] && jq empty "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$MODEL_REGISTRATION_FILE"
        log_download "DEBUG" "Removed model $group/$model_name from registrations"
    else
        rm -f "$temp_file"
        log_download "WARNING" "Failed to remove model from registrations"
    fi
    
    release_download_lock "registration"
    trap - EXIT INT TERM QUIT
    return 0
}
EOF

chmod +x "$TARGET_DIR/model_download_integration.sh"

echo "✅ Model download integration script created at $TARGET_DIR/model_download_integration.sh"