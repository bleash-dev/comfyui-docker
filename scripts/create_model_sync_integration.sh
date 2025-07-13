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
    local download_url="$6"  # Required download URL for metadata
    
    if [ -z "$local_file" ] || [ -z "$s3_destination" ] || [ -z "$sync_type" ] || [ -z "$download_url" ]; then
        log_model_sync "ERROR" "Missing required parameters for S3 upload (including download URL)"
        return 1
    fi
    
    # Validate download URL format
    if [ "$download_url" = "null" ] || [ "$download_url" = "unknown" ]; then
        log_model_sync "ERROR" "Invalid download URL provided: $download_url"
        return 1
    fi
    
    if ! echo "$download_url" | grep -qE '^(https?|s3)://[^[:space:]]+$'; then
        log_model_sync "ERROR" "Download URL has invalid format: $download_url"
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
    
    # Prepare metadata with download URL (required)
    local metadata_args="--metadata downloadUrl=\"$download_url\""
    log_model_sync "INFO" "Including download URL in metadata: $download_url"
    
    # Check if pv (pipe viewer) is available for better progress tracking
    if command -v pv >/dev/null 2>&1 && [ "$file_size" -gt 10485760 ]; then
        # Use pv for files larger than 10MB
        log_model_sync "INFO" "Using pv for progress tracking: $file_name"
        
        if pv "$local_file" | aws s3 cp - "$s3_destination" $metadata_args --only-show-errors; then
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
                $metadata_args \
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
            if aws s3 cp "$local_file" "$s3_destination" $metadata_args --only-show-errors; then
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
    local temp_output
    temp_output=$(mktemp)

    local download_url=""
    if get_model_download_url "$local_path" "$temp_output"; then
        download_url=$(<"$temp_output")
    else
        download_url=""
    fi

    rm -f "$temp_output"
    
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
    local can_sync action reason existing_model
    can_sync=$(echo "$api_response" | jq -r '.data.canSync // false')
    action=$(echo "$api_response" | jq -r '.data.action // "reject"')
    reason=$(echo "$api_response" | jq -r '.data.reason // "No reason provided"')
    existing_model=$(echo "$api_response" | jq -r '.data.existingModel // null')
    
    log_model_sync "INFO" "API response - canSync: $can_sync, action: $action, reason: $reason"
    
    # Handle canSync: true cases (upload or replace)
    if [ "$can_sync" = "true" ]; then
        case "$action" in
            "upload")
                log_model_sync "INFO" "New model - proceeding with upload to $s3_destination"
                ;;
            "replace")
                log_model_sync "INFO" "Replacing existing model - proceeding with upload to $s3_destination"
                ;;
            *)
                log_model_sync "ERROR" "Unknown action for canSync=true: $action"
                return 1
                ;;
        esac
        
        # Create/update model object for upload/replace
        local model_object
        model_object=$(jq -n \
            --arg originalS3Path "$s3_destination" \
            --arg localPath "$local_path" \
            --arg modelName "$(basename "$local_path")" \
            --argjson modelSize "$model_size" \
            --arg downloadUrl "$download_url" \
            --arg directoryGroup "$destination_group" \
            '{
                originalS3Path: $originalS3Path,
                localPath: $localPath,
                modelName: $modelName,
                modelSize: $modelSize,
                downloadUrl: $downloadUrl,
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
    fi
    
    # Handle canSync: false cases
    if [ "$can_sync" = "false" ]; then
        log_model_sync "WARN" "Model sync not allowed: $reason"
        
        # Check for partial upload or invalid file - remove from config
        if [[ "$reason" =~ "Partial upload detected" ]] || [[ "$reason" =~ "Invalid file extension" ]]; then
            log_model_sync "INFO" "Removing invalid model from local config: $reason"
            
            # Find and remove the model from config
            local model_name=$(basename "$local_path")
            if remove_model_by_path "$local_path"; then
                log_model_sync "INFO" "Successfully removed invalid model from config: $model_name"
            else
                log_model_sync "WARN" "Model not found in config or removal failed: $model_name"
            fi
            return 1
        fi
        
        # Check if model exists at exact same path
        if [ "$reason" = "Model already exists at this exact path" ]; then
            log_model_sync "INFO" "Model exists at exact path - no upload needed, config already correct"
            return 1
        fi
        
        # Handle cases where existingModel is provided
        if [ "$existing_model" != "null" ] && [ -n "$existing_model" ]; then
            log_model_sync "INFO" "Existing model found - updating local config to reference existing model"
            
            # Extract existing model's S3 path
            local existing_s3_path
            existing_s3_path=$(echo "$existing_model" | jq -r '.originalS3Path // ""')
            
            if [ -n "$existing_s3_path" ] && [ "$existing_s3_path" != "null" ]; then
                # Update local config to reference the existing model's S3 path
                local model_object
                model_object=$(jq -n \
                    --arg originalS3Path "$existing_s3_path" \
                    --arg localPath "$local_path" \
                    --arg modelName "$(basename "$local_path")" \
                    --argjson modelSize "$model_size" \
                    --arg downloadUrl "$download_url" \
                    --arg directoryGroup "$destination_group" \
                    '{
                        originalS3Path: $originalS3Path,
                        localPath: $localPath,
                        modelName: $modelName,
                        modelSize: $modelSize,
                        downloadUrl: $downloadUrl,
                        directoryGroup: $directoryGroup
                    }')
                
                # Update model config with existing model's S3 path
                create_or_update_model "$destination_group" "$model_object"
                if [ $? -eq 0 ]; then
                    log_model_sync "INFO" "Local config updated to reference existing model: $local_path -> $existing_s3_path"
                else
                    log_model_sync "ERROR" "Failed to update local config for existing model"
                fi
            else
                log_model_sync "ERROR" "Existing model found but no valid S3 path provided"
            fi
        else
            log_model_sync "INFO" "No existing model provided - sync rejected without config update"
        fi
        
        # All canSync: false cases should return 1 to indicate sync was rejected
        return 1
    fi
    
    # Should not reach here, but handle unexpected cases
    log_model_sync "ERROR" "Unexpected API response state: canSync=$can_sync, action=$action"
    return 1
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
    local temp_output
    temp_output=$(mktemp)

    local download_url=""
    if get_model_download_url "$local_path" "$temp_output"; then
        download_url=$(<"$temp_output")
    else
        download_url=""
    fi

    rm -f "$temp_output"
    
    if [ -z "$download_url" ] || [ "$download_url" = "unknown" ]; then
        log_model_sync "INFO" "Skipping file without valid download URL in config: $file_name $download_url"
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
    
    # Sanitize model config before processing
    log_model_sync "INFO" "Sanitizing model config before sync..."
    if ! sanitize_model_config; then
        log_model_sync "ERROR" "Failed to sanitize model config"
        notify_model_sync_progress "$sync_type" "FAILED" 0
        return 1
    fi
    
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
                    # Get the download URL for metadata (required)
                    local temp_output
                    temp_output=$(mktemp)

                    local download_url=""
                    if get_model_download_url "$local_path" "$temp_output"; then
                        download_url=$(<"$temp_output")
                    else
                        download_url=""
                    fi

                    rm -f "$temp_output"
                    
                    # Validate download URL before upload
                    if [ -z "$download_url" ] || [ "$download_url" = "unknown" ] || [ "$download_url" = "null" ]; then
                        log_model_sync "ERROR" "Cannot upload model without valid download URL: $relative_path"
                        successful_models=$((successful_models - 1))
                    elif ! echo "$download_url" | grep -qE '^(https?|s3)://[^[:space:]]+$'; then
                        log_model_sync "ERROR" "Cannot upload model with invalid download URL format: $relative_path (URL: $download_url)"
                        successful_models=$((successful_models - 1))
                    else
                        log_model_sync "INFO" "Uploading model file: $relative_path"
                        
                        # Calculate progress range for this file
                        local base_progress=$((processed_models * 80 / total_models))
                        local progress_range=$((80 / total_models))
                        
                        if upload_file_with_progress "$model_file" "$s3_destination" "$sync_type" "$processed_models" "$total_models" "$download_url"; then
                            log_model_sync "INFO" "Successfully uploaded model: $relative_path"
                        else
                            log_model_sync "ERROR" "Failed to upload model: $relative_path"
                            successful_models=$((successful_models - 1))
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

# Function to sanitize model config before sync
sanitize_model_config() {
    log_model_sync "INFO" "Starting model config sanitization..."
    
    # Initialize config if needed
    initialize_model_config
    
    # Get all models from config
    local all_models_file
    all_models_file=$(mktemp)
    
    # Extract all models with their metadata
    jq '
    [
        to_entries[] |
        select(.value | type == "object") |
        {group: .key, models: .value} |
        .models | to_entries[] |
        .value + {"directoryGroup": .group, "configKey": .key}
    ]
    ' "$MODEL_CONFIG_FILE" > "$all_models_file" 2>/dev/null
    
    if [ ! -s "$all_models_file" ]; then
        log_model_sync "INFO" "No models found in config to sanitize"
        rm -f "$all_models_file"
        return 0
    fi
    
    local total_models
    total_models=$(jq 'length' "$all_models_file" 2>/dev/null || echo "0")
    log_model_sync "INFO" "Found $total_models models in config to sanitize"
    
    # Group models by name and download URL
    local duplicates_file
    duplicates_file=$(mktemp)
    
    jq '
    group_by(.modelName + "|" + (.downloadUrl // "")) |
    map(select(length > 1)) |
    map({
        key: (.[0].modelName + "|" + (.[0].downloadUrl // "")),
        models: .
    })
    ' "$all_models_file" > "$duplicates_file" 2>/dev/null
    
    local duplicate_groups
    duplicate_groups=$(jq 'length' "$duplicates_file" 2>/dev/null || echo "0")
    
    if [ "$duplicate_groups" -eq 0 ]; then
        log_model_sync "INFO" "No duplicate models found, proceeding with file existence validation"
    else
        log_model_sync "INFO" "Found $duplicate_groups groups of duplicate models to consolidate"
    fi
    
    # Process each group of duplicates
    local models_to_remove=()
    local models_to_convert=()
    
    if [ "$duplicate_groups" -gt 0 ]; then
        local group_index=0
        while [ "$group_index" -lt "$duplicate_groups" ]; do
            local duplicate_group
            duplicate_group=$(jq -r ".[$group_index]" "$duplicates_file")
            
            local group_key
            group_key=$(echo "$duplicate_group" | jq -r '.key')
            
            log_model_sync "INFO" "Processing duplicate group: $group_key"
            
            # Find the model with the largest size and existing file
            local best_model=""
            local best_size=0
            local models_in_group
            models_in_group=$(echo "$duplicate_group" | jq -c '.models[]')
            
            while IFS= read -r model; do
                if [ -z "$model" ]; then
                    continue
                fi
                
                local local_path model_size
                local_path=$(echo "$model" | jq -r '.localPath // ""')
                model_size=$(echo "$model" | jq -r '.modelSize // 0')
                
                # Check if file exists locally
                if [ -f "$local_path" ]; then
                    # Get actual file size
                    local actual_size
                    actual_size=$(stat -f%z "$local_path" 2>/dev/null || stat -c%s "$local_path" 2>/dev/null || echo "0")
                    
                    # Use actual size if it's larger than recorded size
                    if [ "$actual_size" -gt "$model_size" ]; then
                        model_size="$actual_size"
                        # Update the model object with correct size
                        model=$(echo "$model" | jq --argjson size "$actual_size" '.modelSize = $size')
                    fi
                    
                    # Check if this is the best candidate
                    if [ "$model_size" -gt "$best_size" ] || [ -z "$best_model" ]; then
                        best_model="$model"
                        best_size="$model_size"
                    fi
                else
                    log_model_sync "WARN" "Model file does not exist locally: $local_path"
                fi
            done <<< "$models_in_group"
            
            if [ -n "$best_model" ]; then
                local best_path best_group
                best_path=$(echo "$best_model" | jq -r '.localPath')
                best_group=$(echo "$best_model" | jq -r '.directoryGroup')
                
                log_model_sync "INFO" "Selected primary model: $best_path (${best_size} bytes)"
                
                # Mark other models for conversion to symlinks or removal
                while IFS= read -r model; do
                    if [ -z "$model" ]; then
                        continue
                    fi
                    
                    local model_path model_group
                    model_path=$(echo "$model" | jq -r '.localPath')
                    model_group=$(echo "$model" | jq -r '.directoryGroup')
                    
                    if [ "$model_path" != "$best_path" ]; then
                        if [ -f "$model_path" ]; then
                            # Convert to symlink
                            models_to_convert+=("$model_group|$model_path|$best_path")
                            log_model_sync "INFO" "Will convert to symlink: $model_path -> $best_path"
                        else
                            # Remove from config
                            models_to_remove+=("$model_path")
                            log_model_sync "INFO" "Will remove non-existent model from config: $model_path"
                        fi
                    fi
                done <<< "$models_in_group"
            else
                # No valid files found, remove all from config
                while IFS= read -r model; do
                    if [ -z "$model" ]; then
                        continue
                    fi
                    
                    local model_path
                    model_path=$(echo "$model" | jq -r '.localPath')
                    models_to_remove+=("$model_path")
                    log_model_sync "INFO" "Will remove non-existent model from config: $model_path"
                done <<< "$models_in_group"
            fi
            
            group_index=$((group_index + 1))
        done
    fi
    
    # Check for models that exist in config but not on disk (non-duplicates)
    local all_models_count
    all_models_count=$(jq 'length' "$all_models_file")
    local model_index=0
    
    while [ "$model_index" -lt "$all_models_count" ]; do
        local model
        model=$(jq -r ".[$model_index]" "$all_models_file")
        
        local local_path is_symlink
        local_path=$(echo "$model" | jq -r '.localPath // ""')
        is_symlink=$(echo "$model" | jq -r '.symLinkedFrom // false')
        
        if [ -n "$local_path" ]; then
            if [ "$is_symlink" != "false" ] && [ "$is_symlink" != "null" ]; then
                # This is a symlink - verify target exists
                if [ ! -f "$local_path" ]; then
                    log_model_sync "WARN" "Symlink target does not exist: $local_path"
                    models_to_remove+=("$local_path")
                fi
            elif [ ! -f "$local_path" ]; then
                # Regular model file doesn't exist
                log_model_sync "WARN" "Model file does not exist: $local_path"
                models_to_remove+=("$local_path")
            fi
        fi
        
        model_index=$((model_index + 1))
    done
    
    # Clean up temp files
    rm -f "$all_models_file" "$duplicates_file"
    
    # Apply removals
    local removed_count=0
    for model_path in "${models_to_remove[@]}"; do
        if remove_model_by_path "$model_path"; then
            removed_count=$((removed_count + 1))
            log_model_sync "INFO" "Removed model from config: $model_path"
        fi
    done
    
    # Apply symlink conversions
    local converted_count=0
    for conversion in "${models_to_convert[@]}"; do
        IFS='|' read -r group path target <<< "$conversion"
        
        # Get the target model's S3 path from config
        local target_model_file
        target_model_file=$(find_model_by_path "" "$target")
        
        if [ $? -eq 0 ] && [ -f "$target_model_file" ]; then
            local target_s3_path
            target_s3_path=$(jq -r '.originalS3Path // ""' "$target_model_file" 2>/dev/null)
            rm -f "$target_model_file"
            
            if [ -n "$target_s3_path" ] && [ "$target_s3_path" != "null" ]; then
                # Reconstruct full S3 URL if the path is already stripped
                local full_s3_path="$target_s3_path"
                if [[ "$target_s3_path" != s3://* ]]; then
                    full_s3_path="s3://$AWS_BUCKET_NAME$target_s3_path"
                fi
                
                if convert_to_symlink "$group" "$path" "$full_s3_path"; then
                    converted_count=$((converted_count + 1))
                    log_model_sync "INFO" "Converted model to symlink: $path -> $target_s3_path"
                else
                    log_model_sync "ERROR" "Failed to convert model to symlink: $path"
                fi
            else
                log_model_sync "ERROR" "Could not find S3 path for target model: $target"
            fi
        else
            log_model_sync "ERROR" "Could not find target model in config: $target"
        fi
    done
    
    log_model_sync "INFO" "Model config sanitization completed: removed $removed_count models, converted $converted_count to symlinks"
    
    return 0
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
    echo "  sanitize_model_config"
    echo "  sanitize_model_config"
    echo ""
    echo "Example usage:"
    echo "  source \"\$NETWORK_VOLUME/scripts/model_sync_integration.sh\""
    echo "  process_model_for_sync \"/path/to/model.safetensors\" \"s3://bucket/models/model.safetensors\" \"checkpoints\""
    echo "  batch_process_models \"\$NETWORK_VOLUME/ComfyUI/models\" \"s3://bucket/models\" \"global_shared\""
    echo "  sanitize_model_config"
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
