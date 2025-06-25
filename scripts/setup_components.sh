#!/bin/bash
set -eo pipefail

echo "🔧 Setting up ComfyUI components..."

# Set default script directory, Python version, and config root
export SCRIPT_DIR="${SCRIPT_DIR:-/scripts}"
export PYTHON_VERSION="${PYTHON_VERSION:-3.10}"
export PYTHON_CMD="${PYTHON_CMD:-python${PYTHON_VERSION}}"
export COMFYUI_GIT="https://github.com/gilons/vf-comfyui-cors.git"

echo "📝 Using Python: $PYTHON_CMD ($($PYTHON_CMD --version))"

# Environment setup  
export COMFYUI_VENV="$NETWORK_VOLUME/venv/comfyui"

# Create consolidated requirements file for optimization
CONSOLIDATED_REQUIREMENTS="/tmp/consolidated_requirements.txt"
> "$CONSOLIDATED_REQUIREMENTS"  # Clear file

# Setup virtual environments
if [ ! -d "$COMFYUI_VENV" ]; then
    echo "Creating ComfyUI virtual environment..."
    mkdir -p "$(dirname "$COMFYUI_VENV")"
    $PYTHON_CMD -m venv "$COMFYUI_VENV"
fi

# Setup ComfyUI config - store directly in network volume
network_comfyui_config="$NETWORK_VOLUME/.comfyui"
mkdir -p "$network_comfyui_config"

echo "✅ Configuration directories created directly in network volume"

# Setup ComfyUI installation
comfyui_dir="$NETWORK_VOLUME/ComfyUI"

# Check if ComfyUI directory exists and handle appropriately
if [ -d "$comfyui_dir" ]; then
    echo "ComfyUI directory already exists at $comfyui_dir"
    
    # Check if it's a valid ComfyUI installation
    if [ -f "$comfyui_dir/main.py" ]; then
        echo "✅ Found existing ComfyUI installation"
        cd "$comfyui_dir"
        
        # Update existing installation
        echo "Updating existing ComfyUI installation..."
        git fetch --all || echo "⚠️ Git fetch failed, continuing with existing version"
        git reset --hard origin/master || echo "⚠️ Git reset failed, continuing with current version"
        
# Add ComfyUI requirements to consolidated file
        if [ -f "requirements.txt" ]; then
            echo "# ComfyUI requirements" >> "$CONSOLIDATED_REQUIREMENTS"
            cat requirements.txt >> "$CONSOLIDATED_REQUIREMENTS"
            echo "" >> "$CONSOLIDATED_REQUIREMENTS"
        fi
    else
        echo "⚠️ ComfyUI directory exists but doesn't contain main.py"
        
        # Check if directory is empty or only contains hidden files
        if [ -z "$(ls -A "$comfyui_dir" 2>/dev/null | grep -v '^\.')" ]; then
            echo "Directory is effectively empty, proceeding with fresh installation..."
            rm -rf "$comfyui_dir"
            echo "Installing ComfyUI..."
            . $COMFYUI_VENV/bin/activate
            git clone $COMFYUI_GIT "$comfyui_dir"
            cd "$comfyui_dir"
            pip install --no-cache-dir -r requirements.txt
            pip install --no-cache-dir torch==${PYTORCH_VERSION:-2.4.0} torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
            deactivate
        else
            echo "Directory contains files but not a valid ComfyUI installation"
            echo "Contents:"
            ls -la "$comfyui_dir"
            
            # Backup existing directory and install fresh
            backup_dir="$NETWORK_VOLUME/ComfyUI_backup_$(date +%Y%m%d_%H%M%S)"
            echo "Backing up existing directory to $backup_dir"
            mv "$comfyui_dir" "$backup_dir"
            
            echo "Installing fresh ComfyUI..."
            git clone $COMFYUI_GIT "$comfyui_dir"
            cd "$comfyui_dir"
            
            # Add ComfyUI requirements to consolidated file
            if [ -f "requirements.txt" ]; then
                echo "# ComfyUI requirements" >> "$CONSOLIDATED_REQUIREMENTS"
                cat requirements.txt >> "$CONSOLIDATED_REQUIREMENTS"
                echo "" >> "$CONSOLIDATED_REQUIREMENTS"
            fi
        fi
    fi
else
    echo "Installing ComfyUI..."
    git clone $COMFYUI_GIT "$comfyui_dir"
    cd "$comfyui_dir"
    
    # Add ComfyUI requirements to consolidated file
    if [ -f "requirements.txt" ]; then
        echo "# ComfyUI requirements" >> "$CONSOLIDATED_REQUIREMENTS"
        cat requirements.txt >> "$CONSOLIDATED_REQUIREMENTS"
        echo "" >> "$CONSOLIDATED_REQUIREMENTS"
    fi
