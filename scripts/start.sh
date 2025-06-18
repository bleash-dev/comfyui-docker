#!/bin/bash

# Enable comprehensive logging from the start
STARTUP_LOG="$NETWORK_VOLUME/.startup.log"
exec 1> >(tee -a "$STARTUP_LOG")
exec 2> >(tee -a "$STARTUP_LOG" >&2)

echo "=== ComfyUI Container Startup - $(date) ==="

echo "🔍 Starting ComfyUI Setup with S3 Integration..."
echo "Python Version: $(python3 --version)"

# Check FUSE filesystem availability FIRST
echo "🔧 Checking FUSE filesystem availability..."
if [ ! -c /dev/fuse ]; then
    echo "❌ CRITICAL: /dev/fuse device not found!"
    echo "FUSE filesystem is required for S3 mounting via rclone."
    echo ""
    echo "Possible solutions:"
    echo "1. Run container with --privileged flag"
    echo "2. Add device mapping: --device /dev/fuse"
    echo "3. Add capability: --cap-add SYS_ADMIN"
    echo "4. For RunPod: Contact support to enable FUSE on your pod"
    echo ""
    echo "Container startup ABORTED due to missing FUSE support."
    exit 1
fi

# Test FUSE by creating a simple mount
echo "🧪 Testing FUSE functionality..."
test_mount_dir="/tmp/fuse_test"
mkdir -p "$test_mount_dir"

# Try to mount a simple test filesystem using rclone
if timeout 10 rclone mount :memory: "$test_mount_dir" --daemon 2>/dev/null; then
    sleep 2
    if mountpoint -q "$test_mount_dir" 2>/dev/null; then
        echo "✅ FUSE filesystem is working properly"
        fusermount -u "$test_mount_dir" 2>/dev/null || umount "$test_mount_dir" 2>/dev/null
    else
        echo "❌ FUSE mount test failed - mount point not accessible"
        echo "This may indicate insufficient privileges for FUSE operations."
        exit 1
    fi
else
    echo "❌ FUSE mount test failed - rclone cannot create FUSE mounts"
    echo "This may indicate missing FUSE kernel modules or insufficient privileges."
    exit 1
fi

rm -rf "$test_mount_dir"
echo "✅ FUSE filesystem test completed successfully"

# Check GPU availability
if command -v nvidia-smi &> /dev/null; then
    echo "NVIDIA GPU detected"
    echo "CUDA Version: $(nvcc --version 2>/dev/null || echo 'NVCC not found')"
    echo "GPU Information: $(nvidia-smi)"
    export XPU_TARGET=NVIDIA_GPU
elif [ -d "/dev/dri" ]; then
    echo "AMD GPU detected"
    export XPU_TARGET=AMD_GPU
else
    echo "No GPU detected, using CPU"
    export XPU_TARGET=CPU
fi

# Setup S3 mounting with rclone FIRST - before anything else
echo "🔧 Setting up S3 storage with rclone..."
if ! bash /scripts/setup_rclone.sh; then
    echo "❌ CRITICAL: S3 storage setup failed!"
    echo ""
    echo "This could be due to:"
    echo "  1. Missing or invalid AWS credentials"
    echo "  2. Network connectivity issues"
    echo "  3. S3 bucket permissions"
    echo "  5. Failed mounts for existing data"
    echo ""
    echo "For data integrity, the container will not start without proper S3 setup."
    echo "Please check your environment variables and S3 configuration."
    echo ""
    echo "Required environment variables:"
    echo "  - AWS_BUCKET_NAME"
    echo "  - AWS_ACCESS_KEY_ID" 
    echo "  - AWS_SECRET_ACCESS_KEY"
    echo "  - AWS_REGION"
    echo "  - POD_USER_NAME"
    echo ""
    echo "Container startup ABORTED."
    exit 1
fi

# Wait for mounts to stabilize
sleep 3

# Now update environment variables to use the mounted/detected network volume paths
export COMFYUI_VENV="$NETWORK_VOLUME/venv/comfyui"
export JUPYTER_VENV="$NETWORK_VOLUME/venv/jupyter"
export PATH="$COMFYUI_VENV/bin:$JUPYTER_VENV/bin:$PATH"

