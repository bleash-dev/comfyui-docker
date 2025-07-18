#!/bin/bash
# Create utility scripts

echo "📝 Creating utility scripts..."

# Set default script directory, Python version, and config root
# NETWORK_VOLUME and AWS_BUCKET_NAME are assumed to be set in the environment
export SCRIPT_DIR="${SCRIPT_DIR:-/scripts}" # This SCRIPT_DIR is for the execution_analytics.sh
export PYTHON_VERSION="${PYTHON_VERSION:-3.10}"
export PYTHON_CMD="${PYTHON_CMD:-python${PYTHON_VERSION}}"
export CONFIG_ROOT="${CONFIG_ROOT:-/root}"
export COMFYUI_VENV="$NETWORK_VOLUME/venv/comfyui" # Assuming NETWORK_VOLUME is set

# Ensure the scripts directory within NETWORK_VOLUME exists
mkdir -p "$NETWORK_VOLUME/scripts"

# Analytics shortcut
cat > "$NETWORK_VOLUME/analytics" << EOF
#!/bin/bash
set -e -u -o pipefail
# SCRIPT_DIR below refers to the SCRIPT_DIR exported by the parent script
bash "\$SCRIPT_DIR/execution_analytics.sh" "\$@"
EOF

chmod +x "$NETWORK_VOLUME/analytics"

# ComfyUI startup wrapper
cat > "$NETWORK_VOLUME/start_comfyui_with_logs.sh" << EOF
#!/bin/bash
# ComfyUI startup wrapper with logging
set -e -u -o pipefail

# These variables are expected to be in the environment,
# typically exported by the script that launches this one.
# PYTHON_VERSION, PYTHON_CMD, CONFIG_ROOT, NETWORK_VOLUME, COMFYUI_VENV

COMFYUI_LOG="\$NETWORK_VOLUME/ComfyUI/comfyui.log"
COMFYUI_ERROR_LOG="\$NETWORK_VOLUME/ComfyUI/comfyui_error.log"

echo "🚀 Starting ComfyUI with logging at \$(date)"
echo "📝 Using Python: \$PYTHON_CMD (\$("\$PYTHON_CMD" --version))"
echo "📁 Using Config Root: \$CONFIG_ROOT"
echo "📦 Using Venv: \$COMFYUI_VENV"

# Ensure ComfyUI directory and venv exist
if [ ! -d "\$NETWORK_VOLUME/ComfyUI" ]; then
    echo "❌ Error: ComfyUI directory \$NETWORK_VOLUME/ComfyUI not found."
    exit 1
fi
if [ ! -f "\$COMFYUI_VENV/bin/activate" ]; then
    echo "❌ Error: ComfyUI venv \$COMFYUI_VENV/bin/activate not found."
    exit 1
fi

cd "\$NETWORK_VOLUME/ComfyUI"
# shellcheck source=/dev/null
. "\$COMFYUI_VENV/bin/activate"

# Ensure logs directory exists
mkdir -p "\$(dirname "\$COMFYUI_LOG")"

echo "🏁 Executing: \$PYTHON_CMD main.py --listen 0.0.0.0 --port 8080 --enable-cors-header \"*\""

PYTORCH_ENABLE_INDUCTOR=0 xvfb-run --auto-servernum --server-args="-screen 0 1920x1080x24" \
\$PYTHON_CMD main.py --listen 0.0.0.0 --port 8080 --enable-cors-header "*" \\
    > >(tee -a "\$COMFYUI_LOG") \\
    2> >(tee -a "\$COMFYUI_ERROR_LOG" >&2)
EOF
chmod +x "$NETWORK_VOLUME/start_comfyui_with_logs.sh"

# Model discovery script
cat > "$NETWORK_VOLUME/scripts/model_discovery.sh" << 'EOF'
#!/bin/bash
# Model discovery and local cache management
set -e -u -o pipefail

# These variables are expected to be set in the environment:
# NETWORK_VOLUME, AWS_BUCKET_NAME, MODEL_DISCOVERY_INTERVAL (optional)

LOCAL_MODELS_CACHE="$NETWORK_VOLUME/.cache/local-models.json"
S3_GLOBAL_MODELS_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/global_shared/models"
MODELS_BASE_DIR="$NETWORK_VOLUME/ComfyUI/models"

