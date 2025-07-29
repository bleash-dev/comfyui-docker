#!/bin/bash
set -eo pipefail

echo "=== ComfyUI Tenant Startup - $(date) ==="
echo "🔍 Starting ComfyUI Setup for Tenant..."

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

# Set default Python version and config root
export PYTHON_VERSION="${PYTHON_VERSION:-3.10}"
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

# Check for additional network volume optimization (_NETWORK_VOLUME)
if [ -n "${_NETWORK_VOLUME:-}" ]; then
    if [ -d "$_NETWORK_VOLUME" ] && [ -w "$_NETWORK_VOLUME" ]; then
        echo "🔗 Additional network volume detected at $_NETWORK_VOLUME for shared data optimization"
        export _NETWORK_VOLUME
    else
        echo "⚠️ WARNING: _NETWORK_VOLUME set to $_NETWORK_VOLUME but path is not accessible, disabling optimization"
        unset _NETWORK_VOLUME
    fi
else
    echo "📁 No additional network volume configured for shared data optimization"
fi

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
        if apt-get install -y --no-install-recommends "${CLEAN_APT_PACKAGES[@]}" >> "$USER_SCRIPT_LOG" 2>&1; then
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
echo "$POD_TRACKER_PID" > "/tmp/pod_tracker_${POD_ID}.pid"
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

# Update environment variables to use the tenant network volume paths
export COMFYUI_VENV="$NETWORK_VOLUME/venv/comfyui"
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
echo "🔧 Setting up all components via $SCRIPT_DIR/setup_components.sh..."
if ! bash "$SCRIPT_DIR/setup_components.sh"; then
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
cat > "$NETWORK_VOLUME/start_comfyui_tenant.sh" << EOF
#!/bin/bash
# Tenant-specific ComfyUI startup script

set -eo pipefail

echo "🚀 Starting ComfyUI for tenant $POD_ID on port $COMFYUI_PORT..."

# Activate virtual environment
source "$COMFYUI_VENV/bin/activate"

# Change to ComfyUI directory
cd "$NETWORK_VOLUME/ComfyUI"

# Start ComfyUI with tenant-specific configuration
exec python main.py \\
    --listen 0.0.0.0 \\
    --port $COMFYUI_PORT \\
    --enable-cors-header \\
    --output-directory "$NETWORK_VOLUME/ComfyUI/output" \\
    --input-directory "$NETWORK_VOLUME/ComfyUI/input" \\
    --extra-model-paths-config "$NETWORK_VOLUME/ComfyUI/extra_model_paths.yaml" \\
    2>&1 | tee -a "$COMFYUI_LOG"
EOF

chmod +x "$NETWORK_VOLUME/start_comfyui_tenant.sh"

echo "🚀🚀🚀 Executing tenant ComfyUI: $NETWORK_VOLUME/start_comfyui_tenant.sh 🚀🚀🚀"
exec "$NETWORK_VOLUME/start_comfyui_tenant.sh"