echo "✅ S3 storage mounted successfully"
echo "📁 Network Volume: $NETWORK_VOLUME"
echo "🐍 ComfyUI Venv: $COMFYUI_VENV"
echo "📊 Jupyter Venv: $JUPYTER_VENV"

# Setup periodic sync system (after mounts are ready)
echo "⏰ Setting up periodic sync system..."
bash $NETWORK_VOLUME/scripts/setup_periodic_sync.sh

# Start sync daemon in background
echo "🔄 Starting sync daemon..."
nohup $NETWORK_VOLUME/scripts/sync_daemon.sh > $NETWORK_VOLUME/.sync_daemon.log 2>&1 &

# Start new folder detection daemon
echo "🔍 Starting folder detection daemon..."
nohup bash -c 'while true; do '$NETWORK_VOLUME'/scripts/sync_new_folders.sh; sleep 300; done' > $NETWORK_VOLUME/.folder_detection.log 2>&1 &

# Start signal handler for graceful shutdown
echo "📢 Starting signal handler..."
nohup $NETWORK_VOLUME/scripts/signal_handler.sh > $NETWORK_VOLUME/.signal_handler.log 2>&1 &

# Start log monitoring and error detection
echo "📊 Starting log monitoring systems..."
nohup $NETWORK_VOLUME/scripts/log_monitor.sh > $NETWORK_VOLUME/.log_monitor.log 2>&1 &
nohup $NETWORK_VOLUME/scripts/error_detector.sh > $NETWORK_VOLUME/.error_detector.log 2>&1 &

# Start custom node monitoring (NEW)
echo "📦 Starting custom node monitoring..."
nohup $NETWORK_VOLUME/scripts/monitor_custom_nodes.sh > $NETWORK_VOLUME/.custom_node_monitor.log 2>&1 &
nohup $NETWORK_VOLUME/scripts/intercept_manager_logs.sh > $NETWORK_VOLUME/.manager_interceptor.log 2>&1 &

# Install inotify-tools for better file monitoring
if ! command -v inotifywait >/dev/null 2>&1; then
    echo "📦 Installing inotify-tools for file monitoring..."
    apt-get update && apt-get install -y inotify-tools 2>/dev/null || true
fi

# Initial log sync to capture startup
echo "📤 Performing initial log sync..."
$NETWORK_VOLUME/scripts/sync_logs.sh

# Function to safely create symlink
create_symlink() {
    local src="$1"
    local dst="$2"
    
    if [ -L "$dst" ]; then
        rm "$dst"
    elif [ -d "$dst" ] || [ -f "$dst" ]; then
        rm -rf "$dst"
    fi

    if [ -d "$src" ] || [ -f "$src" ]; then
        ln -sf "$src" "$dst"
        echo "✅ Created symlink: $dst -> $src"
    else
        echo "❌ Source $src not found"
    fi
}

# Function to setup virtual environments
setup_virtual_environments() {
    # Check if virtual environments already exist (from mounted storage)
    if [ ! -d "$COMFYUI_VENV" ]; then
        echo "Creating ComfyUI virtual environment..."
        mkdir -p "$(dirname "$COMFYUI_VENV")"
        python${PYTHON_VERSION:-3.10} -m venv "$COMFYUI_VENV"
        echo "✅ ComfyUI virtual environment created"
    else
        echo "✅ Using existing ComfyUI virtual environment from mounted storage"
    fi
    
    if [ ! -d "$JUPYTER_VENV" ]; then
        echo "Creating Jupyter virtual environment..."
        mkdir -p "$(dirname "$JUPYTER_VENV")"
        python${PYTHON_VERSION:-3.10} -m venv "$JUPYTER_VENV"
        echo "✅ Jupyter virtual environment created"
    else
        echo "✅ Using existing Jupyter virtual environment from mounted storage"
    fi
}

# Function to setup Jupyter installation
setup_jupyter_installation() {
    if ! "$JUPYTER_VENV/bin/python" -c "import jupyterlab" 2>/dev/null; then
        echo "Installing JupyterLab..."
        . "$JUPYTER_VENV/bin/activate"
        pip install --no-cache-dir jupyterlab notebook numpy pandas
        deactivate
        echo "✅ JupyterLab installed"
    else
        echo "✅ Using existing JupyterLab installation from mounted storage"
    fi
}

