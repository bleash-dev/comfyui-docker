#!/bin/bash
# Create integrated model sync script

echo "📝 Creating integrated model sync script..."

# Create the model sync integration script
cat > "$NETWORK_VOLUME/scripts/model_sync_integration.sh" << 'EOF'
#!/bin/bash
# Model Sync Integration Script
# Integrates API communication with model configuration management

# Source required scripts
source "$NETWORK_VOLUME/scripts/api_client.sh"
source "$NETWORK_VOLUME/scripts/model_config_manager.sh"

# Configuration
MODEL_SYNC_LOG="$NETWORK_VOLUME/.model_sync_integration.log"

# Ensure log file exists
mkdir -p "$(dirname "$MODEL_SYNC_LOG")"
touch "$MODEL_SYNC_LOG"

# Function to log model sync activities
log_model_sync() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] Model Sync: $message" | tee -a "$MODEL_SYNC_LOG"
}

# Function to upload file to S3 with progress tracking
upload_file_with_progress() {
    local local_file="$1"
    local s3_destination="$2"
    local sync_type="$3"
    local current_file_index="$4"
    local total_files="$5"
    
    if [ -z "$local_file" ] || [ -z "$s3_destination" ] || [ -z "$sync_type" ]; then
        log_model_sync "ERROR" "Missing required parameters for S3 upload"
        return 1
    fi
    
    if [ ! -f "$local_file" ]; then
        log_model_sync "ERROR" "File does not exist: $local_file"
        return 1
    fi
    
    local file_size
    file_size=$(stat -f%z "$local_file" 2>/dev/null || stat -c%s "$local_file" 2>/dev/null || echo "0")
    local file_name=$(basename "$local_file")
    
    log_model_sync "INFO" "Uploading $file_name to S3 (${file_size} bytes)"
    
    # Check if pv (pipe viewer) is available for better progress tracking
    if command -v pv >/dev/null 2>&1 && [ "$file_size" -gt 10485760 ]; then
        # Use pv for files larger than 10MB
        log_model_sync "INFO" "Using pv for progress tracking: $file_name"
        
        if pv "$local_file" | aws s3 cp - "$s3_destination" --only-show-errors; then
            log_model_sync "INFO" "Successfully uploaded with pv: $file_name"
            return 0
        else
            log_model_sync "ERROR" "Failed to upload with pv: $file_name"
            return 1
        fi
    else
        # For smaller files or when pv is not available, use regular upload with progress simulation
        if [ "$file_size" -gt 104857600 ]; then
            log_model_sync "INFO" "Using multipart upload for large file: $file_name"
            
            # Use aws s3 cp with custom progress tracking
            local temp_progress_file
            temp_progress_file=$(mktemp)
            
            # Start upload in background
            aws s3 cp "$local_file" "$s3_destination" \
                --cli-read-timeout 0 \
                --cli-write-timeout 0 \
                --only-show-errors &
            
            local upload_pid=$!
            local start_time=$(date +%s)
            
            # Monitor upload progress by checking file presence on S3
            while kill -0 "$upload_pid" 2>/dev/null; do
                local current_time=$(date +%s)
                local elapsed=$((current_time - start_time))
                
                # Simple progress estimation based on elapsed time
                if [ "$elapsed" -gt 0 ]; then
                    # Estimate progress (this is rough, but better than nothing)
                    local estimated_progress=$((elapsed * 100 / (file_size / 1048576 + 10)))
                    if [ "$estimated_progress" -gt 95 ]; then
                        estimated_progress=95
                    fi
                    
                    log_model_sync "INFO" "Upload progress estimate: ${estimated_progress}% for $file_name"
                fi
                
                sleep 3
            done
            
            wait "$upload_pid"
            local upload_result=$?
            rm -f "$temp_progress_file"
            
            if [ "$upload_result" -eq 0 ]; then
                log_model_sync "INFO" "Successfully uploaded large file: $file_name"
                return 0
            else
                log_model_sync "ERROR" "Failed to upload large file: $file_name"
                return 1
            fi
        else
            # For smaller files, use regular upload
            if aws s3 cp "$local_file" "$s3_destination" --only-show-errors; then
                log_model_sync "INFO" "Successfully uploaded: $file_name"
                return 0
            else
                log_model_sync "ERROR" "Failed to upload: $file_name"
                return 1
            fi
        fi
    fi
}