# Discovery interval (in seconds)
DISCOVERY_INTERVAL="${MODEL_DISCOVERY_INTERVAL:-30}" # 30 seconds default

discover_local_models() {
    echo "📊 Discovering local models in $MODELS_BASE_DIR..."
    
    mkdir -p "$(dirname "$LOCAL_MODELS_CACHE")"

    local tmp_json_lines_file
    tmp_json_lines_file=$(mktemp) || { echo "❌ Failed to create temp file" >&2; exit 1; }
    # Ensure cleanup of temp file on exit or signals
    trap 'rm -f "$tmp_json_lines_file"' EXIT SIGINT SIGTERM SIGQUIT

    if [ ! -d "$MODELS_BASE_DIR" ]; then
        echo "⚠️ Models directory not found: $MODELS_BASE_DIR. Creating empty cache."
        echo "[]" > "$LOCAL_MODELS_CACHE"
        return
    fi
    
    # Find ALL files in models directory (no extension filtering)
    find "$MODELS_BASE_DIR" -type f | while IFS= read -r model_file; do
        # Get relative path from models base
        # realpath is a GNU utility. On macOS, you might need grealpath.
        local rel_path
        rel_path=$(realpath --relative-to="$MODELS_BASE_DIR" "$model_file")
        
        # Generate model name from filename
        local model_name
        model_name=$(basename "$model_file")
        
        # Generate S3 locator
        local s3_locator
        s3_locator="$S3_GLOBAL_MODELS_BASE/$rel_path"
        
        # Create JSON object and append to array
        # Note: 'local_path' is relative to ComfyUI's root, assuming models are under "models/" subdirectory.
        local model_json
        model_json=$(jq -cn \
            --arg name "$model_name" \
            --arg local_path "models/$rel_path" \
            --arg s3_locator "$s3_locator" \
            '{
                model_name: $name,
                local_path: $local_path,
                s3_locator: $s3_locator
            }')
        
        echo "$model_json" >> "$tmp_json_lines_file"
    done
    
    # Combine all JSON objects into a single array
    jq -s '.' "$tmp_json_lines_file" > "$LOCAL_MODELS_CACHE"
    
    # No need to rm $tmp_json_lines_file here, trap will handle it.
    
    local model_count
    model_count=$(jq '. | length' "$LOCAL_MODELS_CACHE")
    echo "✅ Discovered $model_count local models. Cache updated: $LOCAL_MODELS_CACHE"
}

# Signal handler for graceful shutdown
handle_discovery_signal() {
    echo "📢 Model discovery received signal, stopping..."
    exit 0
}

# If --run-once is passed, just discover and exit
if [ "${1:-}" = "--run-once" ]; then
    discover_local_models
    exit 0
fi

trap handle_discovery_signal SIGTERM SIGINT SIGQUIT

echo "🔍 Starting model discovery service (interval: ${DISCOVERY_INTERVAL}s)..."
# Initial discovery
discover_local_models

# Periodic discovery loop
while true; do
    sleep "$DISCOVERY_INTERVAL"
    discover_local_models
done
EOF
chmod +x "$NETWORK_VOLUME/scripts/model_discovery.sh"

# Remote model sync script
cat > "$NETWORK_VOLUME/scripts/sync_remote_models.sh" << 'EOF'
#!/bin/bash
# Sync models from S3 based on a JSON manifest file.

# These variables are expected to be set in the environment:
# NETWORK_VOLUME, AWS_BUCKET_NAME

LOCAL_MODELS_MANIFEST="$NETWORK_VOLUME/.cache/local-models.json"
# The base directory for models is now derived from the manifest itself.
# This makes the script more flexible.

# Ensure jq is installed
if ! command -v jq &> /dev/null; then
    echo "❌ Error: 'jq' command not found. Please install jq to parse the JSON manifest."
    exit 1
fi

# Ensure the manifest file exists
if [ ! -f "$LOCAL_MODELS_MANIFEST" ]; then
    echo "❌ Error: Model manifest file not found at $LOCAL_MODELS_MANIFEST"
    exit 1
fi