# Function to setup jupyter config persistence
setup_persistent_jupyter() {
    local network_jupyter_dir="$NETWORK_VOLUME/.jupyter"
    local local_jupyter_dir="/root/.jupyter"
    
    if [ ! -d "$network_jupyter_dir" ]; then
        echo "Setting up Jupyter config..."
        mkdir -p "$network_jupyter_dir"
        
        . $JUPYTER_VENV/bin/activate
        jupyter notebook --generate-config --config-dir="$network_jupyter_dir"
        
        cat > "$network_jupyter_dir/jupyter_notebook_config.py" << 'EOF'
c.NotebookApp.token = ''
c.NotebookApp.password = ''
c.NotebookApp.allow_origin = '*'
c.NotebookApp.allow_remote_access = True
c.NotebookApp.ip = '0.0.0.0'
c.NotebookApp.port = 8888
c.NotebookApp.open_browser = False
c.NotebookApp.allow_root = True

c.ServerApp.token = ''
c.ServerApp.password = ''
c.ServerApp.allow_origin = '*'
c.ServerApp.allow_remote_access = True
c.ServerApp.ip = '0.0.0.0'
c.ServerApp.port = 8888
c.ServerApp.open_browser = False
c.ServerApp.allow_root = True
EOF
        echo "✅ Jupyter configuration created"
        deactivate
    else
        echo "✅ Using existing Jupyter config from mounted storage"
    fi
    
    rm -rf "$local_jupyter_dir"
    create_symlink "$network_jupyter_dir" "$local_jupyter_dir"
}

# Function to setup ComfyUI user data persistence
setup_persistent_comfyui_data() {
    local network_comfyui_config="$NETWORK_VOLUME/.comfyui"
    local local_comfyui_config="/root/.comfyui"
    
    if [ ! -d "$network_comfyui_config" ]; then
        echo "Setting up ComfyUI config..."
        mkdir -p "$network_comfyui_config"
        echo "✅ ComfyUI configuration directory created"
    else
        echo "✅ Using existing ComfyUI config from mounted storage"
    fi
    
    rm -rf "$local_comfyui_config"
    create_symlink "$network_comfyui_config" "$local_comfyui_config"
}

# Function to setup ComfyUI installation
setup_comfyui_installation() {
    local comfyui_dir="$NETWORK_VOLUME/ComfyUI"
    
    echo "📝 Setting up ComfyUI with logging..." >> "$STARTUP_LOG"
    
    # Check if ComfyUI already exists (could be from mounted storage or previous install)
    if [ -d "$comfyui_dir" ] && [ -f "$comfyui_dir/main.py" ] && [ -s "$comfyui_dir/main.py" ]; then
        echo "✅ Using existing ComfyUI installation from mounted storage"
        
        # Check if we need to install/update requirements (only if venv is new or incomplete)
        cd "$comfyui_dir"
        . $COMFYUI_VENV/bin/activate
        
        # Quick check if essential packages are installed
        if ! python -c "import torch, torchvision" 2>/dev/null; then
            echo "📦 Installing/updating ComfyUI requirements..."
            if [ -f "requirements.txt" ]; then
                pip install --no-cache-dir -r requirements.txt
            fi
            pip install --no-cache-dir torch==${PYTORCH_VERSION:-2.4.0} torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
            echo "✅ ComfyUI requirements updated"
        else
            echo "✅ ComfyUI requirements already satisfied"
        fi
        
        deactivate
        return
    fi
    
    # ComfyUI doesn't exist or is incomplete, install it
    echo "Installing ComfyUI locally..."
    
    # Remove incomplete installation if it exists
    if [ -d "$comfyui_dir" ]; then
        echo "⚠️ Removing incomplete ComfyUI installation"
        rm -rf "$comfyui_dir"
    fi
    
    . $COMFYUI_VENV/bin/activate
    git clone https://github.com/comfyanonymous/ComfyUI "$comfyui_dir"
    cd "$comfyui_dir"
    
    if [ "${COMFYUI_VERSION:-master}" != "master" ]; then
        git checkout "${COMFYUI_VERSION}"
    fi
    
    pip install --no-cache-dir -r requirements.txt
    pip install --no-cache-dir torch==${PYTORCH_VERSION:-2.4.0} torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
    
    deactivate
    echo "✅ ComfyUI installed locally"
}

