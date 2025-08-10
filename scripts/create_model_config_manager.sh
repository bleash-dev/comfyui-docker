#!/bin/bash
# Create model configuration management script

echo "📝 Creating model configuration management script..."

# Create the model configuration manager
cat > "$NETWORK_VOLUME/scripts/model_config_manager.sh" << 'EOF'
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
    
    # Strip S3 bucket prefix from originalS3Path before saving locally
    local s3_bucket_prefix="s3://$AWS_BUCKET_NAME/"
    model_object=$(echo "$model_object" | jq \
        --arg bucketPrefix "$s3_bucket_prefix" \
        '
        # Strip bucket prefix from originalS3Path if it exists
        if .originalS3Path and (.originalS3Path | startswith($bucketPrefix)) then
            .originalS3Path = (.originalS3Path | sub($bucketPrefix; ""))
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
# Supports both exact matching and substring matching
# If exact match is found, returns that; otherwise returns all models containing the path
find_model_by_path() {
    local group="$1"
    local local_path="$2"
    local output_file="${3:-}"
    local match_type="${4:-auto}"  # "exact", "contains", or "auto" (try exact first, then contains)
    
    # Support both old and new calling conventions
    if [ -z "$output_file" ] && [ -z "$local_path" ]; then
        # Old convention: find_model_by_path <local_path> [output_file]
        local_path="$group"
        output_file="$2"
        group=""
        match_type="${3:-auto}"
    elif [ -z "$output_file" ] && [ -n "$local_path" ]; then
        # New convention: find_model_by_path <group> <local_path> [output_file] [match_type]
        output_file=""
        match_type="${4:-auto}"
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
    
    local exact_output contains_output
    exact_output=$(mktemp)
    contains_output=$(mktemp)
    
    # First try exact match
    if [ -n "$group" ]; then
        # Search in specific group - exact match
        jq --arg group "$group" \
           --arg localPath "$local_path" \
           '
           .[$group] // {} |
           to_entries[] |
           select(.value.localPath == $localPath) |
           .value + {"directoryGroup": $group}
           ' "$MODEL_CONFIG_FILE" > "$exact_output" 2>/dev/null
        
        # Search in specific group - contains match
        jq --arg group "$group" \
           --arg localPath "$local_path" \
           '
           [.[$group] // {} |
           to_entries[] |
           select(.value.localPath and (.value.localPath | contains($localPath))) |
           .value + {"directoryGroup": $group}]
           ' "$MODEL_CONFIG_FILE" > "$contains_output" 2>/dev/null
    else
        # Search across all groups - exact match
        jq --arg localPath "$local_path" \
           '
           [to_entries[] | 
           select(.value | type == "object") |
           {key: .key, models: .value} |
           .models | to_entries[] |
           select(.value.localPath == $localPath) |
           .value + {"directoryGroup": .key}][0] // empty
           ' "$MODEL_CONFIG_FILE" > "$exact_output" 2>/dev/null
        
        # Search across all groups - contains match
        jq --arg localPath "$local_path" \
           '
           [to_entries[] | 
           select(.value | type == "object") |
           {key: .key, models: .value} |
           .models | to_entries[] |
           select(.value.localPath and (.value.localPath | contains($localPath))) |
           .value + {"directoryGroup": .key}]
           ' "$MODEL_CONFIG_FILE" > "$contains_output" 2>/dev/null
    fi
    
    # Determine which results to return based on match_type and what was found
    local use_exact=false
    local use_contains=false
    
    case "$match_type" in
        "exact")
            use_exact=true
            ;;
        "contains")
            use_contains=true
            ;;
        "auto")
            # If exact match found, use it; otherwise use contains results
            if [ -s "$exact_output" ] && [ "$(jq -r '. | length' "$exact_output" 2>/dev/null)" != "0" ]; then
                use_exact=true
            else
                use_contains=true
            fi
            ;;
    esac
    
    if [ "$use_exact" = true ] && [ -s "$exact_output" ]; then
        # Check if exact output contains actual results (not just empty object/array)
        local exact_content
        exact_content=$(jq -r '. | if type == "array" then length else if . == {} then 0 else 1 end end' "$exact_output" 2>/dev/null)
        if [ "$exact_content" != "0" ]; then
            cp "$exact_output" "$output_file"
            rm -f "$exact_output" "$contains_output"
            log_model_config "DEBUG" "Found model with exact local path match: $local_path"
            echo "$output_file"
            return 0
        fi
    fi
    
    if [ "$use_contains" = true ] && [ -s "$contains_output" ]; then
        # Check if contains output has actual results
        local contains_count
        contains_count=$(jq 'length' "$contains_output" 2>/dev/null || echo "0")
        if [ "$contains_count" -gt 0 ]; then
            cp "$contains_output" "$output_file"
            rm -f "$exact_output" "$contains_output"
            log_model_config "DEBUG" "Found $contains_count model(s) with local path containing: $local_path"
            echo "$output_file"
            return 0
        fi
    fi
    
    # No matches found
    rm -f "$exact_output" "$contains_output"
    log_model_config "DEBUG" "No model found with local path matching: $local_path"
    rm -f "$output_file"
    return 1
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

