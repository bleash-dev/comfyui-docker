#!/bin/bash
set -eo pipefail

echo "=== ComfyUI Container Startup - $(date) ==="
echo "🔍 Starting ComfyUI Setup with S3 Integration..."

# Set default Python version and config root
export 
export PYTHON_VERSION="${PYTHON_VERSION:-3.10}"
export PYTHON_CMD="${PYTHON_CMD:-python${PYTHON_VERSION}}"
export CONFIG_ROOT="${CONFIG_ROOT:-/root}"
echo "Python Version: $($PYTHON_CMD --version)"
echo "Config Root: $CONFIG_ROOT"

# Set default script directory
export SCRIPT_DIR="${SCRIPT_DIR:-/scripts}"
echo "📁 Using script directory: $SCRIPT_DIR"

# Setup user script logging
USER_SCRIPT_LOG="$NETWORK_VOLUME/.user-script-logs.log"
mkdir -p "$(dirname "$USER_SCRIPT_LOG")"
touch "$USER_SCRIPT_LOG"
chmod 664 "$USER_SCRIPT_LOG" 2>/dev/null || true

# Install user-specified APT packages early (before everything else)
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
        
        # Update package list
        echo "Updating APT package list..." | tee -a "$USER_SCRIPT_LOG"
        if apt-get update -qq >> "$USER_SCRIPT_LOG" 2>&1; then
            echo "✅ APT package list updated successfully" | tee -a "$USER_SCRIPT_LOG"
        else
            echo "⚠️ WARNING: APT package list update failed, proceeding anyway" | tee -a "$USER_SCRIPT_LOG"
        fi
        
        # Install packages
        echo "Installing APT packages..." | tee -a "$USER_SCRIPT_LOG"
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

# Detect network volume location EARLY - only if NETWORK_VOLUME is not already set
if [ -z "$NETWORK_VOLUME" ]; then
    echo "🔧 Detecting network volume location..."
    if [ -d "/runpod-volume" ]; then
        NETWORK_VOLUME="/runpod-volume"
        echo "Network volume detected at /runpod-volume"
    elif mountpoint -q /workspace 2>/dev/null; then
        NETWORK_VOLUME="/workspace"
        echo "Network volume detected at /workspace (mounted)"
    elif [ -f "/workspace/.runpod_volume" ] || [ -w "/workspace" ]; then
        NETWORK_VOLUME="/workspace"
        echo "Using /workspace as persistent storage"
    else
        echo "❌ CRITICAL: No network volume detected or usable!"
        echo "This container requires persistent storage at /workspace or /runpod-volume."
        exit 1
    fi
else
    echo "📁 Using pre-configured NETWORK_VOLUME: $NETWORK_VOLUME"
fi

# Export NETWORK_VOLUME for all child processes
export NETWORK_VOLUME

# Enable comprehensive logging
STARTUP_LOG="$NETWORK_VOLUME/.startup.log"

# Ensure the startup log file exists and is writable
if ! touch "$STARTUP_LOG" 2>/dev/null; then
    echo "⚠️ WARNING: Could not create startup log at $STARTUP_LOG, using fallback"
    STARTUP_LOG="/tmp/startup_fallback.log"
    touch "$STARTUP_LOG"
fi
chmod 664 "$STARTUP_LOG" 2>/dev/null || true

# Set up logging redirection only if STARTUP_LOG is valid
if [ -n "$STARTUP_LOG" ] && [ -f "$STARTUP_LOG" ]; then
    exec 1> >(tee -a "$STARTUP_LOG")
    exec 2> >(tee -a "$STARTUP_LOG" >&2)
else
    echo "⚠️ WARNING: Startup log setup failed, continuing without file logging"
fi

echo "----------------------------------------------------"
echo "Startup Log initiated: $STARTUP_LOG"
echo "Container ID (hostname): $(hostname)"
echo "User: $(whoami)"
echo "----------------------------------------------------"
echo "📁 Network Volume set to: $NETWORK_VOLUME"