fi


# Setup additional custom nodes
echo "📝 Setting up additional custom nodes..."
custom_nodes_dir="$NETWORK_VOLUME/ComfyUI/custom_nodes"

if [ ! -d "$custom_nodes_dir" ]; then
    echo "🛠️ Custom nodes directory ($custom_nodes_dir) does not exist. Creating it..."
    mkdir -p "$custom_nodes_dir"
    if [ $? -ne 0 ]; then
        echo "❌ ERROR: Failed to create custom nodes directory: $custom_nodes_dir. Exiting."
        exit 1
    else
        echo "✅ Successfully created custom nodes directory: $custom_nodes_dir"
    fi
else
    echo "👍 Custom nodes directory ($custom_nodes_dir) already exists."
fi


# Setup ComfyUI Manager
manager_dir="$custom_nodes_dir/ComfyUI-Manager"
if [ ! -d "$manager_dir" ]; then
    echo "Installing ComfyUI Manager..."
    cd "$custom_nodes_dir"
    git clone https://github.com/ltdrdata/ComfyUI-Manager.git
    
    # Add ComfyUI Manager requirements to consolidated file
    if [ -f "ComfyUI-Manager/requirements.txt" ]; then
        echo "# ComfyUI-Manager requirements" >> "$CONSOLIDATED_REQUIREMENTS"
        cat "ComfyUI-Manager/requirements.txt" >> "$CONSOLIDATED_REQUIREMENTS"
        echo "" >> "$CONSOLIDATED_REQUIREMENTS"
    fi
else
    echo "✅ ComfyUI Manager already exists"
    cd "$manager_dir"
    echo "Updating ComfyUI Manager..."
    git pull || echo "⚠️ Git pull failed, continuing with existing version"
    
    # Add ComfyUI Manager requirements to consolidated file
    if [ -f "requirements.txt" ]; then
        echo "# ComfyUI-Manager requirements" >> "$CONSOLIDATED_REQUIREMENTS"
        cat "requirements.txt" >> "$CONSOLIDATED_REQUIREMENTS"
        echo "" >> "$CONSOLIDATED_REQUIREMENTS"
    fi
fi

filesystem_manager_dir="$custom_nodes_dir/Comfyui-FileSytem-Manager"
idle_checker_dir="$custom_nodes_dir/Comfyui-Idle-Checker"


# --- Change to the custom_nodes directory ---
# This cd is now safe because we've ensured the directory exists or exited if creation failed.
cd "$custom_nodes_dir"
if [ $? -ne 0 ]; then
    echo "❌ ERROR: Failed to change directory to $custom_nodes_dir even after creation check. Exiting."
    exit 1
fi
echo "➡️  Currently in directory: $(pwd)"

# Install Comfyui-FileSytem-Manager
if [ -d "$filesystem_manager_dir" ] && [ -f "$filesystem_manager_dir/__init__.py" ]; then
    echo "✅ Comfyui-FileSytem-Manager already exists (from mounted storage)"
    cd "$filesystem_manager_dir"
    git pull || echo "⚠️ Git pull failed, continuing with existing version"
    cd "$custom_nodes_dir"
else
    echo "Installing Comfyui-FileSytem-Manager..."
    git clone https://github.com/bleash-dev/Comfyui-FileSytem-Manager.git
fi

# Add Comfyui-FileSytem-Manager requirements to consolidated file
if [ -f "$filesystem_manager_dir/requirements.txt" ]; then
    echo "# Comfyui-FileSytem-Manager requirements" >> "$CONSOLIDATED_REQUIREMENTS"
    cat "$filesystem_manager_dir/requirements.txt" >> "$CONSOLIDATED_REQUIREMENTS"
    echo "" >> "$CONSOLIDATED_REQUIREMENTS"
fi

# Install Comfyui-Idle-Checker
if [ -d "$idle_checker_dir" ] && [ -f "$idle_checker_dir/__init__.py" ]; then
    echo "✅ Comfyui-Idle-Checker already exists (from mounted storage)"
    cd "$idle_checker_dir"
    git pull || echo "⚠️ Git pull failed, continuing with existing version"
    cd "$custom_nodes_dir"
else
    echo "Installing Comfyui-Idle-Checker..."
    git clone https://github.com/bleash-dev/Comfyui-Idle-Checker.git
fi

# Add Comfyui-Idle-Checker requirements to consolidated file
if [ -f "$idle_checker_dir/requirements.txt" ]; then
    echo "# Comfyui-Idle-Checker requirements" >> "$CONSOLIDATED_REQUIREMENTS"
    cat "$idle_checker_dir/requirements.txt" >> "$CONSOLIDATED_REQUIREMENTS"
    echo "" >> "$CONSOLIDATED_REQUIREMENTS"