# Function to sync directory to S3 with progress tracking
sync_directory_with_progress() {
    local local_dir="$1"
    local s3_destination="$2"
    local sync_type="$3"
    local base_progress="$4"  # Base progress percentage to start from
    local progress_range="$5" # How much progress this operation should cover
    
    if [ -z "$local_dir" ] || [ -z "$s3_destination" ] || [ -z "$sync_type" ]; then
        log_model_sync "ERROR" "Missing required parameters for directory sync"
        return 1
    fi
    
    if [ ! -d "$local_dir" ]; then
        log_model_sync "ERROR" "Directory does not exist: $local_dir"
        return 1
    fi
    
    log_model_sync "INFO" "Starting directory sync: $local_dir -> $s3_destination"
    
    # Count total files first
    local total_files
    total_files=$(find "$local_dir" -type f | wc -l)
    
    if [ "$total_files" -eq 0 ]; then
        log_model_sync "INFO" "No files to sync in directory: $local_dir"
        return 0
    fi
    
    log_model_sync "INFO" "Found $total_files files to sync"
    
    # Use aws s3 sync with --cli-write-timeout for better progress tracking
    local sync_output
    sync_output=$(mktemp)
    
    # Run aws s3 sync in background and track its progress
    aws s3 sync "$local_dir" "$s3_destination" \
        --only-show-errors \
        --cli-read-timeout 0 \
        --cli-write-timeout 0 > "$sync_output" 2>&1 &
    
    local sync_pid=$!
    local files_synced=0
    
    # Monitor the sync process
    while kill -0 "$sync_pid" 2>/dev/null; do
        # Check how many files have been processed by looking at S3
        local current_s3_count
        current_s3_count=$(aws s3 ls "$s3_destination" --recursive 2>/dev/null | wc -l || echo "0")
        
        if [ "$current_s3_count" -gt "$files_synced" ]; then
            files_synced="$current_s3_count"
            
            # Calculate progress within the allocated range
            local file_progress=$((files_synced * 100 / total_files))
            local overall_progress=$((base_progress + (file_progress * progress_range / 100)))
            
            notify_model_sync_progress "$sync_type" "PROGRESS" "$overall_progress"
            log_model_sync "INFO" "Sync progress: $files_synced/$total_files files ($overall_progress%)"
        fi
        
        sleep 2
    done
    
    # Wait for the sync process to complete
    wait "$sync_pid"
    local sync_result=$?
    
    # Clean up
    rm -f "$sync_output"
    
    if [ "$sync_result" -eq 0 ]; then
        log_model_sync "INFO" "Directory sync completed successfully: $local_dir"
        return 0
    else
        log_model_sync "ERROR" "Directory sync failed: $local_dir"
        return 1
    fi
}