# Function to setup ComfyUI Manager
setup_comfyui_manager() {
    echo "📝 Setting up ComfyUI Manager with logging..." >> "$STARTUP_LOG"
    
    local manager_dir="$NETWORK_VOLUME/ComfyUI/custom_nodes/ComfyUI-Manager"
    
    # Check if ComfyUI-Manager already exists (could be from mounted shared custom_nodes)
    if [ -d "$manager_dir" ] && [ -f "$manager_dir/__init__.py" ]; then
        echo "✅ ComfyUI Manager already exists (from mounted storage)"
        
        # Check if requirements are satisfied in current venv
        . $COMFYUI_VENV/bin/activate
        if [ -f "$manager_dir/requirements.txt" ]; then
            # Try to import a common package from manager requirements
            if ! python -c "import git" 2>/dev/null; then
                echo "📦 Installing ComfyUI Manager requirements in current venv..."
                pip install --no-cache-dir -r "$manager_dir/requirements.txt"
            fi
        fi
        deactivate
        return
    fi
    
    # Install ComfyUI Manager
    echo "Installing ComfyUI Manager..."
    . $COMFYUI_VENV/bin/activate
    cd "$NETWORK_VOLUME/ComfyUI/custom_nodes"
    git clone https://github.com/ltdrdata/ComfyUI-Manager.git
    
    if [ -f "ComfyUI-Manager/requirements.txt" ]; then
        pip install --no-cache-dir -r ComfyUI-Manager/requirements.txt
    fi
    
    deactivate
    echo "✅ ComfyUI Manager installed"
}

# Function to setup download tools
setup_download_tools() {
    echo "Setting up download tools..."
    
    # Check if download tools are already installed in venv
    . $COMFYUI_VENV/bin/activate
    
    # Check if gdown and huggingface_hub are already installed
    if ! python -c "import gdown, huggingface_hub" 2>/dev/null; then
        echo "📦 Installing download tools..."
        pip install --no-cache-dir gdown "huggingface_hub[cli]"
    else
        echo "✅ Download tools already installed"
    fi
    
    # Login to HuggingFace if token is available
    if [ -n "$HF_TOKEN" ]; then
        huggingface-cli login --token $HF_TOKEN --add-to-git-credential
    fi
    deactivate
    
    # Create download scripts directory if it doesn't exist
    if [ ! -d "$NETWORK_VOLUME/scripts" ]; then
        mkdir -p "$NETWORK_VOLUME/scripts"
        
        # Create Google Drive download script
        cat > "$NETWORK_VOLUME/scripts/download_gdrive.sh" << EOF
#!/bin/bash
# Google Drive download script
# Usage: ./download_gdrive.sh <google_drive_url_or_file_id> <destination_path>

if [ \$# -ne 2 ]; then
    echo "Usage: \$0 <google_drive_url_or_file_id> <destination_path>"
    echo "Example: \$0 'https://drive.google.com/file/d/1234567890/view' $NETWORK_VOLUME/ComfyUI/models/checkpoints/"
    echo "Example: \$0 '1234567890' $NETWORK_VOLUME/ComfyUI/models/checkpoints/"
    exit 1
fi

INPUT="\$1"
DEST="\$2"

# Extract file ID from Google Drive URL or use direct file ID (POSIX compatible)
case "\$INPUT" in
    *"drive.google.com"*)
        FILE_ID=\$(echo "\$INPUT" | sed -n 's|.*[/=]\([a-zA-Z0-9_-]\{25,\}\).*|\1|p')
        ;;
    *)
        FILE_ID="\$INPUT"
        ;;
esac

if [ -z "\$FILE_ID" ]; then
    echo "❌ Could not extract file ID from input: \$INPUT"
    exit 1
fi