sync_from_manifest() {
    echo "📋 Reading model manifest from: $LOCAL_MODELS_MANIFEST"

    local model_count
    model_count=$(jq '. | length' "$LOCAL_MODELS_MANIFEST")
    echo "📊 Manifest contains $model_count models to check."

    local synced_count=0
    local skipped_count=0
    local failed_count=0
    local not_found_count=0

    # Use jq to iterate over each model object in the JSON array
    # The 'c' flag is for compact output, and 'r' is for raw string output (no quotes)
    jq -c '.[]' "$LOCAL_MODELS_MANIFEST" | while IFS= read -r model_json; do
        # Extract details for each model using jq
        local model_name s3_locator local_path
        model_name=$(echo "$model_json" | jq -r '.model_name')
        s3_locator=$(echo "$model_json" | jq -r '.s3_locator')
        local_path=$(echo "$model_json" | jq -r '.local_path') # This is the full local path

        # Skip entries that look like placeholders or are invalid
        if [ "$model_name" = ".global_shared_info" ] || [ -z "$s3_locator" ] || [ -z "$local_path" ]; then
            echo "  ⏩ Skipping invalid or placeholder entry: $model_name"
            continue
        fi
        
        # Prepend the network volume to get the absolute path
        local full_local_path="$NETWORK_VOLUME/ComfyUI/$local_path"

        if [ -f "$full_local_path" ]; then
            # echo "  👍 Model already exists, skipping: $model_name"
            ((skipped_count++))
        else
            echo "  📥 Syncing missing model: $model_name"
            echo "     from: $s3_locator"
            echo "     to:   $full_local_path"
            
            # Check if the object exists in S3 before trying to download
            if ! aws s3api head-object --bucket "$(echo "$s3_locator" | cut -d/ -f3)" --key "$(echo "$s3_locator" | cut -d/ -f4-)" &> /dev/null; then
                 echo "  ❌ S3 object not found: $s3_locator"
                 ((not_found_count++))
                 continue
            fi
            
            # Create the destination directory
            mkdir -p "$(dirname "$full_local_path")"
            
            # Download the file from S3
            if aws s3 cp "$s3_locator" "$full_local_path" --only-show-errors; then
                echo "  ✅ Successfully synced: $model_name"
                ((synced_count++))
            else
                echo "  ❌ Failed to sync: $model_name (AWS CLI exit code: $?)"
                ((failed_count++))
            fi
        fi
    done

    echo "---"
    echo "✅ Sync process completed."
    echo "   - Synced: $synced_count new models."
    echo "   - Skipped (already exist): $skipped_count models."
    if [ "$failed_count" -gt 0 ]; then
        echo "   - ⚠️ Failed: $failed_count models."
    fi
    if [ "$not_found_count" -gt 0 ]; then
        echo "   - ⚠️ Not Found in S3: $not_found_count models."
    fi
}

sync_all_from_s3() {
    echo "🔄 Syncing ALL available models from S3 (full sync)..."
    local s3_global_models_base="s3://$AWS_BUCKET_NAME/pod_sessions/global_shared/models"
    # Note: The local path from the manifest is ignored here. We sync to a common root.
    # The original script put everything in ComfyUI/models. Let's make that explicit.
    local models_base_dir="$NETWORK_VOLUME/ComfyUI/models"
    mkdir -p "$models_base_dir"

    echo "   Source: $s3_global_models_base/"
    echo "   Destination: $models_base_dir/"
    
    if aws s3 sync "$s3_global_models_base/" "$models_base_dir/" --only-show-errors; then
        echo "✅ Full model sync completed."
    else
        echo "❌ Full model sync failed. Check AWS CLI errors above."
    fi
}


echo "🌐 Starting remote model sync..."

# Check if we should sync based on manifest or sync all from S3
if [ "${1:-}" = "--all" ]; then
    sync_all_from_s3
else
    sync_from_manifest
fi

echo "✨ Remote model sync finished."
EOF
chmod +x "$NETWORK_VOLUME/scripts/sync_remote_models.sh"

# Model management utility script
cat > "$NETWORK_VOLUME/scripts/manage_models.sh" << 'EOF'
#!/bin/bash
# Model management utility script
set -e -u -o pipefail

# These variables are expected to be set in the environment:
# NETWORK_VOLUME, AWS_BUCKET_NAME

LOCAL_MODELS_CACHE="$NETWORK_VOLUME/.cache/local-models.json"
S3_GLOBAL_MODELS_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/global_shared/models"
MODELS_BASE_DIR="$NETWORK_VOLUME/ComfyUI/models" # Used for reference, actual paths are in cache