# Function to process a single model for sync
process_model_for_sync() {
    local local_path="$1"
    local s3_destination="$2"
    local destination_group="$3"
    
    if [ -z "$local_path" ] || [ -z "$s3_destination" ] || [ -z "$destination_group" ]; then
        log_model_sync "ERROR" "Missing required parameters for model sync processing"
        return 1
    fi
    
    if [ ! -f "$local_path" ]; then
        log_model_sync "ERROR" "Model file does not exist: $local_path"
        return 1
    fi
    
    # Early validation: Check if download URL is available before proceeding
    local download_url
    download_url=$(get_model_download_url "$local_path" 2>/dev/null || echo "")
    
    if [ -z "$download_url" ] || [ "$download_url" = "unknown" ]; then
        log_model_sync "INFO" "Skipping model (no download URL in config): $(basename "$local_path")"
        return 1
    fi
    
    # Validate that the download URL is actually a valid URL format (HTTP/HTTPS/S3)
    if ! echo "$download_url" | grep -qE '^(https?|s3)://[^[:space:]]+$'; then
        log_model_sync "INFO" "Skipping model (invalid download URL format): $(basename "$local_path") (URL: $download_url)"
        return 1
    fi
    
    log_model_sync "INFO" "Processing model for sync: $local_path"
    
    # Get model size
    local model_size
    model_size=$(stat -f%z "$local_path" 2>/dev/null || stat -c%s "$local_path" 2>/dev/null || echo "0")
    
    # Check with API if we can sync this model
    log_model_sync "INFO" "Checking sync permission for model: $destination_group, $local_path"
    
    local response_file
    response_file=$(mktemp)
    
    local http_code
    http_code=$(check_model_sync_permission "$s3_destination" "$download_url" "$destination_group" "$model_size" "$response_file")
    
    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        log_model_sync "ERROR" "Failed to get sync permission (HTTP $http_code)"
        rm -f "$response_file"
        return 1
    fi
    
    # Parse API response
    if [ ! -f "$response_file" ] || [ ! -s "$response_file" ]; then
        log_model_sync "ERROR" "Empty or missing API response"
        rm -f "$response_file"
        return 1
    fi
    
    local api_response
    api_response=$(cat "$response_file")
    rm -f "$response_file"
    
    # Extract response data
    local can_sync action reason existing_model symlink_target
    can_sync=$(echo "$api_response" | jq -r '.data.canSync // false')
    action=$(echo "$api_response" | jq -r '.data.action // "reject"')
    reason=$(echo "$api_response" | jq -r '.data.reason // "No reason provided"')
    existing_model=$(echo "$api_response" | jq -r '.data.existingModel // null')
    symlink_target=$(echo "$api_response" | jq -r '.data.symLinkTarget // ""')
    
    log_model_sync "INFO" "API response - canSync: $can_sync, action: $action, reason: $reason"
    
    if [ "$can_sync" != "true" && "$action" == "reject" ]; then
        log_model_sync "WARN" "Model sync not allowed: $reason"
        
        # Only update local config if the rejection reason is that model already exists at this exact path
        if [ "$reason" = "Model already exists at this exact path" ]; then
            log_model_sync "INFO" "Model exists at exact path - updating local config with correct S3 path"
            
            # Update local config with the correct S3 path since model exists at this path
            local model_object
            model_object=$(jq -n \
                --arg originalS3Path "$s3_destination" \
                --arg localPath "$local_path" \
                --arg modelName "$(basename "$local_path")" \
                --argjson modelSize "$model_size" \
                --arg downloadLink "$download_url" \
                --arg directoryGroup "$destination_group" \
                '{
                    originalS3Path: $originalS3Path,
                    localPath: $localPath,
                    modelName: $modelName,
                    modelSize: $modelSize,
                    downloadLink: $downloadLink,
                    directoryGroup: $directoryGroup
                }')
            
            # Update model config with correct S3 path
            create_or_update_model "$destination_group" "$model_object"
            if [ $? -eq 0 ]; then
                log_model_sync "INFO" "Local config updated with correct S3 path: $local_path -> $s3_destination"
            else
                log_model_sync "ERROR" "Failed to update local config for existing model"
            fi
        else
            log_model_sync "INFO" "Not updating local config - rejection reason does not indicate existing model at path"
        fi
        
        # Still return 1 to indicate the sync operation was rejected
        return 1
    fi
    
    # Process based on action
    case "$action" in
        "symlink")
            log_model_sync "INFO" "Creating symlink for model to existing S3 path"
            
            if [ -z "$symlink_target" ] || [ "$symlink_target" = "null" ]; then
                # Extract from existing model if symlink_target is not provided
                if [ "$existing_model" != "null" ]; then
                    symlink_target=$(echo "$existing_model" | jq -r '.originalS3Path // ""')
                fi
            fi
            
            if [ -n "$symlink_target" ] && [ "$symlink_target" != "null" ]; then
                # Update model config to reflect symlink
                convert_to_symlink "$destination_group" "$local_path" "$symlink_target"
                if [ $? -eq 0 ]; then
                    log_model_sync "INFO" "Successfully converted model to symlink: $local_path -> $symlink_target"
                    return 0
                else
                    log_model_sync "ERROR" "Failed to update model config for symlink"
                    return 1
                fi
            else
                log_model_sync "ERROR" "No symlink target provided for symlink action"
                return 1
            fi
            ;;
            
        "upload"|"replace")
            log_model_sync "INFO" "Proceeding with model $action to $s3_destination"
            
            # Create/update model object for upload
            local model_object
            model_object=$(jq -n \
                --arg originalS3Path "$s3_destination" \
                --arg localPath "$local_path" \
                --arg modelName "$(basename "$local_path")" \
                --argjson modelSize "$model_size" \
                --arg downloadLink "$download_url" \
                --arg directoryGroup "$destination_group" \
                '{
                    originalS3Path: $originalS3Path,
                    localPath: $localPath,
                    modelName: $modelName,
                    modelSize: $modelSize,
                    downloadLink: $downloadLink,
                    directoryGroup: $directoryGroup
                }')
            
            # Update model config
            create_or_update_model "$destination_group" "$model_object"
            if [ $? -eq 0 ]; then
                log_model_sync "INFO" "Model config updated for $action: $local_path"
                # Return success - actual upload will be handled by calling script
                return 0
            else
                log_model_sync "ERROR" "Failed to update model config for $action"
                return 1
            fi
            ;;
            
        "reject")
            log_model_sync "WARN" "Model sync rejected by API: $reason"
            
            # Only update local config if the rejection reason is that model already exists at this exact path
            if [ "$reason" = "Model already exists at this exact path" ]; then
                log_model_sync "INFO" "Model exists at exact path - updating local config with correct S3 path"
                
                # Update local config with the correct S3 path since model exists at this path
                local model_object
                model_object=$(jq -n \
                    --arg originalS3Path "$s3_destination" \
                    --arg localPath "$local_path" \
                    --arg modelName "$(basename "$local_path")" \
                    --argjson modelSize "$model_size" \
                    --arg downloadLink "$download_url" \
                    --arg directoryGroup "$destination_group" \
                    '{
                        originalS3Path: $originalS3Path,
                        localPath: $localPath,
                        modelName: $modelName,
                        modelSize: $modelSize,
                        downloadLink: $downloadLink,
                        directoryGroup: $directoryGroup
                    }')
                
                # Update model config with correct S3 path
                create_or_update_model "$destination_group" "$model_object"
                if [ $? -eq 0 ]; then
                    log_model_sync "INFO" "Local config updated with correct S3 path: $local_path -> $s3_destination"
                else
                    log_model_sync "ERROR" "Failed to update local config for existing model"
                fi
            else
                log_model_sync "INFO" "Not updating local config - rejection reason does not indicate existing model at path"
            fi
            
            # Still return 1 to indicate the sync operation was rejected
            return 1
            ;;
            
        *)
            log_model_sync "ERROR" "Unknown action received from API: $action"
            return 1
            ;;
    esac
}

