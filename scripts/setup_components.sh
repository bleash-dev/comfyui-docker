#!/bin/bash
set -eo pipefail # Ensures script exits on error and handles pipe failures
# Setup all ComfyUI components

echo "🔧 Setting up ComfyUI components..."

# Setup virtual environments
if [ ! -d "$COMFYUI_VENV" ]; then
    echo "Creating ComfyUI virtual environment..."
    mkdir -p "$(dirname "$COMFYUI_VENV")"
    python${PYTHON_VERSION:-3.10} -m venv "$COMFYUI_VENV"
fi

if [ ! -d "$JUPYTER_VENV" ]; then
    echo "Creating Jupyter virtual environment..."
    mkdir -p "$(dirname "$JUPYTER_VENV")"
    python${PYTHON_VERSION:-3.10} -m venv "$JUPYTER_VENV"
fi

# Setup Jupyter
if ! "$JUPYTER_VENV/bin/python" -c "import jupyterlab" 2>/dev/null; then
    echo "Installing JupyterLab..."
    . "$JUPYTER_VENV/bin/activate"
    pip install --no-cache-dir jupyterlab notebook numpy pandas
    deactivate
fi

# Setup Jupyter config
network_jupyter_dir="$NETWORK_VOLUME/.jupyter"
if [ ! -d "$network_jupyter_dir" ]; then
    mkdir -p "$network_jupyter_dir"
    . $JUPYTER_VENV/bin/activate
    jupyter notebook --generate-config --config-dir="$network_jupyter_dir"
    cat > "$network_jupyter_dir/jupyter_notebook_config.py" << 'EOF'
c.ServerApp.token = ''
c.ServerApp.password = ''
c.ServerApp.allow_origin = '*'
c.ServerApp.ip = '0.0.0.0'
c.ServerApp.port = 8888
c.ServerApp.open_browser = False
c.ServerApp.allow_root = True
EOF
    deactivate
fi

rm -rf "/root/.jupyter"
ln -sf "$network_jupyter_dir" "/root/.jupyter"

# Setup ComfyUI config
network_comfyui_config="$NETWORK_VOLUME/.comfyui"
mkdir -p "$network_comfyui_config"
rm -rf "/root/.comfyui"
ln -sf "$network_comfyui_config" "/root/.comfyui"

# Setup ComfyUI installation
comfyui_dir="$NETWORK_VOLUME/ComfyUI"
if [ ! -f "$comfyui_dir/main.py" ]; then
    echo "Installing ComfyUI..."
    . $COMFYUI_VENV/bin/activate
    git clone https://github.com/comfyanonymous/ComfyUI "$comfyui_dir"
    cd "$comfyui_dir"
    pip install --no-cache-dir -r requirements.txt
    pip install --no-cache-dir torch==${PYTORCH_VERSION:-2.4.0} torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
    deactivate
else
    echo "✅ Using existing ComfyUI installation"
    cd "$comfyui_dir"
    . $COMFYUI_VENV/bin/activate
    if ! python -c "import torch" 2>/dev/null; then
        echo "Installing ComfyUI requirements..."
        pip install --no-cache-dir -r requirements.txt
        pip install --no-cache-dir torch==${PYTORCH_VERSION:-2.4.0} torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
    fi
    deactivate
fi

# Setup ComfyUI Manager
manager_dir="$NETWORK_VOLUME/ComfyUI/custom_nodes/ComfyUI-Manager"
if [ ! -d "$manager_dir" ]; then
    echo "Installing ComfyUI Manager..."
    . $COMFYUI_VENV/bin/activate
    cd "$NETWORK_VOLUME/ComfyUI/custom_nodes"
    git clone https://github.com/ltdrdata/ComfyUI-Manager.git
    [ -f "ComfyUI-Manager/requirements.txt" ] && pip install --no-cache-dir -r ComfyUI-Manager/requirements.txt
    deactivate
fi