# Validate destination directory
if [ ! -d "\$DEST" ]; then
    echo "❌ Destination directory does not exist: \$DEST"
    echo "Creating destination directory..."
    mkdir -p "\$DEST"
fi

echo "📥 Downloading from Google Drive..."
echo "File ID: \$FILE_ID"
echo "Destination: \$DEST"

# Activate virtual environment and download in destination directory using subshell
(
    cd "\$DEST" && \\
    . "$NETWORK_VOLUME/venv/comfyui/bin/activate" && \\
    gdown "\$FILE_ID"
)

DOWNLOAD_STATUS=\$?

if [ \$DOWNLOAD_STATUS -eq 0 ]; then
    echo "✅ Download completed successfully!"
    echo "📁 Files in destination:"
    ls -lh "\$DEST"
else
    echo "❌ Download failed!"
    echo ""
    echo "🔧 Troubleshooting tips:"
    echo "1. Check if the Google Drive file is public (shared with 'Anyone with the link')"
    echo "2. Try accessing the file directly in browser: https://drive.google.com/file/d/\$FILE_ID/view"
    echo "3. If the file is private, you may need to authenticate gdown:"
    echo "   gdown --folder 'your_folder_url' --remaining-ok"
    echo "4. Alternative: Download manually and upload to the container"
    exit 1
fi
EOF

        # Create HuggingFace download script
        cat > "$NETWORK_VOLUME/scripts/download_hf.sh" << EOF
#!/bin/bash
# HuggingFace download script
# Usage: ./download_hf.sh <repo_id> <filename> <destination_path>