show_help() {
    echo "🛠️ ComfyUI Model Management Utility"
    echo "===================================="
    echo ""
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  list                    - List all locally cached models"
    echo "  list-remote             - List all models available in S3"
    echo "  sync [--all]            - Sync missing models from S3 (--all syncs everything)"
    echo "  search <pattern>        - Search for models by name pattern in local cache"
    echo "  info <model_name>       - Show detailed information about a cached model"
    echo "  refresh                 - Refresh local model cache by running discovery once"
    echo "  status                  - Show model sync status and cache info"
    echo "  help                    - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 list                           # List all local models"
    echo "  $0 search \"stable-diffusion\"      # Search for stable diffusion models"
    echo "  $0 sync                           # Sync missing models"
    echo "  $0 sync --all                     # Sync all available models"
    echo "  $0 refresh                        # Update the local model cache"
}

list_local_models() {
    echo "📋 Local Models Cache ($LOCAL_MODELS_CACHE)"
    echo "===================="
    
    if [ ! -f "$LOCAL_MODELS_CACHE" ]; then
        echo "❌ Local models cache not found. Run '$0 refresh' to generate cache."
        return 1
    fi
    
    if ! jq -e '. | length > 0' "$LOCAL_MODELS_CACHE" > /dev/null 2>&1; then
        echo "ℹ️ Local model cache is empty or invalid."
        jq '. | length' "$LOCAL_MODELS_CACHE" # Show length for debugging
        return
    fi
    
    printf "%-40s | %-20s | %s\n" "Model Name" "Category" "Local Path (relative to ComfyUI root)"
    printf "%-40s | %-20s | %s\n" "----------------------------------------" "--------------------" "---------------------------------------"
    
    jq -r '.[] | "\(.model_name)|\(.local_path | split("/")[1])|\(.local_path)"' "$LOCAL_MODELS_CACHE" | \
    while IFS='|' read -r name category path; do
        printf "%-40s | %-20s | %s\n" "$name" "$category" "$path"
    done
    
    local total_models
    total_models=$(jq '. | length' "$LOCAL_MODELS_CACHE")
    echo ""
    echo "Total local models cached: $total_models"
}

list_remote_models() {
    echo "📋 Remote Models Available in S3 ($S3_GLOBAL_MODELS_BASE)"
    echo "======================================================"
    echo "Fetching remote model list (this may take a moment)..."

    local s3_prefix_in_bucket
    s3_prefix_in_bucket=$(echo "$S3_GLOBAL_MODELS_BASE" | sed "s|^s3://$AWS_BUCKET_NAME/||")
    if [[ -n "$s3_prefix_in_bucket" && "${s3_prefix_in_bucket: -1}" != "/" ]]; then
        s3_prefix_in_bucket+="/"
    fi

    local remote_list_tmp
    remote_list_tmp=$(mktemp)
    trap 'rm -f "$remote_list_tmp"' RETURN # Clean up on function exit

    aws s3api list-objects-v2 --bucket "$AWS_BUCKET_NAME" --prefix "$s3_prefix_in_bucket" \
        --query 'Contents[?Size > `0`].[Key]' --output text | \
        sed "s|^$s3_prefix_in_bucket||" > "$remote_list_tmp"

    if [ ! -s "$remote_list_tmp" ]; then # Check if file is not empty
        echo "ℹ️ No remote models found in S3 at the specified path."
        return
    fi
    
    printf "%-40s | %-20s | %s\n" "Model Name" "Category" "S3 Relative Path"
    printf "%-40s | %-20s | %s\n" "----------------------------------------" "--------------------" "------------------"
            
    while IFS= read -r model_rel_path; do
        [ -z "$model_rel_path" ] && continue 
        
        local category model_name
        category=$(echo "$model_rel_path" | cut -d'/' -f1)
        if [[ "$model_rel_path" != *"/"* ]]; then # File at the root of the S3 models path
            category="-" # Or 'root', or keep as filename
        fi
        model_name=$(basename "$model_rel_path")
        printf "%-40s | %-20s | %s\n" "$model_name" "$category" "$model_rel_path"
    done < "$remote_list_tmp" | sort
    
    local remote_count
    remote_count=$(wc -l < "$remote_list_tmp")
    echo ""
    echo "Total remote models found: $remote_count"
}