# Setup additional custom nodes
echo "📝 Setting up additional custom nodes..."
custom_nodes_dir="$NETWORK_VOLUME/ComfyUI/custom_nodes"
filesystem_manager_dir="$custom_nodes_dir/Comfyui-FileSytem-Manager"
idle_checker_dir="$custom_nodes_dir/Comfyui-Idle-Checker"

. $COMFYUI_VENV/bin/activate
cd "$custom_nodes_dir"

# Install Comfyui-FileSytem-Manager
if [ -d "$filesystem_manager_dir" ] && [ -f "$filesystem_manager_dir/__init__.py" ]; then
    echo "✅ Comfyui-FileSytem-Manager already exists (from mounted storage)"
    cd "$filesystem_manager_dir"
    git pull
    cd "$custom_nodes_dir"
else
    echo "Installing Comfyui-FileSytem-Manager..."
    git clone https://github.com/bleash-dev/Comfyui-FileSytem-Manager.git
    
    if [ -f "$filesystem_manager_dir/requirements.txt" ]; then
        pip install --no-cache-dir -r "$filesystem_manager_dir/requirements.txt"
    fi
    
    if [ -f "$filesystem_manager_dir/install.py" ]; then
        cd "$filesystem_manager_dir"
        python install.py
        cd "$custom_nodes_dir"
    fi
    
    echo "✅ Comfyui-FileSytem-Manager installed"
fi

# Install Comfyui-Idle-Checker
if [ -d "$idle_checker_dir" ] && [ -f "$idle_checker_dir/__init__.py" ]; then
    echo "✅ Comfyui-Idle-Checker already exists (from mounted storage)"
    cd "$idle_checker_dir"
    git pull
    cd "$custom_nodes_dir"
else
    echo "Installing Comfyui-Idle-Checker..."
    git clone https://github.com/bleash-dev/Comfyui-Idle-Checker.git
    
    if [ -f "$idle_checker_dir/requirements.txt" ]; then
        pip install --no-cache-dir -r "$idle_checker_dir/requirements.txt"
    fi
    
    if [ -f "$idle_checker_dir/install.py" ]; then
        cd "$idle_checker_dir"
        python install.py
        cd "$custom_nodes_dir"
    fi
    
    echo "✅ Comfyui-Idle-Checker installed"
fi

deactivate
echo "✅ Additional custom nodes setup complete"

# Setup download tools
. $COMFYUI_VENV/bin/activate
if ! python -c "import gdown, huggingface_hub" 2>/dev/null; then
    pip install --no-cache-dir gdown "huggingface_hub[cli]"
fi
[ -n "$HF_TOKEN" ] && huggingface-cli login --token $HF_TOKEN --add-to-git-credential
deactivate

# Setup download scripts
echo "📦 Setting up download tools and scripts..."
if [ ! -d "$NETWORK_VOLUME/scripts" ]; then
    mkdir -p "$NETWORK_VOLUME/scripts"
    
    # Create Google Drive download script
    cat > "$NETWORK_VOLUME/scripts/download_gdrive.sh" << 'EOF'
#!/bin/bash
# Google Drive download script
# Usage: ./download_gdrive.sh <google_drive_url_or_file_id> <destination_path>

if [ $# -ne 2 ]; then
    echo "Usage: $0 <google_drive_url_or_file_id> <destination_path>"
    echo "Example: $0 'https://drive.google.com/file/d/1234567890/view' $NETWORK_VOLUME/ComfyUI/models/checkpoints/"
    echo "Example: $0 '1234567890' $NETWORK_VOLUME/ComfyUI/models/checkpoints/"
    exit 1
fi

INPUT="$1"
DEST="$2"

# Extract file ID from Google Drive URL or use direct file ID (POSIX compatible)
case "$INPUT" in
    *"drive.google.com"*)
        FILE_ID=$(echo "$INPUT" | sed -n 's|.*[/=]\([a-zA-Z0-9_-]\{25,\}\).*|\1|p')
        ;;
    *)
        FILE_ID="$INPUT"
        ;;
esac

if [ -z "$FILE_ID" ]; then
    echo "❌ Could not extract file ID from input: $INPUT"
    exit 1
fi

