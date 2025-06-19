#!/bin/bash
set -eo pipefail # Ensures script exits on error and handles pipe failures

echo "=== ComfyUI Container Startup - $(date) ==="
echo "🔍 Starting ComfyUI Setup with S3 Integration..."
echo "Python Version: $(python3 --version)"

# Detect network volume location EARLY (before any background processes)
echo "🔧 Detecting network volume location..."
NETWORK_VOLUME=""
if [ -d "/runpod-volume" ]; then
    NETWORK_VOLUME="/runpod-volume"
    echo "Network volume detected at /runpod-volume"
elif mountpoint -q /workspace 2>/dev/null; then
    NETWORK_VOLUME="/workspace"
    echo "Network volume detected at /workspace (mounted)"
elif [ -f "/workspace/.runpod_volume" ] || [ -w "/workspace" ]; then # Check writability for /workspace as well
    NETWORK_VOLUME="/workspace"
    echo "Using /workspace as persistent storage"
else
    echo "❌ CRITICAL: No network volume detected or usable!"
    echo "This container requires persistent storage at /workspace or /runpod-volume."
    exit 1
fi

# Export NETWORK_VOLUME for all child processes
export NETWORK_VOLUME

# Enable comprehensive logging from the start (now that we have NETWORK_VOLUME)
STARTUP_LOG="$NETWORK_VOLUME/.startup.log"
# Create the log file and set permissions if it doesn't exist, to avoid tee issues if NETWORK_VOLUME was just formatted/is new
touch "$STARTUP_LOG"
chmod 664 "$STARTUP_LOG" # Or appropriate permissions

exec 1> >(tee -a "$STARTUP_LOG")
exec 2> >(tee -a "$STARTUP_LOG" >&2)

echo "----------------------------------------------------"
echo "Startup Log initiated: $STARTUP_LOG"
echo "Container ID (hostname): $(hostname)"
echo "User: $(whoami)"
echo "----------------------------------------------------"
echo "📁 Network Volume set to: $NETWORK_VOLUME"

# Start pod execution tracking early (now NETWORK_VOLUME is available)
echo "🕐 Starting pod execution tracking..."
# Ensure log directory for tracker exists if it writes its own separate log
mkdir -p "$(dirname "$NETWORK_VOLUME/.pod_tracker.log")"
nohup bash /scripts/pod_execution_tracker.sh > "$NETWORK_VOLUME/.pod_tracker.log" 2>&1 &
POD_TRACKER_PID=$!
echo "$POD_TRACKER_PID" > /tmp/pod_tracker.pid # Consider placing on $NETWORK_VOLUME if /tmp is too ephemeral for other scripts
echo "Pod tracker started with PID $POD_TRACKER_PID. Log: $NETWORK_VOLUME/.pod_tracker.log"


# Check FUSE filesystem availability
echo "🔧 Checking FUSE filesystem availability..."
if [ ! -c /dev/fuse ]; then
    echo "❌ CRITICAL: /dev/fuse device not found!"
    echo "FUSE filesystem is required for S3 mounting via rclone."
    echo "Container startup ABORTED due to missing FUSE support."
    exit 1
fi
echo "✅ /dev/fuse device found."

# Test FUSE functionality
echo "🧪 Testing FUSE functionality with rclone :memory: mount..."
test_mount_dir="/tmp/fuse_test_$(date +%s)" # Unique test dir
mkdir -p "$test_mount_dir"

# Increased timeout slightly, added --allow-other for some environments, though :memory: might not need it.
# Added --no-checksum --no-modtime for :memory: mount to speed it up.
if timeout 15 rclone mount :memory: "$test_mount_dir" --daemon --allow-non-empty --no-checksum --no-modtime --vfs-cache-mode off >/dev/null 2>&1; then
    sleep 2 # Give it a moment to actually mount
    if mountpoint -q "$test_mount_dir"; then
        echo "✅ FUSE mount test successful. Mount point accessible."
        fusermount -uz "$test_mount_dir" 2>/dev/null || umount -l "$test_mount_dir" 2>/dev/null || echo "⚠️ Note: Could not unmount FUSE test dir, but test passed."
    else
        echo "❌ FUSE mount test FAILED - mount point not accessible after rclone command succeeded."
        # Attempt to clean up even if mountpoint check failed
        fusermount -uz "$test_mount_dir" 2>/dev/null || umount -l "$test_mount_dir" 2>/dev/null || true
        rm -rf "$test_mount_dir"
        exit 1
    fi
else
    echo "❌ FUSE mount test FAILED - rclone command to mount :memory: failed."
    # Attempt to clean up
    rm -rf "$test_mount_dir" # rmdir might fail if mount partially happened
    exit 1
fi
rm -rf "$test_mount_dir"
echo "✅ FUSE filesystem test completed."

# Check GPU availability
echo "🔎 Checking GPU availability..."
if command -v nvidia-smi &> /dev/null; then
    echo "✅ NVIDIA GPU detected via nvidia-smi."
    export XPU_TARGET="NVIDIA_GPU"
    # Optional: Log GPU details
    # nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
elif [ -d "/dev/dri" ] && compgen -G "/dev/dri/renderD*" > /dev/null; then # Check for render nodes
    echo "✅ AMD/Intel GPU detected via /dev/dri/renderD*."
    # Further differentiation might be needed if both AMD and Intel iGPU exist.
    # For now, let's assume if renderD* exists, it's usable by ROCm or Intel tools.
    export XPU_TARGET="AMD_GPU" # Or "GPU" generally if specific AMD tools aren't guaranteed
else
    echo "ℹ️ No dedicated GPU (NVIDIA/AMD) detected. Using CPU."
    export XPU_TARGET="CPU"
fi
echo "🎯 XPU_TARGET set to: $XPU_TARGET"


# Setup S3 mounting with rclone (this also creates all sync scripts)
echo "🔧 Setting up S3 storage with rclone via /scripts/setup_rclone.sh..."
if ! bash /scripts/setup_rclone.sh; then # Assuming this script has its own error reporting
    echo "❌ CRITICAL: S3 storage setup failed (see output from setup_rclone.sh)."
    echo "Container startup ABORTED."
    exit 1
fi
echo "✅ S3 storage setup script completed."


# Update environment variables to use the mounted network volume paths
export COMFYUI_VENV="$NETWORK_VOLUME/venv/comfyui"
export JUPYTER_VENV="$NETWORK_VOLUME/venv/jupyter" # If Jupyter is used
export PATH="$COMFYUI_VENV/bin:$JUPYTER_VENV/bin:$PATH" # Add Jupyter only if JUPYTER_VENV is non-empty

echo "🐍 ComfyUI Venv path set to: $COMFYUI_VENV"
if [ -n "$JUPYTER_VENV" ]; then # Assuming JUPYTER_VENV might be optional
    echo "📊 Jupyter Venv path set to: $JUPYTER_VENV"
fi
echo "PATH updated."


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
echo "🚀 Starting background services via /scripts/start_background_services.sh..."
if [ -f /scripts/start_background_services.sh ]; then
    bash /scripts/start_background_services.sh # Assuming this script backgrounds its own processes and logs appropriately
    echo "✅ Background services script initiated."
else
    echo "ℹ️ No /scripts/start_background_services.sh found, skipping."
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
echo "🔧 Setting up all components via /scripts/setup_components.sh..."
if ! bash /scripts/setup_components.sh; then # Assuming this script has its own error reporting
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