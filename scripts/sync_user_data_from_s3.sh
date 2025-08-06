#!/bin/bash
# Tenant Data Sync: Copy base ComfyUI and sync user customizations
required_vars=("AWS_BUCKET_NAME" "POD_USER_NAME" "POD_ID" "NETWORK_VOLUME")
for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then 
        echo "❌ ERROR: Required environment variable $var is not set."
        exit 1
    fi
done

# Use centralized paths set by start_tenant.sh
BASE_COMFYUI_PATH="${BASE_COMFYUI_PATH:-/base/ComfyUI}"
BASE_VENV_PATH="${BASE_VENV_PATH:-/base/venv/comfyui}"

# Ensure workspace directories exist
mkdir -p "$NETWORK_VOLUME"
TENANT_COMFYUI_PATH="$NETWORK_VOLUME/ComfyUI"

# Validate base installation exists
if [ ! -d "$BASE_COMFYUI_PATH" ]; then
    echo "❌ ERROR: Base ComfyUI installation not found at $BASE_COMFYUI_PATH"
    echo "   This AMI was not properly built with the new architecture."
    exit 1
fi

if [ ! -d "$BASE_VENV_PATH" ]; then
    echo "❌ ERROR: Base ComfyUI virtual environment not found at $BASE_VENV_PATH"
    echo "   This AMI was not properly built with the new architecture."
    exit 1
fi

# --- Step 1: Copy Base ComfyUI Installation ---
echo "🎨 Copying base ComfyUI installation..."
echo "  📂 Copying from $BASE_COMFYUI_PATH to $TENANT_COMFYUI_PATH"

# Remove existing ComfyUI if it exists
if [ -d "$TENANT_COMFYUI_PATH" ]; then
    rm -rf "$TENANT_COMFYUI_PATH"
fi

# Copy the entire base ComfyUI installation
cp -r "$BASE_COMFYUI_PATH" "$TENANT_COMFYUI_PATH"

if [ -d "$TENANT_COMFYUI_PATH" ]; then
    echo "  ✅ Base ComfyUI copied successfully"
    echo "  📊 ComfyUI size: $(du -sh "$TENANT_COMFYUI_PATH" | cut -f1)"
else
    echo "  ❌ Failed to copy base ComfyUI"
    exit 1
fi

# --- Step 2: Setup Virtual Environment Access ---
echo "🐍 Setting up Python virtual environment access..."
echo "  📦 Using shared virtual environment at $BASE_VENV_PATH"

# Create activation helper script for this tenant
cat > "$NETWORK_VOLUME/activate-comfyui" << EOF
#!/bin/bash
# ComfyUI Environment Activation for Tenant $POD_ID
export COMFYUI_VENV="$BASE_VENV_PATH"
export PYTHONPATH="$TENANT_COMFYUI_PATH:\$PYTHONPATH"
source "\$COMFYUI_VENV/bin/activate"
echo "✅ ComfyUI environment activated for tenant $POD_ID"
echo "   Python: \$(which python)"
echo "   ComfyUI: $TENANT_COMFYUI_PATH"
EOF
chmod +x "$NETWORK_VOLUME/activate-comfyui"
echo "  ✅ Virtual environment access configured"

# Source S3 interactor if available
if [ -f "$NETWORK_VOLUME/scripts/s3_interactor.sh" ]; then
    source "$NETWORK_VOLUME/scripts/s3_interactor.sh"
else
    echo "⚠️ S3 interactor not found, using direct AWS CLI commands"
fi

# --- Helper Function: Download and Extract ---
download_and_extract() {
    local archive_s3_uri="$1"          
    local local_extract_target_dir="$2"  
    local archive_description="$3"       
    local tmp_archive_file
    local bucket_name key

    if [[ "$archive_s3_uri" =~ s3://([^/]+)/(.*) ]]; then
        bucket_name="${BASH_REMATCH[1]}"
        key="${BASH_REMATCH[2]}"
    else
        echo "❌ Invalid S3 URI format for $archive_description: $archive_s3_uri"
        return 1
    fi

    echo "📥 Checking for $archive_description archive: $archive_s3_uri"

    # Check if the archive exists on S3
    if command -v s3_object_exists >/dev/null 2>&1 && s3_object_exists "$archive_s3_uri"; then
        tmp_archive_file=$(mktemp "/tmp/s3_archive_dl_$(basename "$key" .tar.gz)_XXXXXX.tar.gz")

        echo "  📥 Downloading $archive_description..."
        if s3_copy_from "$archive_s3_uri" "$tmp_archive_file" "--only-show-errors"; then
            echo "  📦 Extracting to $local_extract_target_dir..."
            mkdir -p "$local_extract_target_dir"
            if tar -xzf "$tmp_archive_file" -C "$local_extract_target_dir"; then
                echo "  ✅ Extracted $archive_description successfully"
            else
                echo "  ⚠️ Failed to extract $archive_description"
            fi
            rm -f "$tmp_archive_file"
        else
            echo "  ⚠️ Failed to download $archive_description from S3"
            [ -f "$tmp_archive_file" ] && rm -f "$tmp_archive_file"
        fi
    else
        echo "  ⏭️ $archive_description not found in S3, skipping"
    fi
    echo "" 
}

# Note: Custom node dependency installation is now handled by setup_tenant_components.sh
# This script only handles copying/syncing the files themselves

# --- Define S3 Paths ---
S3_USER_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME"
S3_POD_BASE="$S3_USER_BASE/$POD_ID"
S3_USER_SHARED_BASE="$S3_USER_BASE/shared"

# --- Step 3: Sync User Cache Directory ---
echo "�️ Syncing user cache directory..."
download_and_extract \
    "$S3_USER_SHARED_BASE/_cache.tar.gz" \
    "$NETWORK_VOLUME" \
    "User cache data"

# --- Step 4: Sync User ComfyUI Config Directory ---
echo "⚙️ Syncing user ComfyUI config directory..."
download_and_extract \
    "$S3_USER_SHARED_BASE/_comfyui.tar.gz" \
    "$NETWORK_VOLUME" \
    "User ComfyUI config data"

# --- Step 5: Sync Custom Nodes ---
echo "� Syncing custom nodes..."
download_and_extract \
    "$S3_USER_SHARED_BASE/custom_nodes.tar.gz" \
    "$TENANT_COMFYUI_PATH" \
    "Custom nodes"

# Install dependencies for synced custom nodes
if [ -d "$TENANT_COMFYUI_PATH/custom_nodes" ]; then
    install_custom_node_deps "$TENANT_COMFYUI_PATH/custom_nodes"
fi

# --- Step 6: Sync Pod-Specific Data ---
echo "📂 Syncing pod-specific data..."
download_and_extract \
    "$S3_POD_BASE/comfyui_pod_specific_data.tar.gz" \
    "$TENANT_COMFYUI_PATH" \
    "Pod-specific ComfyUI data"

download_and_extract \
    "$S3_POD_BASE/other_pod_specific_data.tar.gz" \
    "$NETWORK_VOLUME" \
    "Pod-specific other data"

echo "🎯 Tenant workspace setup completed!"
echo "📊 Summary:"
echo "  ✅ Base ComfyUI copied from /base/ComfyUI"
echo "  � Virtual environment: /base/venv/comfyui (shared)"
echo "  � Workspace: $NETWORK_VOLUME"
echo "  🎨 ComfyUI: $TENANT_COMFYUI_PATH"
echo "  🔧 Activation: $NETWORK_VOLUME/activate-comfyui"