# Function to sync progress notification wrapper
notify_model_sync_progress() {
    local sync_type="$1"
    local status="$2"
    local percentage="$3"
    
    # Add model-specific prefix to sync type
    local full_sync_type="model_${sync_type}"
    
    notify_sync_progress "$full_sync_type" "$status" "$percentage"
    
    # Also log locally
    log_model_sync "INFO" "Progress notification sent: $full_sync_type $status $percentage%"
}

# Function to check if a file should be processed for sync
should_process_file() {
    local file_path="$1"
    local file_name=$(basename "$file_path")
    
    # Skip hidden files and system files
    if [[ "$file_name" =~ ^\. ]]; then
        log_model_sync "INFO" "Skipping hidden file: $file_name"
        return 1
    fi
    
    # Skip common non-model files
    case "$file_name" in
        *.log|*.tmp|*.temp)
            log_model_sync "INFO" "Skipping non-model file: $file_name"
            return 1
            ;;
        *_info|*_metadata|*.info|*.metadata)
            log_model_sync "INFO" "Skipping metadata file: $file_name"
            return 1
            ;;
    esac
    
    # Check if file has a valid download URL in config
    local download_url
    download_url=$(get_model_download_url "$file_path" 2>/dev/null || echo "")
    
    if [ -z "$download_url" ] || [ "$download_url" = "unknown" ]; then
        log_model_sync "INFO" "Skipping file without valid download URL in config: $file_name"
        return 1
    fi
    
    # Validate that the download URL is actually a valid URL (HTTP/HTTPS/S3)
    if ! echo "$download_url" | grep -qE '^(https?|s3)://[^[:space:]]+$'; then
        log_model_sync "INFO" "Skipping file with invalid download URL format: $file_name (URL: $download_url)"
        return 1
    fi
    
    log_model_sync "DEBUG" "File passed validation for processing: $file_name"
    return 0
}