# Start pod execution tracking early
echo "🕐 Starting pod execution tracking..."
mkdir -p "$(dirname "$NETWORK_VOLUME/.pod_tracker.log")"
nohup bash "$SCRIPT_DIR/pod_execution_tracker.sh" > "$NETWORK_VOLUME/.pod_tracker.log" 2>&1 &
POD_TRACKER_PID=$!
echo "$POD_TRACKER_PID" > /tmp/pod_tracker.pid
echo "Pod tracker started with PID $POD_TRACKER_PID. Log: $NETWORK_VOLUME/.pod_tracker.log"


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
    echo "❌ CRITICAL: S3 storage setup failed (see output from setup_rclone.sh)."
    echo "Container startup ABORTED."
    exit 1
fi
echo "✅ S3 storage setup script completed."


# Update environment variables to use the mounted network volume paths
export COMFYUI_VENV="$NETWORK_VOLUME/venv/comfyui"
export PATH="$COMFYUI_VENV/bin:$PATH"


# Verify that required scripts were created by setup_rclone.sh (or other setup steps)
echo "🔍 Verifying required scripts exist on $NETWORK_VOLUME/scripts/..."
required_scripts_on_volume=(
    "$NETWORK_VOLUME/scripts/sync_user_data.sh"
    "$NETWORK_VOLUME/scripts/graceful_shutdown.sh"
    # "$NETWORK_VOLUME/scripts/signal_handler.sh" # Often part of graceful_shutdown or the main app
    "$NETWORK_VOLUME/scripts/sync_logs.sh" # If used by background services
    "$NETWORK_VOLUME/start_comfyui_with_logs.sh" # This one is exec'd
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


# Start background services (using script from /scripts/ baked into image)
echo "🚀 Starting background services via $SCRIPT_DIR/start_background_services.sh..."
if [ -f "$SCRIPT_DIR/start_background_services.sh" ]; then
    bash "$SCRIPT_DIR/start_background_services.sh" # Assuming this script backgrounds its own processes and logs appropriately
    echo "✅ Background services script initiated."
else
    echo "ℹ️ No $SCRIPT_DIR/start_background_services.sh found, skipping."
fi


# Install runtime dependencies if needed
echo "📦 Checking for runtime dependencies (jq, bc)..."
missing_deps=()
command -v jq >/dev/null 2>&1 || missing_deps+=("jq")
command -v bc >/dev/null 2>&1 || missing_deps+=("bc")

if [ ${#missing_deps[@]} -gt 0 ]; then
    echo "  Dependencies to install: ${missing_deps[*]}"
    # Be cautious with apt-get update if running frequently or in constrained networks
    if apt-get update -qq && apt-get install -y -qq --no-install-recommends "${missing_deps[@]}"; then
        echo "  ✅ Successfully installed: ${missing_deps[*]}"
    else
        echo "  ⚠️ WARNING: Failed to install some runtime dependencies (${missing_deps[*]})."
        echo "     Functionality requiring these tools may be impaired."
        # Decide if this is fatal or just a warning. For now, a warning.
    fi
else
    echo "  ✅ jq and bc are already installed."
fi


# Setup all components (ComfyUI, models, etc.) via image script
echo "🔧 Setting up all components via $SCRIPT_DIR/setup_components.sh..."
if ! bash "$SCRIPT_DIR/setup_components.sh"; then # Assuming this script has its own error reporting
    echo "❌ CRITICAL: Component setup failed (see output from setup_components.sh)."
    exit 1
fi
echo "✅ All components setup script completed."


# Mark setup as complete for tracking
echo "🚩 Marking setup as complete by creating $NETWORK_VOLUME/.setup_complete"
touch "$NETWORK_VOLUME/.setup_complete"


# Final sync and start ComfyUI
echo "🔄 Performing final user data sync via $NETWORK_VOLUME/scripts/sync_user_data.sh..."
if ! "$NETWORK_VOLUME/scripts/sync_user_data.sh"; then
    echo "⚠️ WARNING: Final user data sync encountered issues. Proceeding to start ComfyUI..."
    # Not exiting here, as ComfyUI might still start with partial data or defaults.
fi
echo "✅ Final user data sync completed."

echo "🚀🚀🚀 Executing main application: $NETWORK_VOLUME/start_comfyui_with_logs.sh 🚀🚀🚀"
exec "$NETWORK_VOLUME/start_comfyui_with_logs.sh" # This replaces the current script process