#!/bin/bash
# Create model configuration management script

# Get the target directory from the first argument
TARGET_DIR="${1:-$NETWORK_VOLUME/scripts}"
mkdir -p "$TARGET_DIR"

echo "📝 Creating model configuration management script..."

# Create the model configuration manager
cat > "$TARGET_DIR/model_config_manager.sh" << 'EOF'
#!/bin/bash
# Model Configuration Manager for ComfyUI
# Manages models_config.json with thread-safe operations

# Configuration
MODEL_CONFIG_FILE="$NETWORK_VOLUME/ComfyUI/models_config.json"
MODEL_CONFIG_LOCK_DIR="$NETWORK_VOLUME/.model_config_locks"
MODEL_CONFIG_LOG="$NETWORK_VOLUME/.model_config_manager.log"
MODEL_CONFIG_LOCK_TIMEOUT=600  # 1 minute timeout for config operations

# Ensure directories and files exist
mkdir -p "$(dirname "$MODEL_CONFIG_FILE")"
mkdir -p "$MODEL_CONFIG_LOCK_DIR"
mkdir -p "$(dirname "$MODEL_CONFIG_LOG")"
touch "$MODEL_CONFIG_LOG"

# Function to log model config activities
log_model_config() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] Model Config: $message" | tee -a "$MODEL_CONFIG_LOG" >&2
}