search_models() {
    local pattern="$1"
    
    if [ -z "$pattern" ]; then
        echo "❌ Search pattern required. Usage: $0 search <pattern>" >&2
        return 1
    fi
    
    echo "🔍 Searching local cache for models matching: $pattern"
    echo "=================================================="
    
    if [ ! -f "$LOCAL_MODELS_CACHE" ]; then
        echo "❌ Local models cache not found. Run '$0 refresh' to generate cache." >&2
        return 1
    fi
    
    if ! jq -e '. | length > 0' "$LOCAL_MODELS_CACHE" > /dev/null 2>&1; then
        echo "ℹ️ Local model cache is empty or invalid."
        return
    fi
    
    local results_found=false
    printf "%-40s | %-20s | %s\n" "Model Name" "Category" "Local Path"
    printf "%-40s | %-20s | %s\n" "----------------------------------------" "--------------------" "------------"
    
    jq -r --arg pattern "$pattern" \
       '.[] | select(.model_name | test($pattern; "i")) | "\(.model_name)|\(.local_path | split("/")[1])|\(.local_path)"' \
       "$LOCAL_MODELS_CACHE" | \
    while IFS='|' read -r name category path; do
        printf "%-40s | %-20s | %s\n" "$name" "$category" "$path"
        results_found=true
    done

    if ! $results_found; then
        echo "No models found matching '$pattern' in the local cache."
    fi
}

show_model_info() {
    local model_name_arg="$1"
    
    if [ -z "$model_name_arg" ]; then
        echo "❌ Model name required. Usage: $0 info <model_name>" >&2
        return 1
    fi
    
    echo "📊 Model Information (from local cache): $model_name_arg"
    echo "=================================================="
    
    if [ ! -f "$LOCAL_MODELS_CACHE" ]; then
        echo "❌ Local models cache not found. Run '$0 refresh' to generate cache." >&2
        return 1
    fi
    
    local model_info
    # Use exact match for model_name
    model_info=$(jq -r --arg name_exact "$model_name_arg" \
        '.[] | select(.model_name == $name_exact) | @json' "$LOCAL_MODELS_CACHE")
    
    if [ -z "$model_info" ]; then
        echo "❌ Model not found in local cache: $model_name_arg"
        echo "   You can try '$0 search \"$model_name_arg\"' for partial matches."
        return 1
    fi
    
    echo "$model_info" | jq -r '
        "Name:         " + .model_name,
        "Local Path:   " + .local_path,
        "S3 Location:  " + .s3_locator,
        "Category:     " + (.local_path | split("/")[1])
    '
    
    # Check if file exists locally
    # local_path in cache is like "models/checkpoints/foo.safetensors"
    # Full path is $NETWORK_VOLUME/ComfyUI/models/checkpoints/foo.safetensors
    local local_file_full_path="$NETWORK_VOLUME/ComfyUI/$(echo "$model_info" | jq -r '.local_path')"
    if [ -f "$local_file_full_path" ]; then
        echo "Status:       ✅ Available locally"
        echo "File size:    $(du -h "$local_file_full_path" | cut -f1)"
        # stat command portability: -c for GNU, -f for BSD/macOS
        echo "Last modified:$(stat -c '%y' "$local_file_full_path" 2>/dev/null || stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S %Z' "$local_file_full_path" 2>/dev/null || echo 'N/A')"
    else
        echo "Status:       ❌ Not available locally (path: $local_file_full_path)"
        echo "              (Run '$0 sync' to download missing models)"
    fi
}

refresh_cache() {
    echo "🔄 Refreshing local model cache..."
    # Call model_discovery.sh to run once and update the cache
    if bash "$NETWORK_VOLUME/scripts/model_discovery.sh" --run-once; then
        echo "✅ Model cache refreshed successfully."
    else
        echo "❌ Failed to refresh model cache." >&2
        return 1
    fi
}