fi
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

# Sync remote models after cache restoration
echo "🌐 Starting initial remote model sync..."
if [ -f "$NETWORK_VOLUME/scripts/sync_remote_models.sh" ]; then
    # Run in background to avoid blocking startup
    nohup bash "$NETWORK_VOLUME/scripts/sync_remote_models.sh" > "$NETWORK_VOLUME/.initial_model_sync.log" 2>&1 &
    INITIAL_SYNC_PID=$!
    echo "📊 Initial model sync started in background (PID: $INITIAL_SYNC_PID)"
    echo "📝 Check progress: tail -f $NETWORK_VOLUME/.initial_model_sync.log"
else
    echo "⚠️ Remote model sync script not found, skipping initial sync"
fi


# Add standard tools to consolidated requirements
echo "# Standard tools requirements" >> "$CONSOLIDATED_REQUIREMENTS"
echo "gdown" >> "$CONSOLIDATED_REQUIREMENTS"
echo "huggingface_hub[cli]" >> "$CONSOLIDATED_REQUIREMENTS"
echo "" >> "$CONSOLIDATED_REQUIREMENTS"

# Install custom nodes if nodes.txt exists
[ -f "$NETWORK_VOLUME/ComfyUI/nodes.txt" ] && bash "$SCRIPT_DIR/install_nodes.sh" "$CONSOLIDATED_REQUIREMENTS"

# Consolidated pip install - Install all requirements in one go
if [ -s "$CONSOLIDATED_REQUIREMENTS" ]; then
    echo "🔄 Installing all consolidated requirements..."
    . $COMFYUI_VENV/bin/activate
    
    # Remove duplicates and empty lines
    sort "$CONSOLIDATED_REQUIREMENTS" | uniq | grep -v '^$' | grep -v '^#' > "${CONSOLIDATED_REQUIREMENTS}.clean"
    
    # Install all requirements at once
    pip install --no-cache-dir -r "${CONSOLIDATED_REQUIREMENTS}.clean" || echo "⚠️ Some requirements failed to install"
    
    # Install PyTorch if needed
    if ! python -c "import torch" 2>/dev/null; then
        echo "Installing PyTorch..."
        pip install --no-cache-dir torch==${PYTORCH_VERSION:-2.4.0} torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
    fi
    
    # Run custom installation scripts after pip install
    echo "🔧 Running custom installation scripts..."
    
    # FileSystem Manager install
    if [ -f "$filesystem_manager_dir/install.py" ]; then
        echo "Running Comfyui-FileSytem-Manager installation..."
        cd "$filesystem_manager_dir"
        python install.py || echo "⚠️ Comfyui-FileSytem-Manager install.py failed"
        cd "$custom_nodes_dir"
    fi
    
    # Idle Checker install
    if [ -f "$idle_checker_dir/install.py" ]; then
        echo "Running Comfyui-Idle-Checker installation..."
        cd "$idle_checker_dir"
        python install.py || echo "⚠️ Comfyui-Idle-Checker install.py failed"
        cd "$custom_nodes_dir"
    fi
    
    # Run install.py for any custom nodes from nodes.txt
    if [ -f "$NETWORK_VOLUME/ComfyUI/nodes.txt" ]; then
        echo "Running install.py scripts for custom nodes..."
        while IFS= read -r repo_url; do
            [[ -z "$repo_url" || "$repo_url" =~ ^[[:space:]]*# ]] && continue
            repo_name=$(basename "$repo_url" .git)
            if [ -f "$repo_name/install.py" ]; then
                echo "Running install.py for $repo_name..."
                cd "$repo_name"
                python install.py || echo "⚠️ $repo_name install.py failed"
                cd "$custom_nodes_dir"
            fi
        done < "$NETWORK_VOLUME/ComfyUI/nodes.txt"
    fi
    
    # Setup HuggingFace token if provided
    if [ -n "$HF_TOKEN" ]; then
        echo "🔧 Configuring HuggingFace CLI..."
        huggingface-cli login --token "$HF_TOKEN" --add-to-git-credential || echo "⚠️ HuggingFace login failed"
    fi
    
    deactivate
    
    # Cleanup
    rm -f "$CONSOLIDATED_REQUIREMENTS" "${CONSOLIDATED_REQUIREMENTS}.clean"
    
    echo "✅ Consolidated pip installation completed"
else
    echo "ℹ️ No requirements to install"
fi

echo "✅ All components setup complete"
echo "✅ All components setup complete"