# Function to remove model by local path
# Supports both exact matching and substring matching like find_model_by_path
# Can remove multiple models if using substring matching
remove_model_by_path() {
    local local_path="$1"
    local match_type="${2:-auto}"  # "exact", "contains", or "auto" (try exact first, then contains)
    
    if [ -z "$local_path" ]; then
        log_model_config "ERROR" "Local path is required for remove operation"
        return 1
    fi
    
    log_model_config "INFO" "Removing model(s) and any symlinks pointing to them with path matching '$local_path' (match_type: $match_type)"
    
    # Acquire lock
    if ! acquire_model_config_lock "remove"; then
        log_model_config "ERROR" "Failed to acquire lock for model removal"
        return 1
    fi
    
    # Set up trap to release lock on exit
    trap "release_model_config_lock 'remove'" EXIT INT TERM QUIT
    
    # Initialize config if needed
    initialize_model_config
    
    # Find models to remove using the same logic as find_model_by_path
    local models_to_remove
    models_to_remove=$(mktemp)
    
    # Get all models that match the criteria
    if [ "$match_type" = "exact" ]; then
        # Exact match only
        jq --arg localPath "$local_path" '
        [to_entries[] | 
        select(.value | type == "object") |
        {key: .key, models: .value} |
        .models | to_entries[] |
        select(.value.localPath == $localPath) |
        {group: .key, model: .key, localPath: .value.localPath}]
        ' "$MODEL_CONFIG_FILE" > "$models_to_remove" 2>/dev/null
    elif [ "$match_type" = "contains" ]; then
        # Contains match only
        jq --arg localPath "$local_path" '
        [to_entries[] | 
        select(.value | type == "object") |
        {key: .key, models: .value} |
        .models | to_entries[] |
        select(.value.localPath and (.value.localPath | contains($localPath))) |
        {group: .key, model: .key, localPath: .value.localPath}]
        ' "$MODEL_CONFIG_FILE" > "$models_to_remove" 2>/dev/null
    else
        # Auto mode: try exact first, then contains if no exact match
        local exact_matches contains_matches
        exact_matches=$(mktemp)
        contains_matches=$(mktemp)
        
        # Get exact matches
        jq --arg localPath "$local_path" '
        [to_entries[] | 
        select(.value | type == "object") |
        {key: .key, models: .value} |
        .models | to_entries[] |
        select(.value.localPath == $localPath) |
        {group: .key, model: .key, localPath: .value.localPath}]
        ' "$MODEL_CONFIG_FILE" > "$exact_matches" 2>/dev/null
        
        # Get contains matches
        jq --arg localPath "$local_path" '
        [to_entries[] | 
        select(.value | type == "object") |
        {key: .key, models: .value} |
        .models | to_entries[] |
        select(.value.localPath and (.value.localPath | contains($localPath))) |
        {group: .key, model: .key, localPath: .value.localPath}]
        ' "$MODEL_CONFIG_FILE" > "$contains_matches" 2>/dev/null
        
        # Use exact if available, otherwise contains
        local exact_count
        exact_count=$(jq 'length' "$exact_matches" 2>/dev/null || echo "0")
        
        if [ "$exact_count" -gt 0 ]; then
            cp "$exact_matches" "$models_to_remove"
            log_model_config "DEBUG" "Using exact matches for removal: $exact_count model(s)"
        else
            cp "$contains_matches" "$models_to_remove"
            local contains_count
            contains_count=$(jq 'length' "$contains_matches" 2>/dev/null || echo "0")
            log_model_config "DEBUG" "Using contains matches for removal: $contains_count model(s)"
        fi
        
        rm -f "$exact_matches" "$contains_matches"
    fi
    
    # Check if we found any models to remove
    local remove_count
    remove_count=$(jq 'length' "$models_to_remove" 2>/dev/null || echo "0")
    
    if [ "$remove_count" -eq 0 ]; then
        log_model_config "INFO" "No models found matching path: $local_path"
        rm -f "$models_to_remove"
        release_model_config_lock "remove"
        trap - EXIT INT TERM QUIT
        return 1
    fi
    
    log_model_config "INFO" "Found $remove_count model(s) to remove"
    
    # Create a list of all local paths that will be removed (for symlink cleanup)
    local paths_to_remove
    paths_to_remove=$(jq -r '.[].localPath' "$models_to_remove" 2>/dev/null)
    
    local model_found=false
    local temp_file
    temp_file=$(mktemp)
    
    # Remove all matching models
    jq --argjson modelsToRemove "$(cat "$models_to_remove")" '
    . as $root |
    ($modelsToRemove | map(.localPath)) as $pathsToRemove |
    reduce to_entries[] as $group ({}; 
        if ($group.value | type == "object") then
            .[$group.key] = (
                $group.value | 
                to_entries |
                map(select(
                    (.value.localPath | IN($pathsToRemove[]) | not)
                )) |
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
            local removed_count=$((original_count - new_count))
            log_model_config "INFO" "Successfully removed $removed_count model(s) from config matching: $local_path"
            
            # Log details of what was removed
            while IFS= read -r model_info; do
                if [ -n "$model_info" ]; then
                    local group model_name model_path
                    group=$(echo "$model_info" | jq -r '.group')
                    model_name=$(echo "$model_info" | jq -r '.model')
                    model_path=$(echo "$model_info" | jq -r '.localPath')
                    log_model_config "INFO" "Removed: $group/$model_name (path: $model_path)"
                fi
            done < <(jq -c '.[]' "$models_to_remove" 2>/dev/null)
            
            model_found=true
        else
            log_model_config "INFO" "No models were actually removed from config"
            rm -f "$temp_file"
        fi
    else
        log_model_config "ERROR" "Failed to update model config file during removal"
        rm -f "$temp_file"
    fi
    
    # Clean up
    rm -f "$models_to_remove"
    
    # Release lock
    release_model_config_lock "remove"
    trap - EXIT INT TERM QUIT
    
    if [ "$model_found" = true ]; then
        return 0
    else
        return 1
    fi
}

# Function to load all current local models
load_local_models() {
    local output_file="$1"
    
    # Default output file if not provided
    if [ -z "$output_file" ]; then
        output_file=$(mktemp)
    fi
    
    log_model_config "INFO" "Loading all local models"
    
    # Initialize config if needed
    initialize_model_config
    
    # Extract all models
    jq '
    [
        to_entries[] |
        select(.value | type == "object") as $group |
        $group.value | to_entries[] |
        .value + {
            "modelKey": .key,
            "directoryGroup": $group.key
        }
    ]
    ' "$MODEL_CONFIG_FILE" > "$output_file" 2>/dev/null
    
    if [ $? -eq 0 ] && [ -f "$output_file" ]; then
        local model_count
        model_count=$(jq 'length' "$output_file" 2>/dev/null || echo "0")
        log_model_config "INFO" "Loaded $model_count local models"
        echo "$output_file"
        return 0
    else
        log_model_config "ERROR" "Failed to load local models"
        rm -f "$output_file"
        return 1
    fi
}

# Function to determine download destination from local path and S3 path
# This ensures we download to a consistent location based on the S3 path structure
# and create symlinks if the actual destination differs from the requested local path
determine_download_destination() {
    local local_path="$1"
    local s3_path="$2"
    
    if [ -z "$local_path" ] || [ -z "$s3_path" ]; then
        return 1
    fi
    
    # Extract the base prefix from local_path (everything before /models/)
    local local_prefix=""
    if [[ "$local_path" =~ (.*/models)/ ]]; then
        local_prefix="${BASH_REMATCH[1]}"
    else
        # Fallback: try to find models directory in local_path
        local models_index
        models_index=$(echo "$local_path" | grep -o ".*/models" | tail -1)
        if [ -n "$models_index" ]; then
            local_prefix="$models_index"
        else
            # If no models directory found, use dirname of local_path as base
            local_prefix="$(dirname "$local_path")"
        fi
    fi
    
    # Clean up S3 path - remove s3:// prefix and bucket name if present
    local cleaned_s3_path="$s3_path"
    if [[ "$s3_path" =~ ^s3://[^/]+/(.*)$ ]]; then
        cleaned_s3_path="${BASH_REMATCH[1]}"
    elif [[ "$s3_path" =~ ^/(.*)$ ]]; then
        cleaned_s3_path="${BASH_REMATCH[1]}"
    fi
    
    # Extract the part after "models/" from S3 path
    local s3_after_models=""
    if [[ "$cleaned_s3_path" =~ models/(.*)$ ]]; then
        s3_after_models="${BASH_REMATCH[1]}"
    else
        # If no models/ found in S3 path, use the whole cleaned path
        s3_after_models="$cleaned_s3_path"
    fi
    
    # Construct the download destination
    local download_destination="${local_prefix}/${s3_after_models}"
    
    echo "$download_destination"
}

# Function to check if symlink is needed and get symlink info
# Returns: "symlink_needed|download_dest|local_path" or "no_symlink|download_dest"
check_symlink_requirement() {
    local local_path="$1"
    local s3_path="$2"
    
    if [ -z "$local_path" ] || [ -z "$s3_path" ]; then
        return 1
    fi
    
    local download_dest
    download_dest=$(determine_download_destination "$local_path" "$s3_path")
    
    if [ -z "$download_dest" ]; then
        return 1
    fi
    
    # Normalize paths for comparison
    local normalized_local
    local normalized_dest
    normalized_local=$(realpath -m "$local_path" 2>/dev/null || echo "$local_path")
    normalized_dest=$(realpath -m "$download_dest" 2>/dev/null || echo "$download_dest")
    
    if [ "$normalized_local" != "$normalized_dest" ]; then
        echo "symlink_needed|${download_dest}|${local_path}"
    else
        echo "no_symlink|${download_dest}"
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
    echo "  remove_model_by_path <local_path>"
    echo "  load_local_models [output_file]"
    echo "  determine_download_destination <local_path> <s3_path>"
    echo "  check_symlink_requirement <local_path> <s3_path>"
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
    echo "    \"uploadedAt\": \"2023-07-10T12:00:00.000Z\","
    echo "    \"lastUpdated\": \"2023-07-10T12:00:00.000Z\","
    echo "    \"directoryGroup\": \"checkpoints\""
    echo "  }"
    echo ""
    echo "Note: originalS3Path contains S3 path with bucket prefix stripped"
    
    # Initialize if called directly
    initialize_model_config
    echo ""
    echo "Model config file initialized/verified."
fi
EOF

chmod +x "$NETWORK_VOLUME/scripts/model_config_manager.sh"

echo "✅ Model configuration manager created at $NETWORK_VOLUME/scripts/model_config_manager.sh"