show_status() {
    echo "📊 Model Sync Status & Configuration"
    echo "==================================="
    
    local local_count=0
    if [ -f "$LOCAL_MODELS_CACHE" ]; then
        if jq '.' "$LOCAL_MODELS_CACHE" > /dev/null 2>&1; then
             local_count=$(jq '. | length' "$LOCAL_MODELS_CACHE")
        else
            echo "⚠️ Local models cache ($LOCAL_MODELS_CACHE) is present but invalid JSON."
        fi
        echo "Local models cached: $local_count (last updated: $(stat -c '%y' "$LOCAL_MODELS_CACHE" 2>/dev/null || stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S %Z' "$LOCAL_MODELS_CACHE" 2>/dev/null || echo 'N/A'))"
    else
        echo "Local models cache: ❌ Not found ($LOCAL_MODELS_CACHE). Run '$0 refresh'."
    fi
    
    echo "Checking remote S3 availability..."
    local s3_prefix_in_bucket remote_count="N/A"
    s3_prefix_in_bucket=$(echo "$S3_GLOBAL_MODELS_BASE" | sed "s|^s3://$AWS_BUCKET_NAME/||")
    if [[ -n "$s3_prefix_in_bucket" && "${s3_prefix_in_bucket: -1}" != "/" ]]; then
        s3_prefix_in_bucket+="/"
    fi
    
    # Get count of actual file objects
    remote_count=$(aws s3api list-objects-v2 --bucket "$AWS_BUCKET_NAME" --prefix "$s3_prefix_in_bucket" \
                    --query "length(Contents[?Size > \`0\`])" --output text 2>/dev/null) || remote_count="Error fetching"
    
    if [[ "$remote_count" == "None" || -z "$remote_count" || "$remote_count" == "Error fetching" ]]; then
        # If error or None, try to list to see if bucket/prefix is accessible at all
        if ! aws s3 ls "${S3_GLOBAL_MODELS_BASE%/}/" >/dev/null 2>&1; then # Check if prefix exists
             remote_count="Error accessing S3 path"
        else
             remote_count=0 # Path exists but no files, or query failed but path is valid
        fi
    fi
    echo "Remote models available in S3: $remote_count"
    
    echo ""
    echo "Configuration:"
    echo "  Cache file: $LOCAL_MODELS_CACHE"
    echo "  ComfyUI Models directory (base): $NETWORK_VOLUME/ComfyUI/models"
    echo "  S3 base path for models: $S3_GLOBAL_MODELS_BASE"
    echo "  AWS Bucket: $AWS_BUCKET_NAME"
    
    echo ""
    echo "Service Status:"
    # Check if model discovery is running (the background daemon version)
    # This pgrep is a bit naive, might match unrelated scripts if names are similar.
    if pgrep -f "$NETWORK_VOLUME/scripts/model_discovery.sh" | grep -qv "$$"; then # Exclude self if manage_models is calling it
        echo "  Model discovery service (daemon): ✅ Running"
    else
        echo "  Model discovery service (daemon): ❌ Not running (or run with --run-once)"
    fi
}

# Main command handling
# If no command, default to help
main_command="${1:-help}"

case "$main_command" in
    "list")
        list_local_models
        ;;
    "list-remote")
        list_remote_models
        ;;
    "sync")
        # Pass through arguments like --all to the sync script
        shift || true # remove "sync"
        bash "$NETWORK_VOLUME/scripts/sync_remote_models.sh" "$@"
        ;;
    "search")
        search_models "${2:-}" # Pass second arg as pattern
        ;;
    "info")
        show_model_info "${2:-}" # Pass second arg as model name
        ;;
    "refresh")
        refresh_cache
        ;;
    "status")
        show_status
        ;;
    "help"|"--help"|"-h")
        show_help
        ;;
    *)
        echo "❌ Unknown command: $main_command" >&2
        echo "Run '$0 help' for usage information."
        exit 1
        ;;
esac
EOF

chmod +x "$NETWORK_VOLUME/scripts/manage_models.sh"

# Create convenient shortcut for model management
cat > "$NETWORK_VOLUME/models" << EOF
#!/bin/bash
set -e -u -o pipefail
# Pass all arguments to the main management script
bash "$NETWORK_VOLUME/scripts/manage_models.sh" "\$@"
EOF

chmod +x "$NETWORK_VOLUME/models"

echo "✅ Utility scripts created successfully."
echo "   - Analytics shortcut: $NETWORK_VOLUME/analytics"
echo "   - ComfyUI starter: $NETWORK_VOLUME/start_comfyui_with_logs.sh"
echo "   - Model discovery daemon: $NETWORK_VOLUME/scripts/model_discovery.sh"
echo "   - Model sync script: $NETWORK_VOLUME/scripts/sync_remote_models.sh"
echo "   - Model management tool: $NETWORK_VOLUME/scripts/manage_models.sh (or shortcut: $NETWORK_VOLUME/models)"