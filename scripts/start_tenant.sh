#!/bin/bash
set -eo pipefail

echo "=== ComfyUI Tenant Startup - $(date) ==="
echo "🔍 Starting ComfyUI Setup for Tenant..."

mkdir -p "$NETWORK_VOLUME/tmp"

export TMPDIR=$NETWORK_VOLUME/tmp
# or on macOS:
export TMP=$NETWORK_VOLUME/tmp
export TEMP=$NETWORK_VOLUME/tmp
# Sync scripts from S3 to ensure we have the latest versions
echo "📥 Syncing latest scripts from S3..."
S3_ENVIRONMENT="${DEPLOYMENT_TARGET:-dev}"
S3_SCRIPTS_PREFIX="s3://viral-comm-api-ec2-deployments-dev/comfyui-ami/${S3_ENVIRONMENT}"

if command -v aws >/dev/null 2>&1; then
    echo "🔧 Syncing scripts from S3: $S3_SCRIPTS_PREFIX"
    
    # Create script directory if it doesn't exist
    mkdir -p /scripts
    
    # Sync all scripts from S3, overwriting existing ones
    if aws s3 sync "$S3_SCRIPTS_PREFIX/" "/scripts/" --delete --quiet 2>/dev/null; then
        echo "✅ Scripts synced successfully from S3"
        
        # Make scripts executable
        chmod +x /scripts/*.sh 2>/dev/null || true
        chmod +x /scripts/*.py 2>/dev/null || true
        
        echo "📊 Synced scripts:"
        ls -la /scripts/ | head -10
    else
        echo "⚠️ Warning: Failed to sync scripts from S3, continuing with existing scripts"
        echo "   This may indicate IAM permissions issues or network connectivity problems"
        echo "   Checking if local scripts exist..."
        
        if [ "$(ls -A /scripts/ 2>/dev/null)" ]; then
            echo "✅ Local scripts found, continuing with existing versions"
        else
            echo "❌ ERROR: No scripts available locally and S3 sync failed"
            echo "   Please check IAM permissions and S3 bucket access"
            exit 1
        fi
    fi
else
    echo "⚠️ Warning: AWS CLI not available, cannot sync scripts from S3"
    echo "   Continuing with existing scripts in /scripts/"
fi

# Tenant-specific environment validation
if [ -z "${POD_ID:-}" ] || [ -z "${POD_USER_NAME:-}" ] || [ -z "${COMFYUI_PORT:-}" ]; then
    echo "❌ ERROR: Required tenant environment variables not set:"
    echo "  POD_ID: ${POD_ID:-NOT_SET}"
    echo "  POD_USER_NAME: ${POD_USER_NAME:-NOT_SET}"
    echo "  COMFYUI_PORT: ${COMFYUI_PORT:-NOT_SET}"
    exit 1
fi

echo "🏷️ Tenant Information:"
echo "  Pod ID: $POD_ID"
echo "  User: $POD_USER_NAME"
echo "  Port: $COMFYUI_PORT"

# Set centralized virtual environment paths
export BASE_VENV_PATH="${BASE_VENV_PATH:-/base/venv/comfyui}"
export BASE_COMFYUI_PATH="${BASE_COMFYUI_PATH:-/base/ComfyUI}"
export TENANT_COMFYUI_PATH="$NETWORK_VOLUME/ComfyUI"

echo "📍 Virtual Environment Paths:"
echo "  Base venv: $BASE_VENV_PATH"
echo "  Base ComfyUI: $BASE_COMFYUI_PATH" 
echo "  Tenant ComfyUI: $TENANT_COMFYUI_PATH"

# Set default Python version and config root
export PYTHON_VERSION="${PYTHON_VERSION:-3.11}"
export PYTHON_CMD="${PYTHON_CMD:-python${PYTHON_VERSION}}"
export CONFIG_ROOT="${CONFIG_ROOT:-/root}"
echo "Python Version: $($PYTHON_CMD --version)"
echo "Config Root: $CONFIG_ROOT"

# Set default script directory
export SCRIPT_DIR="${SCRIPT_DIR:-/scripts}"
echo "📁 Using script directory: $SCRIPT_DIR"

# Validate NETWORK_VOLUME for tenant
if [ -z "${NETWORK_VOLUME:-}" ]; then
    echo "❌ ERROR: NETWORK_VOLUME not set for tenant"
    exit 1
fi

if [ ! -d "$NETWORK_VOLUME" ] || [ ! -w "$NETWORK_VOLUME" ]; then
    echo "❌ ERROR: NETWORK_VOLUME ($NETWORK_VOLUME) is not accessible"
    exit 1
fi

echo "📁 Network Volume: $NETWORK_VOLUME"

# Setup tenant-specific logging
TENANT_LOG_DIR="$NETWORK_VOLUME/logs"
mkdir -p "$TENANT_LOG_DIR"

USER_SCRIPT_LOG="$TENANT_LOG_DIR/user-script.log"
STARTUP_LOG="$TENANT_LOG_DIR/startup.log"
COMFYUI_LOG="$TENANT_LOG_DIR/comfyui.log"

touch "$USER_SCRIPT_LOG" "$STARTUP_LOG" "$COMFYUI_LOG"
chmod 664 "$USER_SCRIPT_LOG" "$STARTUP_LOG" "$COMFYUI_LOG" 2>/dev/null || true

# Set up logging redirection
exec 1> >(tee -a "$STARTUP_LOG")
exec 2> >(tee -a "$STARTUP_LOG" >&2)

echo "----------------------------------------------------"
echo "Tenant Startup Log initiated: $STARTUP_LOG"
echo "Container ID (hostname): $(hostname)"
echo "User: $(whoami)"
echo "Tenant: $POD_ID ($POD_USER_NAME)"
echo "----------------------------------------------------"

# Install user-specified APT packages if provided
if [ -n "${APT_PACKAGES:-}" ]; then
    echo "📦 Installing user-specified APT packages..." | tee -a "$USER_SCRIPT_LOG"
    echo "=== APT PACKAGE INSTALLATION START - $(date) ===" >> "$USER_SCRIPT_LOG"
    echo "Requested packages: $APT_PACKAGES" | tee -a "$USER_SCRIPT_LOG"
    
    # Convert comma-separated list to array
    IFS=',' read -ra APT_ARRAY <<< "$APT_PACKAGES"
    
    # Clean package names (remove spaces)
    CLEAN_APT_PACKAGES=()
    for pkg in "${APT_ARRAY[@]}"; do
        cleaned=$(echo "$pkg" | xargs)  # Remove leading/trailing spaces
        if [ -n "$cleaned" ]; then
            CLEAN_APT_PACKAGES+=("$cleaned")
        fi
    done
    
    if [ ${#CLEAN_APT_PACKAGES[@]} -gt 0 ]; then
        echo "Installing: ${CLEAN_APT_PACKAGES[*]}" | tee -a "$USER_SCRIPT_LOG"
        
        # Install packages (skip update in tenant to speed up)
        if dnf install -y --no-install-recommends "${CLEAN_APT_PACKAGES[@]}" >> "$USER_SCRIPT_LOG" 2>&1; then
            echo "✅ APT packages installed successfully: ${CLEAN_APT_PACKAGES[*]}" | tee -a "$USER_SCRIPT_LOG"
        else
            echo "❌ ERROR: Some APT packages failed to install. Check log for details." | tee -a "$USER_SCRIPT_LOG"
            echo "⚠️ Continuing with startup despite APT installation errors..." | tee -a "$USER_SCRIPT_LOG"
        fi
    else
        echo "⚠️ No valid APT packages found after cleaning" | tee -a "$USER_SCRIPT_LOG"
    fi
    echo "=== APT PACKAGE INSTALLATION END - $(date) ===" >> "$USER_SCRIPT_LOG"
    echo ""
else
    echo "ℹ️ No user-specified APT packages to install (APT_PACKAGES not set)" | tee -a "$USER_SCRIPT_LOG"
fi

# Create S3 interactor script if needed
echo "🔧 Setting up S3 interactor for tenant..."
if [ -f "$SCRIPT_DIR/create_s3_interactor.sh" ]; then
    if ! bash "$SCRIPT_DIR/create_s3_interactor.sh" "$NETWORK_VOLUME/scripts"; then
        echo "❌ CRITICAL: Failed to create S3 interactor for tenant."
        exit 1
    fi
    echo "  ✅ S3 interactor created/configured."
else
    echo "⚠️ WARNING: create_s3_interactor.sh not found in $SCRIPT_DIR"
fi

# Start pod execution tracking for tenant
echo "🕐 Starting pod execution tracking for tenant..."
mkdir -p "$(dirname "$TENANT_LOG_DIR/pod_tracker-${POD_ID}.log")"
nohup bash "$SCRIPT_DIR/pod_execution_tracker.sh" > "$TENANT_LOG_DIR/pod_tracker-${POD_ID}.log" 2>&1 &
POD_TRACKER_PID=$!
echo "$POD_TRACKER_PID" > "$NETWORK_VOLUME/tmp/pod_tracker_${POD_ID}.pid"
echo "Pod tracker started with PID $POD_TRACKER_PID. Log: $TENANT_LOG_DIR/pod_tracker-${POD_ID}.log"

# Check GPU availability
echo "🔎 Checking GPU availability..."
if command -v nvidia-smi &> /dev/null; then
    echo "✅ NVIDIA GPU detected via nvidia-smi."
    export XPU_TARGET="NVIDIA_GPU"
elif [ -d "/dev/dri" ] && compgen -G "/dev/dri/renderD*" > /dev/null; then
    echo "✅ AMD/Intel GPU detected via /dev/dri/renderD*."
    export XPU_TARGET="AMD_GPU"
else
    echo "ℹ️ No dedicated GPU (NVIDIA/AMD) detected. Using CPU."
    export XPU_TARGET="CPU"
fi
echo "🎯 XPU_TARGET set to: $XPU_TARGET"

# Setup S3 storage with AWS CLI
echo "🔧 Setting up S3 storage with AWS CLI via $SCRIPT_DIR/setup_rclone.sh..."
if ! bash "$SCRIPT_DIR/setup_rclone.sh"; then
    echo "❌ CRITICAL: S3 storage setup failed for tenant."
    echo "Container startup ABORTED."
    exit 1
fi
echo "✅ S3 storage setup script completed."

# Update environment variables to use the centralized base venv
export COMFYUI_VENV="$BASE_VENV_PATH"
export PATH="$COMFYUI_VENV/bin:$PATH"

# Verify that required scripts exist
echo "🔍 Verifying required scripts exist on $NETWORK_VOLUME/scripts/..."
required_scripts_on_volume=(
    "$NETWORK_VOLUME/scripts/sync_user_data.sh"
    "$NETWORK_VOLUME/scripts/graceful_shutdown.sh"
    "$NETWORK_VOLUME/scripts/sync_logs.sh"
)

missing_scripts=()
for script_path in "${required_scripts_on_volume[@]}"; do
    if [ ! -f "$script_path" ]; then
        missing_scripts+=("$script_path")
    fi
done

if [ ${#missing_scripts[@]} -gt 0 ]; then
    echo "❌ CRITICAL: Required scripts are missing from $NETWORK_VOLUME/scripts/:"
    for script_path_missing in "${missing_scripts[@]}"; do
        echo "  - $script_path_missing"
    done
    echo "This indicates script creation/copying failed during earlier setup stages."
    exit 1
fi
echo "✅ All required scripts on $NETWORK_VOLUME/scripts/ verified."

# Setup all components (ComfyUI, models, etc.)
echo "🔧 Setting up all components via $SCRIPT_DIR/setup_tenant_components.sh..."
if ! bash "$SCRIPT_DIR/setup_tenant_components.sh"; then
    echo "❌ CRITICAL: Component setup failed for tenant."
    exit 1
fi
echo "✅ All components setup script completed."

# Mark setup as complete for tracking
echo "🚩 Marking setup as complete by creating $NETWORK_VOLUME/.setup_complete"
touch "$NETWORK_VOLUME/.setup_complete"

# Start background services for tenant
echo "🚀 Starting background services via $SCRIPT_DIR/start_background_services.sh..."
if [ -f "$SCRIPT_DIR/start_background_services.sh" ]; then
    bash "$SCRIPT_DIR/start_background_services.sh"
    echo "✅ Background services script initiated."
else
    echo "ℹ️ No $SCRIPT_DIR/start_background_services.sh found, skipping."
fi

# Create tenant-specific ComfyUI startup script
echo "🔧 Creating tenant-specific ComfyUI startup script..."
cat > "$NETWORK_VOLUME/start_comfyui_tenant.sh" << 'EOF'
#!/bin/bash
# Tenant-specific ComfyUI startup script

set -eo pipefail

echo "🚀 Starting ComfyUI for tenant $POD_ID on port $COMFYUI_PORT..."

# Detect GPU availability and configure accordingly
echo "🔍 Detecting GPU availability..."
HAS_GPU=false
GPU_VENDOR="none"

# Check for NVIDIA GPU
if command -v nvidia-smi >/dev/null 2>&1; then
    if nvidia-smi >/dev/null 2>&1; then
        echo "✅ NVIDIA GPU detected"
        HAS_GPU=true
        GPU_VENDOR="nvidia"
    else
        echo "⚠️ nvidia-smi found but not working properly"
    fi
else
    echo "ℹ️ nvidia-smi not found"
fi

# Check with PyTorch (works for NVIDIA and AMD/ROCm)
source "$COMFYUI_VENV/bin/activate"
if python -c "import torch; print(torch.cuda.is_available())" 2>/dev/null | grep -q "True"; then
    echo "✅ PyTorch GPU support detected"
    HAS_GPU=true

    BACKEND=$(python -c "import torch; print('hip' if torch.version.hip else 'cuda')" 2>/dev/null)
    if [ "$BACKEND" = "hip" ]; then
        GPU_VENDOR="amd"
        echo "🟥 ROCm (AMD GPU) detected"
    else
        GPU_VENDOR="nvidia"
        echo "🟦 CUDA (NVIDIA GPU) detected"
    fi
else
    echo "⚠️ PyTorch reports no GPU support"
    HAS_GPU=false
    GPU_VENDOR="none"
fi
deactivate

# Configure environment based on GPU availability
if [ "$HAS_GPU" = false ]; then
    echo "🖥️ Configuring for CPU-only mode..."
    export CUDA_VISIBLE_DEVICES=""
    export FORCE_CUDA="0"
    export PYTORCH_CUDA_ALLOC_CONF=""
    export COMFYUI_CPU_ONLY="1"
    DEVICE_ARGS="--cpu --force-fp16"
else
    echo "🚀 Configuring for GPU mode ($GPU_VENDOR)..."
    export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"
    DEVICE_ARGS=""
fi

# Activate virtual environment again
source "$COMFYUI_VENV/bin/activate"

# Change to ComfyUI directory
cd "$NETWORK_VOLUME/ComfyUI"

# Start ComfyUI with tenant-specific configuration
export PYTORCH_ENABLE_INDUCTOR=0
echo "🎯 Starting ComfyUI with device args: $DEVICE_ARGS"
exec xvfb-run --auto-servernum --server-args="-screen 0 1920x1080x24" python main.py \
    --listen 0.0.0.0 \
    --port "$COMFYUI_PORT" \
    --enable-cors-header "*" \
    $DEVICE_ARGS \
    2>&1 | tee -a "$COMFYUI_LOG"
EOF

chmod +x "$NETWORK_VOLUME/start_comfyui_tenant.sh"

echo "🚀🚀🚀 Executing tenant ComfyUI: $NETWORK_VOLUME/start_comfyui_tenant.sh 🚀🚀🚀"
exec "$NETWORK_VOLUME/start_comfyui_tenant.sh"