# Validate destination directory
if [ ! -d "$DEST" ]; then
    echo "❌ Destination directory does not exist: $DEST"
    echo "Creating destination directory..."
    mkdir -p "$DEST"
fi

echo "📥 Downloading from Google Drive..."
echo "File ID: $FILE_ID"
echo "Destination: $DEST"

# Activate virtual environment and download in destination directory using subshell
(
    cd "$DEST" && \
    . "$NETWORK_VOLUME/venv/comfyui/bin/activate" && \
    gdown "$FILE_ID"
)

DOWNLOAD_STATUS=$?

if [ $DOWNLOAD_STATUS -eq 0 ]; then
    echo "✅ Download completed successfully!"
    echo "📁 Files in destination:"
    ls -lh "$DEST"
else
    echo "❌ Download failed!"
    echo ""
    echo "🔧 Troubleshooting tips:"
    echo "1. Check if the Google Drive file is public (shared with 'Anyone with the link')"
    echo "2. Try accessing the file directly in browser: https://drive.google.com/file/d/$FILE_ID/view"
    echo "3. If the file is private, you may need to authenticate gdown"
    echo "4. Alternative: Download manually and upload to the container"
    exit 1
fi
EOF

    # Create HuggingFace download script
    cat > "$NETWORK_VOLUME/scripts/download_hf.sh" << 'EOF'
#!/bin/bash
# HuggingFace download script
# Usage: ./download_hf.sh <repo_id> <filename> <destination_path>

if [ $# -ne 3 ]; then
    echo "Usage: $0 <repo_id> <filename> <destination_path>"
    echo "Example: $0 'runwayml/stable-diffusion-v1-5' 'v1-5-pruned.safetensors' $NETWORK_VOLUME/ComfyUI/models/checkpoints/"
    exit 1
fi

REPO_ID="$1"
FILENAME="$2"
DEST="$3"

echo "📥 Downloading from HuggingFace..."
echo "Repo: $REPO_ID"
echo "File: $FILENAME"
echo "Destination: $DEST"

# Activate virtual environment and download
. "$NETWORK_VOLUME/venv/comfyui/bin/activate"
huggingface-cli download "$REPO_ID" "$FILENAME" --local-dir "$DEST"

if [ $? -eq 0 ]; then
    echo "✅ Download completed successfully!"
    ls -lh "$DEST/$FILENAME"
else
    echo "❌ Download failed!"
    exit 1
fi
EOF

    # Create Civitai download script
    cat > "$NETWORK_VOLUME/scripts/download_civitai.sh" << 'EOF'
#!/bin/bash
# Civitai download script
# Usage: ./download_civitai.sh <model_url> <destination_path> [filename]

if [ $# -lt 2 ]; then
    echo "Usage: $0 <civitai_model_url> <destination_path> [filename]"
    echo "Example: $0 'https://civitai.com/api/download/models/12345' $NETWORK_VOLUME/ComfyUI/models/checkpoints/ model.safetensors"
    exit 1
fi

URL="$1"
DEST="$2"
FILENAME="$3"

echo "📥 Downloading from Civitai..."
echo "URL: $URL"
echo "Destination: $DEST"

# Download using curl with redirect following
if [ -n "$FILENAME" ]; then
    curl -L "$URL" -o "$DEST/$FILENAME"
else
    curl -L -O -J "$URL" && mv "$(ls -t | head -n1)" "$DEST"
fi

if [ $? -eq 0 ]; then
    echo "✅ Download completed successfully!"
    ls -lh "$DEST"
else
    echo "❌ Download failed!"
    exit 1
fi
EOF

    # Make scripts executable
    chmod +x "$NETWORK_VOLUME/scripts"/*.sh
    
    # Create download helper script
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

# Start JupyterLab
echo "Starting JupyterLab..."
. $JUPYTER_VENV/bin/activate
jupyter lab --ip 0.0.0.0 --port 8888 --no-browser --allow-root &
deactivate

# Install custom nodes if nodes.txt exists
[ -f "$NETWORK_VOLUME/ComfyUI/nodes.txt" ] && bash /scripts/install_nodes.sh

echo "✅ All components setup complete"
