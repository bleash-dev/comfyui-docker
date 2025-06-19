#!/bin/bash

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
elif [ -f "/workspace/.runpod_volume" ] || [ -w "/workspace" ]; then
    NETWORK_VOLUME="/workspace"
    echo "Using /workspace as persistent storage"
else
    echo "❌ No network volume detected! This container requires persistent storage."
    echo "Please ensure you have mounted a network volume at /workspace or /runpod-volume"
    exit 1
fi

# Export NETWORK_VOLUME for all child processes
export NETWORK_VOLUME

# Enable comprehensive logging from the start (now that we have NETWORK_VOLUME)
STARTUP_LOG="$NETWORK_VOLUME/.startup.log"
exec 1> >(tee -a "$STARTUP_LOG")
exec 2> >(tee -a "$STARTUP_LOG" >&2)

echo "📁 Network Volume: $NETWORK_VOLUME"

# Start pod execution tracking early (now NETWORK_VOLUME is available)
echo "🕐 Starting pod execution tracking..."
nohup bash /scripts/pod_execution_tracker.sh > $NETWORK_VOLUME/.pod_tracker.log 2>&1 &
POD_TRACKER_PID=$!
echo "$POD_TRACKER_PID" > /tmp/pod_tracker.pid

# Check FUSE filesystem availability
echo "🔧 Checking FUSE filesystem availability..."
if [ ! -c /dev/fuse ]; then
    echo "❌ CRITICAL: /dev/fuse device not found!"
    echo "FUSE filesystem is required for S3 mounting via rclone."
    echo "Container startup ABORTED due to missing FUSE support."
    exit 1
fi

# Test FUSE functionality
echo "🧪 Testing FUSE functionality..."
test_mount_dir="/tmp/fuse_test"
mkdir -p "$test_mount_dir"

if timeout 10 rclone mount :memory: "$test_mount_dir" --daemon 2>/dev/null; then
    sleep 2
    if mountpoint -q "$test_mount_dir" 2>/dev/null; then
        echo "✅ FUSE filesystem is working properly"
        fusermount -u "$test_mount_dir" 2>/dev/null || umount "$test_mount_dir" 2>/dev/null
    else
        echo "❌ FUSE mount test failed - mount point not accessible"
        exit 1
    fi
else
    echo "❌ FUSE mount test failed - rclone cannot create FUSE mounts"
    exit 1
fi

rm -rf "$test_mount_dir"
echo "✅ FUSE filesystem test completed successfully"

# Check GPU availability
if command -v nvidia-smi &> /dev/null; then
    echo "NVIDIA GPU detected"
    export XPU_TARGET=NVIDIA_GPU
elif [ -d "/dev/dri" ]; then
    echo "AMD GPU detected"
    export XPU_TARGET=AMD_GPU
else
    echo "No GPU detected, using CPU"
    export XPU_TARGET=CPU
fi

# Setup S3 mounting with rclone (this also creates all sync scripts)
echo "🔧 Setting up S3 storage with rclone..."
if ! bash /scripts/setup_rclone.sh; then
    echo "❌ CRITICAL: S3 storage setup failed!"
    echo "Container startup ABORTED."
    exit 1
fi

# Update environment variables to use the mounted network volume paths
export COMFYUI_VENV="$NETWORK_VOLUME/venv/comfyui"
export JUPYTER_VENV="$NETWORK_VOLUME/venv/jupyter"
export PATH="$COMFYUI_VENV/bin:$JUPYTER_VENV/bin:$PATH"

echo "✅ S3 storage mounted successfully"
echo "🐍 ComfyUI Venv: $COMFYUI_VENV"
echo "📊 Jupyter Venv: $JUPYTER_VENV"

# Verify that required scripts were created before starting background services
echo "🔍 Verifying required scripts exist..."
required_scripts=(
    "$NETWORK_VOLUME/scripts/sync_user_data.sh"
    "$NETWORK_VOLUME/scripts/graceful_shutdown.sh"
    "$NETWORK_VOLUME/scripts/signal_handler.sh"
    "$NETWORK_VOLUME/scripts/sync_logs.sh"
)

missing_scripts=()
for script in "${required_scripts[@]}"; do
    if [ ! -f "$script" ]; then
        missing_scripts+=("$script")
    fi
done

if [ ${#missing_scripts[@]} -gt 0 ]; then
    echo "❌ CRITICAL: Required scripts are missing:"
    for script in "${missing_scripts[@]}"; do
        echo "  - $script"
    done
    echo "This indicates script creation failed in setup_rclone.sh"
    exit 1
fi

echo "✅ All required scripts verified"

# Start background services (using script from /scripts/)
echo "🚀 Starting background services..."
bash /scripts/start_background_services.sh

# Install runtime dependencies if needed
if ! command -v jq >/dev/null 2>&1; then
    echo "📦 Installing jq for JSON processing..."
    apt-get update && apt-get install -y jq bc 2>/dev/null || true
fi

# Setup all components
echo "🔧 Setting up all components..."
bash /scripts/setup_components.sh

echo "✅ All components setup complete"

# Mark setup as complete for tracking
touch "$NETWORK_VOLUME/.setup_complete"

# Final sync and start ComfyUI
echo "🔄 Performing final sync and starting ComfyUI..."
$NETWORK_VOLUME/scripts/sync_user_data.sh
exec "$NETWORK_VOLUME/start_comfyui_with_logs.sh"