# Function to extract model name from file path using backend convention
# Matches the extractModelName function from the backend:
# - Looks for 'models/' pattern
# - Removes the models prefix
# - Skips the first part (group) and returns everything after
# - Handles nested directories like: {group}/{subdir}/{modelName}
extract_model_name_from_path() {
    local file_path="$1"
    
    # Normalize path separators
    local normalized_path="${file_path//\\//}"
    
    # Look for '/models/' pattern
    local models_prefix="/models/"
    local models_index
    
    if [[ "$normalized_path" == *"$models_prefix"* ]]; then
        # Remove everything up to and including '/models/'
        local after_models="${normalized_path#*$models_prefix}"
        
        # Split by '/' and get path parts
        IFS='/' read -ra path_parts <<< "$after_models"
        
        if [ ${#path_parts[@]} -lt 2 ]; then
            # If no group or model name, return the whole relative path
            echo "$after_models"
            return
        fi
        
        # Skip the first part (group) and return everything after
        # Handles nested dirs like: {group}/{subdir}/{modelName}
        local result=""
        for ((i=1; i<${#path_parts[@]}; i++)); do
            if [ -n "$result" ]; then
                result="${result}/${path_parts[i]}"
            else
                result="${path_parts[i]}"
            fi
        done
        echo "$result"
    else
        # Fallback to basename for non-standard paths
        basename "$file_path"
    fi
}

# Function to acquire model config lock
acquire_model_config_lock() {
    local operation="$1"
    local caller_pid="$$"
    local lock_file="$MODEL_CONFIG_LOCK_DIR/config.lock"
    local waited=0
    local wait_interval=2
    
    log_model_config "DEBUG" "Attempting to acquire model config lock for operation: $operation"
    
    # Wait for lock to be available
    while [ -f "$lock_file" ]; do
        local lock_info
        lock_info=$(cat "$lock_file" 2>/dev/null || echo "")
        
        if [ -n "$lock_info" ]; then
            local lock_operation lock_pid lock_timestamp
            IFS='|' read -r lock_operation lock_pid lock_timestamp <<< "$lock_info"
            
            # Check if the process is still running
            if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
                local current_time
                current_time=$(date +%s)
                local lock_age=$((current_time - lock_timestamp))
                
                if [ "$lock_age" -gt "$MODEL_CONFIG_LOCK_TIMEOUT" ]; then
                    log_model_config "WARN" "Lock timeout exceeded (${lock_age}s), force releasing..."
                    rm -f "$lock_file"
                    break
                fi
                
                if [ "$waited" -ge "$MODEL_CONFIG_LOCK_TIMEOUT" ]; then
                    log_model_config "ERROR" "Timeout waiting for model config lock after ${waited}s"
                    return 1
                fi
                
                log_model_config "DEBUG" "Waiting for model config lock... (${waited}s/${MODEL_CONFIG_LOCK_TIMEOUT}s)"
                sleep "$wait_interval"
                waited=$((waited + wait_interval))
            else
                log_model_config "DEBUG" "Stale lock detected, removing..."
                rm -f "$lock_file"
                break
            fi
        else
            rm -f "$lock_file"
            break
        fi
    done
    
    # Acquire the lock
    local timestamp
    timestamp=$(date +%s)
    echo "$operation|$caller_pid|$timestamp" > "$lock_file"
    
    # Verify we got the lock
    if [ -f "$lock_file" ]; then
        local verification
        verification=$(cat "$lock_file" 2>/dev/null || echo "")
        if echo "$verification" | grep -q "^$operation|$caller_pid|$timestamp$"; then
            log_model_config "DEBUG" "Model config lock acquired for $operation (PID: $caller_pid)"
            return 0
        else
            log_model_config "ERROR" "Failed to verify model config lock acquisition"
            return 1
        fi
    else
        log_model_config "ERROR" "Failed to create model config lock file"
        return 1
    fi
}

# Function to release model config lock
release_model_config_lock() {
    local operation="$1"
    local caller_pid="$$"
    local lock_file="$MODEL_CONFIG_LOCK_DIR/config.lock"
    
    if [ ! -f "$lock_file" ]; then
        log_model_config "DEBUG" "No lock file to release for $operation"
        return 0
    fi
    
    local lock_info
    lock_info=$(cat "$lock_file" 2>/dev/null || echo "")
    
    if [ -n "$lock_info" ]; then
        local lock_operation lock_pid lock_timestamp
        IFS='|' read -r lock_operation lock_pid lock_timestamp <<< "$lock_info"
        
        # Verify this process owns the lock
        if [ "$lock_pid" = "$caller_pid" ] && [ "$lock_operation" = "$operation" ]; then
            rm -f "$lock_file"
            log_model_config "DEBUG" "Model config lock released for $operation (PID: $caller_pid)"
            return 0
        else
            log_model_config "WARN" "Lock not owned by this process (owner: $lock_operation|$lock_pid, caller: $operation|$caller_pid)"
            return 1
        fi
    else
        rm -f "$lock_file"
        return 0
    fi
}

# Function to initialize model config file if it doesn't exist
initialize_model_config() {
    if [ ! -f "$MODEL_CONFIG_FILE" ]; then
        log_model_config "INFO" "Initializing model config file at $MODEL_CONFIG_FILE"
        echo '{}' > "$MODEL_CONFIG_FILE"
    fi
    
    # Validate JSON structure - check if it's valid JSON
    local json_valid=true
    if ! jq empty "$MODEL_CONFIG_FILE" >/dev/null 2>&1; then
        json_valid=false
    fi
    
    # Also check if it's not empty but parses as null
    if [ "$json_valid" = "true" ]; then
        local parsed_content
        parsed_content=$(jq -r '.' "$MODEL_CONFIG_FILE" 2>/dev/null)
        if [ "$parsed_content" = "null" ] || [ -z "$parsed_content" ]; then
            json_valid=false
        fi
    fi
    
    if [ "$json_valid" = "false" ]; then
        log_model_config "WARN" "Invalid JSON in model config file, reinitializing..."
        echo '{}' > "$MODEL_CONFIG_FILE"
    fi
}

# Function to create or update a model item
create_or_update_model() {
    local group="$1"
    local model_object="$2"  # JSON string
    
    if [ -z "$group" ] || [ -z "$model_object" ]; then
        log_model_config "ERROR" "Group and model object are required for create/update operation"
        return 1
    fi
    
    # Validate model object JSON
    if ! echo "$model_object" | jq empty 2>/dev/null; then
        log_model_config "ERROR" "Invalid JSON provided for model object"
        return 1
    fi
    
    # Extract model name for identification
    local model_name
    model_name=$(echo "$model_object" | jq -r '.modelName // empty')
    if [ -z "$model_name" ]; then
        log_model_config "ERROR" "Model object must contain 'modelName' field"
        return 1
    fi
    
    log_model_config "INFO" "Creating/updating model in group '$group': $model_name"
    
    # Acquire lock
    if ! acquire_model_config_lock "update"; then
        log_model_config "ERROR" "Failed to acquire lock for model update"
        return 1
    fi
    
    # Set up trap to release lock on exit
    trap "release_model_config_lock 'update'" EXIT INT TERM QUIT
    
    # Initialize config if needed
    initialize_model_config
    
    # Add timestamps
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    model_object=$(echo "$model_object" | jq ". + {\"lastUpdated\": \"$timestamp\"}")
    
    # If uploadedAt doesn't exist, add it
    if ! echo "$model_object" | jq -e '.uploadedAt' >/dev/null 2>&1; then
        model_object=$(echo "$model_object" | jq ". + {\"uploadedAt\": \"$timestamp\"}")
    fi
    
    # Strip S3 bucket prefix from originalS3Path and symLinkedFrom before saving locally
    local s3_bucket_prefix="s3://$AWS_BUCKET_NAME/"
    model_object=$(echo "$model_object" | jq \
        --arg bucketPrefix "$s3_bucket_prefix" \
        '
        # Strip bucket prefix from originalS3Path if it exists
        if .originalS3Path and (.originalS3Path | startswith($bucketPrefix)) then
            .originalS3Path = (.originalS3Path | sub($bucketPrefix; ""))
        else
            .
        end |
        # Strip bucket prefix from symLinkedFrom if it exists
        if .symLinkedFrom and (.symLinkedFrom | startswith($bucketPrefix)) then
            .symLinkedFrom = (.symLinkedFrom | sub($bucketPrefix; ""))
        else
            .
        end
        ')
    
    # Update the config file
    local temp_file
    temp_file=$(mktemp)
    
    # Validate JSON before processing
    if ! echo "$model_object" | jq empty >/dev/null 2>&1; then
        log_model_config "ERROR" "Invalid JSON for model object in create_or_update_model: $model_object" >&2
        return 1
    fi
    
    # Create or update the group and model entry
    jq --arg group "$group" \
       --arg modelName "$(echo "$model_object" | jq -r '.modelName // empty')" \
       --argjson modelObj "$model_object" \
       '
       # Initialize group if it does not exist
       if has($group) | not then
           .[$group] = {}
       else
           .
       end |
       # Set the model in the group using modelName as key
       .[$group][$modelName] = $modelObj
       ' "$MODEL_CONFIG_FILE" > "$temp_file"
    
    if [ $? -eq 0 ] && jq empty "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$MODEL_CONFIG_FILE"
        log_model_config "INFO" "Successfully updated model config for $group/$model_name"
        
        # Release lock
        release_model_config_lock "update"
        trap - EXIT INT TERM QUIT
        return 0
    else
        log_model_config "ERROR" "Failed to update model config file"
        rm -f "$temp_file"
        
        # Release lock
        release_model_config_lock "update"
        trap - EXIT INT TERM QUIT
        return 1
    fi
}

# Function to delete a model from config
delete_model() {
    local group="$1"
    local model_name="$2"
    
    if [ -z "$group" ] || [ -z "$model_name" ]; then
        log_model_config "ERROR" "Group and model name are required for delete operation"
        return 1
    fi
    
    log_model_config "INFO" "Deleting model from group '$group': $model_name"
    
    # Acquire lock
    if ! acquire_model_config_lock "delete"; then
        log_model_config "ERROR" "Failed to acquire lock for model deletion"
        return 1
    fi
    
    # Set up trap to release lock on exit
    trap "release_model_config_lock 'delete'" EXIT INT TERM QUIT
    
    # Initialize config if needed
    initialize_model_config
    
    # Check if group exists
    if ! jq -e --arg group "$group" 'has($group)' "$MODEL_CONFIG_FILE" >/dev/null 2>&1; then
        log_model_config "INFO" "Group '$group' does not exist, nothing to delete"
        release_model_config_lock "delete"
        trap - EXIT INT TERM QUIT
        return 0
    fi
    
    # Update the config file
    local temp_file
    temp_file=$(mktemp)
    
    jq --arg group "$group" \
       --arg modelName "$model_name" \
       '
       if has($group) then
           del(.[$group][$modelName])
       else
           .
       end
       ' "$MODEL_CONFIG_FILE" > "$temp_file"
    
    if [ $? -eq 0 ] && jq empty "$temp_file" 2>/dev/null; then
        mv "$temp_file" "$MODEL_CONFIG_FILE"
        log_model_config "INFO" "Successfully deleted model from config: $group/$model_name"
        
        # Release lock
        release_model_config_lock "delete"
        trap - EXIT INT TERM QUIT
        return 0
    else
        log_model_config "ERROR" "Failed to update model config file during deletion"
        rm -f "$temp_file"
        
        # Release lock
        release_model_config_lock "delete"
        trap - EXIT INT TERM QUIT
        return 1
    fi
}

# Function to find model by local path
find_model_by_path() {
    local group="$1"
    local local_path="$2"
    local output_file="${3:-}"
    
    # Support both old and new calling conventions
    if [ -z "$output_file" ] && [ -z "$local_path" ]; then
        # Old convention: find_model_by_path <local_path> [output_file]
        local_path="$group"
        output_file="$2"
        group=""
    elif [ -z "$output_file" ] && [ -n "$local_path" ]; then
        # New convention: find_model_by_path <group> <local_path> [output_file]
        output_file=""
    fi
    
    if [ -z "$local_path" ]; then
        log_model_config "ERROR" "Local path is required for find operation"
        return 1
    fi
    
    # Default output file if not provided
    if [ -z "$output_file" ]; then
        output_file=$(mktemp)
    fi
    
    # Initialize config if needed
    initialize_model_config
    
    # Search for the model across all groups or in specific group
    if [ -n "$group" ]; then
        # Search in specific group
        jq --arg group "$group" \
           --arg localPath "$local_path" \
           '
           .[$group] // {} |
           to_entries[] |
           select(.value.localPath == $localPath) |
           .value + {"directoryGroup": $group}
           ' "$MODEL_CONFIG_FILE" > "$output_file" 2>/dev/null
    else
        # Search across all groups
        jq --arg localPath "$local_path" \
           '
           [to_entries[] | 
           select(.value | type == "object") |
           {key: .key, models: .value} |
           .models | to_entries[] |
           select(.value.localPath == $localPath) |
           .value + {"directoryGroup": .key}][0] // empty
           ' "$MODEL_CONFIG_FILE" > "$output_file" 2>/dev/null
    fi
    
    if [ -s "$output_file" ]; then
        log_model_config "DEBUG" "Found model with local path: $local_path"
        echo "$output_file"
        return 0
    else
        log_model_config "DEBUG" "No model found with local path: $local_path"
        rm -f "$output_file"
        return 1
    fi
}

# Function to list all models in a group
list_models_in_group() {
    local group="$1"
    local output_file="$2"
    
    if [ -z "$group" ]; then
        log_model_config "ERROR" "Group is required for list operation"
        return 1
    fi
    
    # Default output file if not provided
    if [ -z "$output_file" ]; then
        output_file=$(mktemp)
    fi
    
    # Initialize config if needed
    initialize_model_config
    
    # Get all models in the group
    jq --arg group "$group" \
       '.[$group] // {} | to_entries | map(.value)' "$MODEL_CONFIG_FILE" > "$output_file" 2>/dev/null
    
    if [ -s "$output_file" ]; then
        log_model_config "DEBUG" "Listed models in group: $group"
        echo "$output_file"
        return 0
    else
        log_model_config "DEBUG" "No models found in group or group does not exist: $group"
        echo "[]" > "$output_file"
        echo "$output_file"
        return 0
    fi
}

# Function to get model download URL by local path
get_model_download_url() {
    local local_path="$1"
    local output_file="$2"

    local temp_file
    temp_file=$(mktemp)

    if find_model_by_path "" "$local_path" "$temp_file"; then
        if [ -f "$temp_file" ]; then
            local download_url
            download_url=$(jq -r '.downloadUrl // empty' "$temp_file" 2>/dev/null)
            rm -f "$temp_file"

            if [ -n "$download_url" ] && [ "$download_url" != "null" ]; then
                echo "$download_url" > "$output_file"
                return 0
            else
                log_model_config "WARN" "No download URL found for model: $local_path"
                return 1
            fi
        fi
    else
        log_model_config "WARN" "Model not found in config: $local_path"
        rm -f "$temp_file"
        return 1
    fi
}

# Function to convert model to symlink
convert_to_symlink() {
    local group="$1"
    local local_path="$2"
    local existing_model_s3_path="$3"
    
    if [ -z "$group" ] || [ -z "$local_path" ] || [ -z "$existing_model_s3_path" ]; then
        log_model_config "ERROR" "Group, local path, and existing model S3 path are required for symlink conversion"
        return 1
    fi
    
    log_model_config "INFO" "Converting model to symlink: $group/$local_path -> $existing_model_s3_path"
    
    # Find the existing model
    local model_file
    model_file=$(find_model_by_path "" "$local_path")
    
    if [ $? -eq 0 ] && [ -f "$model_file" ]; then
        local model_object
        model_object=$(cat "$model_file")
        rm -f "$model_file"
        
        # Update model object for symlink - remove download URL and set symlink properties
        local timestamp
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
        
        # Strip S3 bucket prefix from paths before saving locally
        local s3_bucket_prefix="s3://$AWS_BUCKET_NAME/"
        local stripped_s3_path="$existing_model_s3_path"
        if [[ "$existing_model_s3_path" == "$s3_bucket_prefix"* ]]; then
            stripped_s3_path="${existing_model_s3_path#$s3_bucket_prefix}"
        fi
        
        # Validate JSON before processing
        if ! echo "$model_object" | jq empty >/dev/null 2>&1; then
            log_model_config "ERROR" "Invalid JSON for model object in symlink conversion:" >&2
            log_model_config "ERROR" "Content: $model_object" >&2
            return 1
        fi
        
        model_object=$(echo "$model_object" | jq \
            --arg s3Path "$stripped_s3_path" \
            --arg timestamp "$timestamp" \
            '. + {
                "originalS3Path": $s3Path,
                "symLinkedFrom": $s3Path,
                "lastUpdated": $timestamp
            } | del(.downloadUrl)')
        
        # Update the config
        create_or_update_model "$group" "$model_object"
        return $?
    else
        log_model_config "ERROR" "Model not found in config for symlink conversion: $local_path"
        return 1
    fi
}

# Function to remove model by local path
remove_model_by_path() {
    local local_path="$1"
    
    if [ -z "$local_path" ]; then
        log_model_config "ERROR" "Local path is required for remove operation"
        return 1
    fi
    
    log_model_config "INFO" "Removing model by local path: $local_path"
    
    # Acquire lock
    if ! acquire_model_config_lock "remove"; then
        log_model_config "ERROR" "Failed to acquire lock for model removal"
        return 1
    fi
    
    # Set up trap to release lock on exit
    trap "release_model_config_lock 'remove'" EXIT INT TERM QUIT
    
    # Initialize config if needed
    initialize_model_config
    
    # Find the model first to get group and name
    local model_found=false
    local temp_file
    temp_file=$(mktemp)
    
    # Search for model and remove it
    jq --arg localPath "$local_path" '
    . as $root |
    reduce to_entries[] as $group ({}; 
        if ($group.value | type == "object") then
            .[$group.key] = (
                $group.value | 
                to_entries |
                map(select(.value.localPath != $localPath)) |
                from_entries
            )
        else
            .[$group.key] = $group.value
        end
    )
    ' "$MODEL_CONFIG_FILE" > "$temp_file"
    
    if [ $? -eq 0 ] && jq empty "$temp_file" 2>/dev/null; then
        # Check if anything was actually removed
        local original_count new_count
        original_count=$(jq '[.. | objects | select(has("localPath")) | .localPath] | length' "$MODEL_CONFIG_FILE" 2>/dev/null || echo "0")
        new_count=$(jq '[.. | objects | select(has("localPath")) | .localPath] | length' "$temp_file" 2>/dev/null || echo "0")
        
        if [ "$new_count" -lt "$original_count" ]; then
            mv "$temp_file" "$MODEL_CONFIG_FILE"
            log_model_config "INFO" "Successfully removed model from config: $local_path"
            model_found=true
        else
            log_model_config "INFO" "Model not found in config: $local_path"
            rm -f "$temp_file"
        fi
    else
        log_model_config "ERROR" "Failed to update model config file during removal"
        rm -f "$temp_file"
    fi
    
    # Release lock
    release_model_config_lock "remove"
    trap - EXIT INT TERM QUIT
    
    if [ "$model_found" = true ]; then
        return 0
    else
        return 1
    fi
}

# Function to load all current local models excluding symlinks
load_local_models() {
    local output_file="${1:-}"
    
    # Default output file if not provided
    if [ -z "$output_file" ]; then
        output_file=$(mktemp)
    fi
    
    log_model_config "INFO" "Loading all local models (excluding symlinks)"
    
    # Initialize config if needed
    initialize_model_config
    
    # Extract all models that are NOT symlinks (don't have symLinkedFrom field)
    jq '
    [
        to_entries[] |
        select(.value | type == "object") as $group |
        $group.value | to_entries[] |
        select(.value.symLinkedFrom == null or .value.symLinkedFrom == "") |
        .value + {
            "modelKey": .key,
            "directoryGroup": $group.key
        }
    ]
    ' "$MODEL_CONFIG_FILE" > "$output_file" 2>/dev/null
    
    if [ $? -eq 0 ] && [ -f "$output_file" ]; then
        local model_count
        model_count=$(jq 'length' "$output_file" 2>/dev/null || echo "0")
        log_model_config "INFO" "Loaded $model_count local models (excluding symlinks)"
        echo "$output_file"
        return 0
    else
        log_model_config "ERROR" "Failed to load local models"
        rm -f "$output_file"
        return 1
    fi
}

# Function to resolve symlinks and create them on the filesystem
resolve_symlinks() {
    local target_s3_path="$1"      # S3 path to find symlinks for
    local target_model_name="$2"   # Model name to find symlinks for
    local dry_run="${3:-false}"    # If true, don't create actual symlinks
    
    if [ -z "$target_s3_path" ] && [ -z "$target_model_name" ]; then
        log_model_config "ERROR" "Either target S3 path or model name is required for symlink resolution"
        return 1
    fi
    
    log_model_config "INFO" "Resolving symlinks for target: s3_path='$target_s3_path', model_name='$target_model_name', dry_run=$dry_run"
    
    # Initialize config if needed
    initialize_model_config
    
    local temp_file
    temp_file=$(mktemp)
    
    # Find all models that are symlinked to the target
    local jq_filter
    if [ -n "$target_s3_path" ] && [ -n "$target_model_name" ]; then
        # Search by both S3 path and model name
        jq_filter='
        [
            to_entries[] |
            select(.value | type == "object") as $group |
            $group.value | to_entries[] |
            select(
                (.value.symLinkedFrom != null and .value.symLinkedFrom != "") and
                ((.value.symLinkedFrom | contains($targetS3Path)) or 
                 (.value.symLinkedFrom | test($targetModelName)))
            ) |
            .value + {
                "modelKey": .key,
                "directoryGroup": $group.key
            }
        ]
        '
    elif [ -n "$target_s3_path" ]; then
        # Search by S3 path only
        jq_filter='
        [
            to_entries[] |
            select(.value | type == "object") as $group |
            $group.value | to_entries[] |
            select(
                (.value.symLinkedFrom != null and .value.symLinkedFrom != "") and
                (.value.symLinkedFrom | contains($targetS3Path))
            ) |
            .value + {
                "modelKey": .key,
                "directoryGroup": $group.key
            }
        ]
        '
    else
        # Search by model name only - find symlinks that reference the target model
        jq_filter='
        [
            to_entries[] |
            select(.value | type == "object") as $group |
            $group.value | to_entries[] |
            select(
                (.value.symLinkedFrom != null and .value.symLinkedFrom != "") and
                (.value.symLinkedFrom | test($targetModelName))
            ) |
            .value + {
                "modelKey": .key,
                "directoryGroup": $group.key
            }
        ]
        '
    fi
    
    jq --arg targetS3Path "${target_s3_path:-}" \
       --arg targetModelName "${target_model_name:-}" \
       "$jq_filter" "$MODEL_CONFIG_FILE" > "$temp_file" 2>/dev/null
    
    if [ $? -ne 0 ]; then
        log_model_config "ERROR" "Failed to query symlink models"
        rm -f "$temp_file"
        return 1
    fi
    
    local symlink_count
    symlink_count=$(jq 'length' "$temp_file" 2>/dev/null || echo "0")
    
    if [ "$symlink_count" -eq 0 ]; then
        log_model_config "INFO" "No symlinks found for target"
        rm -f "$temp_file"
        return 0
    fi
    
    log_model_config "INFO" "Found $symlink_count symlink(s) to resolve"
    
    # Process each symlink
    local created_count=0
    local failed_count=0
    
    while IFS= read -r symlink_model; do
        if [ -z "$symlink_model" ] || [ "$symlink_model" = "null" ]; then
            continue
        fi
        
        local symlink_path target_path model_name directory_group
        symlink_path=$(echo "$symlink_model" | jq -r '.localPath // empty')
        target_path=$(echo "$symlink_model" | jq -r '.symLinkedFrom // empty')
        model_name=$(echo "$symlink_model" | jq -r '.modelName // empty')
        directory_group=$(echo "$symlink_model" | jq -r '.directoryGroup // empty')
        
        if [ -z "$symlink_path" ] || [ -z "$target_path" ]; then
            log_model_config "WARN" "Incomplete symlink configuration for model: $model_name"
            failed_count=$((failed_count + 1))
            continue
        fi
        
        # Convert relative S3 path to full local path
        local full_target_path
        if [[ "$target_path" == /* ]]; then
            # Absolute path starting with / - construct full local path
            full_target_path="$NETWORK_VOLUME/ComfyUI$target_path"
        elif [[ "$target_path" == models/* ]]; then
            # Path already starts with "models/" - construct from ComfyUI directory
            full_target_path="$NETWORK_VOLUME/ComfyUI/$target_path"
        else
            # Relative path - assume it's under models/
            full_target_path="$NETWORK_VOLUME/ComfyUI/models/$target_path"
        fi
        
        log_model_config "INFO" "Processing symlink: $symlink_path -> $full_target_path"
        
        if [ "$dry_run" = "true" ]; then
            log_model_config "INFO" "[DRY RUN] Would create symlink: $symlink_path -> $full_target_path"
            created_count=$((created_count + 1))
            continue
        fi
        
        # Check if target exists
        if [ ! -f "$full_target_path" ]; then
            log_model_config "WARN" "Symlink target does not exist: $full_target_path (for $symlink_path)"
            failed_count=$((failed_count + 1))
            continue
        fi
        
        # Create directory for symlink if needed
        local symlink_dir
        symlink_dir=$(dirname "$symlink_path")
        if [ ! -d "$symlink_dir" ]; then
            log_model_config "DEBUG" "Creating directory for symlink: $symlink_dir"
            mkdir -p "$symlink_dir"
        fi
        
        # Remove existing file/symlink if it exists
        if [ -e "$symlink_path" ] || [ -L "$symlink_path" ]; then
            log_model_config "DEBUG" "Removing existing file/symlink: $symlink_path"
            rm -f "$symlink_path"
        fi
        
        # Create the symlink
        if ln -s "$full_target_path" "$symlink_path" 2>/dev/null; then
            log_model_config "INFO" "Created symlink: $symlink_path -> $full_target_path"
            created_count=$((created_count + 1))
        else
            log_model_config "ERROR" "Failed to create symlink: $symlink_path -> $full_target_path"
            failed_count=$((failed_count + 1))
        fi
        
    done < <(jq -c '.[]' "$temp_file" 2>/dev/null)
    
    rm -f "$temp_file"
    
    log_model_config "INFO" "Symlink resolution completed: $created_count created, $failed_count failed"
    
    if [ "$failed_count" -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# Allow script to be sourced or called directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Called directly, show usage
    echo "📋 Model Configuration Manager"
    echo "============================="
    echo ""
    echo "This script manages models_config.json with thread-safe operations."
    echo ""
    echo "Functions available:"
    echo "  create_or_update_model <group> <model_object_json>"
    echo "  delete_model <group> <model_name>"
    echo "  find_model_by_path [group] <local_path> [output_file]"
    echo "  list_models_in_group <group> [output_file]"
    echo "  get_model_download_url <local_path>"
    echo "  convert_to_symlink <group> <local_path> <existing_s3_path>"
    echo "  remove_model_by_path <local_path>"
    echo "  load_local_models [output_file]"
    echo "  resolve_symlinks <target_s3_path> <target_model_name> [dry_run]"
    echo ""
    echo "Configuration file: $MODEL_CONFIG_FILE"
    echo "Lock directory: $MODEL_CONFIG_LOCK_DIR"
    echo "Log file: $MODEL_CONFIG_LOG"
    echo ""
    echo "Model object structure:"
    echo "  {"
    echo "    \"originalS3Path\": \"/path/model.safetensors\",  # S3 path with bucket prefix stripped"
    echo "    \"localPath\": \"/path/to/local/model.safetensors\","
    echo "    \"modelName\": \"model_name\","
    echo "    \"modelSize\": 1234567890,"
    echo "    \"downloadUrl\": \"https://example.com/model.safetensors\","
    echo "    \"symLinkedFrom\": \"/existing/path\" (optional),  # S3 path with bucket prefix stripped"
    echo "    \"uploadedAt\": \"2023-07-10T12:00:00.000Z\","
    echo "    \"lastUpdated\": \"2023-07-10T12:00:00.000Z\","
    echo "    \"directoryGroup\": \"checkpoints\""
    echo "  }"
    echo ""
    echo "Note: s3OriginalPath and symLinkedFrom fields have the s3://bucket prefix stripped"
    echo "      when stored in the local config file for portability."
    
    # Initialize if called directly
    initialize_model_config
    echo ""
    echo "Model config file initialized/verified."
fi
EOF

chmod +x "$TARGET_DIR/model_config_manager.sh"

echo "✅ Model configuration manager created at $TARGET_DIR/model_config_manager.sh"