# Function to batch process models in a directory
batch_process_models() {
    local models_dir="$1"
    local s3_base_path="$2"
    local sync_type="$3"
    
    if [ -z "$models_dir" ] || [ -z "$s3_base_path" ] || [ -z "$sync_type" ]; then
        log_model_sync "ERROR" "Missing required parameters for batch model processing"
        return 1
    fi
    
    if [ ! -d "$models_dir" ]; then
        log_model_sync "ERROR" "Models directory does not exist: $models_dir"
        return 1
    fi
    
    log_model_sync "INFO" "Starting batch processing of models in: $models_dir"
    
    # Send initial progress
    notify_model_sync_progress "$sync_type" "PROGRESS" 0
    
    # Find all model files (any file type in models directory)
    local model_files=()
    while IFS= read -r -d '' file; do
        model_files+=("$file")
    done < <(find "$models_dir" -type f -print0 2>/dev/null)
    
    local total_models=${#model_files[@]}
    local processed_models=0
    local successful_models=0
    
    if [ $total_models -eq 0 ]; then
        log_model_sync "INFO" "No model files found in $models_dir"
        notify_model_sync_progress "$sync_type" "DONE" 100
        return 0
    fi
    
    log_model_sync "INFO" "Found $total_models model files to process"
    
    # Process each model
    for model_file in "${model_files[@]}"; do
        local relative_path
        relative_path=$(realpath --relative-to="$models_dir" "$model_file" 2>/dev/null || echo "${model_file#$models_dir/}")
        
        local destination_group
        destination_group=$(dirname "$relative_path")
        if [ "$destination_group" = "." ]; then
            destination_group="misc"
        fi
        
        local s3_destination="$s3_base_path/$relative_path"
        
        log_model_sync "INFO" "Processing model ($((processed_models + 1))/$total_models): $relative_path"
        
        # Check if this file should be processed (skip non-model files and files without proper config)
        if should_process_file "$model_file"; then
            if process_model_for_sync "$model_file" "$s3_destination" "$destination_group"; then
                successful_models=$((successful_models + 1))
                log_model_sync "INFO" "Successfully processed model: $relative_path"
                
                # For upload/replace actions, perform the actual S3 upload with progress
                if [ -f "$model_file" ]; then
                    # Check if this model should be uploaded (not symlinked)
                    local model_config_entry
                    model_config_entry=$(find_model_by_path "$destination_group" "$model_file")
                    
                    if [ -n "$model_config_entry" ]; then
                        local is_symlink
                        is_symlink=$(echo "$model_config_entry" | jq -r '.symLinkedFrom // false')
                        
                        if [ "$is_symlink" != "true" ]; then
                            log_model_sync "INFO" "Uploading model file: $relative_path"
                            
                            # Calculate progress range for this file
                            local base_progress=$((processed_models * 80 / total_models))
                            local progress_range=$((80 / total_models))
                            
                            if upload_file_with_progress "$model_file" "$s3_destination" "$sync_type" "$processed_models" "$total_models"; then
                                log_model_sync "INFO" "Successfully uploaded model: $relative_path"
                            else
                                log_model_sync "ERROR" "Failed to upload model: $relative_path"
                                successful_models=$((successful_models - 1))
                            fi
                        else
                            log_model_sync "INFO" "Model is symlinked, skipping upload: $relative_path"
                        fi
                    fi
                fi
            else
                log_model_sync "ERROR" "Failed to process model: $relative_path"
            fi
        else
            log_model_sync "INFO" "Skipped file (not eligible for sync): $relative_path"
        fi
        
        processed_models=$((processed_models + 1))
        
        # Send progress update
        local percentage=$((processed_models * 100 / total_models))
        notify_model_sync_progress "$sync_type" "PROGRESS" "$percentage"
    done
    
    # Send final status
    if [ $successful_models -eq $total_models ]; then
        notify_model_sync_progress "$sync_type" "DONE" 100
        log_model_sync "INFO" "Batch processing completed successfully: $successful_models/$total_models models processed"
        return 0
    else
        notify_model_sync_progress "$sync_type" "FAILED" 100
        log_model_sync "ERROR" "Batch processing completed with errors: $successful_models/$total_models models processed successfully"
        return 1
    fi
}

# Allow script to be sourced or called directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Called directly, show usage
    echo "🔗 Model Sync Integration"
    echo "========================"
    echo ""
    echo "This script integrates API communication with model configuration management."
    echo "Source this script to use the integration functions:"
    echo ""
    echo "Functions available:"
    echo "  process_model_for_sync <local_path> <s3_destination> <destination_group>"
    echo "  notify_model_sync_progress <sync_type> <status> <percentage>"
    echo "  batch_process_models <models_dir> <s3_base_path> <sync_type>"
    echo ""
    echo "Example usage:"
    echo "  source \"\$NETWORK_VOLUME/scripts/model_sync_integration.sh\""
    echo "  process_model_for_sync \"/path/to/model.safetensors\" \"s3://bucket/models/model.safetensors\" \"checkpoints\""
    echo "  batch_process_models \"\$NETWORK_VOLUME/ComfyUI/models\" \"s3://bucket/models\" \"global_shared\""
    echo ""
    echo "Required environment variables:"
    echo "  API_BASE_URL: ${API_BASE_URL:-'Not set'}"
    echo "  POD_ID: ${POD_ID:-'Not set'}"
    echo "  POD_USER_NAME: ${POD_USER_NAME:-'Not set'}"
    echo "  WEBHOOK_SECRET_KEY: ${WEBHOOK_SECRET_KEY:+'Set (hidden)' || 'Not set'}"
    echo ""
    echo "Log files:"
    echo "  Model Sync: $MODEL_SYNC_LOG"
    echo "  API Client: $API_CLIENT_LOG"
    echo "  Model Config: $MODEL_CONFIG_LOG"
fi
EOF

chmod +x "$NETWORK_VOLUME/scripts/model_sync_integration.sh"

echo "✅ Model sync integration script created at $NETWORK_VOLUME/scripts/model_sync_integration.sh"