if [ \$# -ne 3 ]; then
    echo "Usage: \$0 <repo_id> <filename> <destination_path>"
    echo "Example: \$0 'runwayml/stable-diffusion-v1-5' 'v1-5-pruned.safetensors' $NETWORK_VOLUME/ComfyUI/models/checkpoints/"
    exit 1
fi

REPO_ID="\$1"
FILENAME="\$2"
DEST="\$3"

echo "📥 Downloading from HuggingFace..."
echo "Repo: \$REPO_ID"
echo "File: \$FILENAME"
echo "Destination: \$DEST"

# Activate virtual environment and download
. "$NETWORK_VOLUME/venv/comfyui/bin/activate"
huggingface-cli download "\$REPO_ID" "\$FILENAME" --local-dir "\$DEST"

if [ \$? -eq 0 ]; then
    echo "✅ Download completed successfully!"
    ls -lh "\$DEST/\$FILENAME"
else
    echo "❌ Download failed!"
    exit 1
fi
EOF

        # Create Civitai download script
        cat > "$NETWORK_VOLUME/scripts/download_civitai.sh" << EOF
#!/bin/bash
# Civitai download script
# Usage: ./download_civitai.sh <model_url> <destination_path> [filename]

if [ \$# -lt 2 ]; then
    echo "Usage: \$0 <civitai_model_url> <destination_path> [filename]"
    echo "Example: \$0 'https://civitai.com/api/download/models/12345' $NETWORK_VOLUME/ComfyUI/models/checkpoints/ model.safetensors"
    exit 1
fi

URL="\$1"
DEST="\$2"
FILENAME="\$3"

echo "📥 Downloading from Civitai..."
echo "URL: \$URL"
echo "Destination: \$DEST"

# Download using curl with redirect following
if [ -n "\$FILENAME" ]; then
    curl -L "\$URL" -o "\$DEST/\$FILENAME"
else
    curl -L -O -J "\$URL" && mv "\$(ls -t | head -n1)" "\$DEST"
fi

if [ \$? -eq 0 ]; then
    echo "✅ Download completed successfully!"
    ls -lh "\$DEST"
else
    echo "❌ Download failed!"
    exit 1
fi
EOF

        # Make scripts executable
        chmod +x "$NETWORK_VOLUME/scripts"/*.sh
        
        # Create a helper script for common model types
        cat > "$NETWORK_VOLUME/scripts/download_helper.sh" << EOF
#!/bin/bash
# Download helper with common model destinations

echo "🛠️ ComfyUI Download Helper"
echo "=========================="
echo ""
echo "Available model directories:"
echo "  1. Checkpoints: $NETWORK_VOLUME/ComfyUI/models/checkpoints/"
echo "  2. VAE: $NETWORK_VOLUME/ComfyUI/models/vae/"
echo "  3. LoRA: $NETWORK_VOLUME/ComfyUI/models/loras/"
echo "  4. ControlNet: $NETWORK_VOLUME/ComfyUI/models/controlnet/"
echo "  5. Embeddings: $NETWORK_VOLUME/ComfyUI/models/embeddings/"
echo "  6. Upscale Models: $NETWORK_VOLUME/ComfyUI/models/upscale_models/"
echo ""
echo "Usage examples:"
echo ""
echo "Google Drive:"
echo "./download_gdrive.sh 'https://drive.google.com/file/d/ID/view' $NETWORK_VOLUME/ComfyUI/models/checkpoints/"
echo ""
echo "HuggingFace:"
echo "./download_hf.sh 'runwayml/stable-diffusion-v1-5' 'v1-5-pruned.safetensors' $NETWORK_VOLUME/ComfyUI/models/checkpoints/"
echo ""
echo "Civitai:"
echo "./download_civitai.sh 'https://civitai.com/api/download/models/12345' $NETWORK_VOLUME/ComfyUI/models/loras/ lora.safetensors"
echo ""
echo "Direct URL:"
echo "wget -P $NETWORK_VOLUME/ComfyUI/models/checkpoints/ 'https://example.com/model.safetensors'"
EOF

        chmod +x "$NETWORK_VOLUME/scripts/download_helper.sh"
        
        echo "✅ Download scripts created"
    else
        echo "✅ Download scripts already exist"
    fi
    
    echo "✅ Download tools setup complete"
    echo "📚 Run: $NETWORK_VOLUME/scripts/download_helper.sh for usage examples"
}

# Setup all components (after mounting is complete)
echo "🔧 Setting up all components..."
setup_virtual_environments
setup_jupyter_installation  
setup_persistent_jupyter
setup_persistent_comfyui_data
setup_comfyui_installation
setup_comfyui_manager
setup_download_tools

echo "✅ All components setup complete"

# Perform initial sync to capture any setup changes
echo "🔄 Performing initial user data sync..."
$NETWORK_VOLUME/scripts/sync_user_data.sh

# Start JupyterLab
echo "Starting JupyterLab..."
. $JUPYTER_VENV/bin/activate
jupyter lab --ip 0.0.0.0 --port 8888 --no-browser --allow-root &
deactivate

# Print directory structure
echo "📁 Network Volume Structure:"
tree -L 2 $NETWORK_VOLUME 2>/dev/null || ls -la $NETWORK_VOLUME

# Install custom nodes if nodes.txt exists
if [ -f "$NETWORK_VOLUME/ComfyUI/nodes.txt" ]; then
    echo "Installing custom nodes..."
    bash /scripts/install_nodes.sh
fi

# Final sync before starting ComfyUI
$NETWORK_VOLUME/scripts/sync_user_data.sh

# Create ComfyUI startup wrapper with logging
cat > "$NETWORK_VOLUME/start_comfyui_with_logs.sh" << 'EOF'
#!/bin/bash
# ComfyUI startup wrapper with comprehensive logging

COMFYUI_LOG="$NETWORK_VOLUME/ComfyUI/comfyui.log"
COMFYUI_ERROR_LOG="$NETWORK_VOLUME/ComfyUI/comfyui_error.log"

echo "🚀 Starting ComfyUI with logging at $(date)"
echo "Log file: $COMFYUI_LOG"
echo "Error log: $COMFYUI_ERROR_LOG"

cd $NETWORK_VOLUME/ComfyUI
. $COMFYUI_VENV/bin/activate

# Start ComfyUI with comprehensive logging
python main.py --listen 0.0.0.0 --port 3000 --enable-cors-header \
    > >(tee -a "$COMFYUI_LOG") \
    2> >(tee -a "$COMFYUI_ERROR_LOG" >&2)
EOF

chmod +x "$NETWORK_VOLUME/start_comfyui_with_logs.sh"

# Start ComfyUI with logging
echo "🚀 Starting ComfyUI with comprehensive logging..."
exec "$NETWORK_VOLUME/start_comfyui_with_logs.sh"