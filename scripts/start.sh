#!/bin/bash
# Remove set -euo pipefail for manual error handling

echo "🔍 Starting ComfyUI Setup..."
echo "Python Version: $(python3 --version)"

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

# Detect network volume location
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
    local network_venv_dir="$NETWORK_VOLUME/venv"
    
    # Create virtual environments in network volume if they don't exist
    if [ ! -d "$network_venv_dir/comfyui" ]; then
        echo "Creating ComfyUI virtual environment in network volume..."
        python${PYTHON_VERSION:-3.10} -m venv "$network_venv_dir/comfyui"
        echo "✅ ComfyUI virtual environment created"
    else
        echo "✅ Using existing ComfyUI virtual environment from network volume"
    fi
    
    if [ ! -d "$network_venv_dir/jupyter" ]; then
        echo "Creating Jupyter virtual environment in network volume..."
        python${PYTHON_VERSION:-3.10} -m venv "$network_venv_dir/jupyter"
        echo "✅ Jupyter virtual environment created"
    else
        echo "✅ Using existing Jupyter virtual environment from network volume"
    fi
    
    # Update environment variables to use network volume venvs directly
    export COMFYUI_VENV="$network_venv_dir/comfyui"
    export JUPYTER_VENV="$network_venv_dir/jupyter"
    export PATH="$COMFYUI_VENV/bin:$JUPYTER_VENV/bin:$PATH"
}

# Function to setup Jupyter installation
setup_jupyter_installation() {
    # Check if Jupyter is already installed in the network volume venv
    if ! "$JUPYTER_VENV/bin/python" -c "import jupyterlab" 2>/dev/null; then
        echo "Installing JupyterLab in network volume virtual environment..."
        . "$JUPYTER_VENV/bin/activate"
        pip install --no-cache-dir jupyterlab notebook numpy pandas
        deactivate
        echo "✅ JupyterLab installed in network volume"
    else
        echo "✅ Using existing JupyterLab installation from network volume"
    fi
}

# Function to setup jupyter config persistence
setup_persistent_jupyter() {
    local network_jupyter_dir="$NETWORK_VOLUME/.jupyter"
    local local_jupyter_dir="/root/.jupyter"
    
    if [ ! -d "$network_jupyter_dir" ]; then
        echo "Setting up Jupyter config on network volume..."
        mkdir -p "$network_jupyter_dir"
        
        # Generate config directly in network volume
        . $JUPYTER_VENV/bin/activate
        jupyter notebook --generate-config --config-dir="$network_jupyter_dir"
        
        # Configure Jupyter for no-auth access directly in network volume
        cat > "$network_jupyter_dir/jupyter_notebook_config.py" << 'EOF'
c.NotebookApp.token = ''
c.NotebookApp.password = ''
c.NotebookApp.allow_origin = '*'
c.NotebookApp.allow_remote_access = True
c.NotebookApp.ip = '0.0.0.0'
c.NotebookApp.port = 8888
c.NotebookApp.open_browser = False
c.NotebookApp.allow_root = True

# JupyterLab config
c.ServerApp.token = ''
c.ServerApp.password = ''
c.ServerApp.allow_origin = '*'
c.ServerApp.allow_remote_access = True
c.ServerApp.ip = '0.0.0.0'
c.ServerApp.port = 8888
c.ServerApp.open_browser = False
c.ServerApp.allow_root = True
EOF
        echo "✅ Jupyter configuration created in network volume"
        deactivate
    else
        echo "✅ Using existing Jupyter config from network volume"
    fi
    
    # Link jupyter config to local directory
    rm -rf "$local_jupyter_dir"
    create_symlink "$network_jupyter_dir" "$local_jupyter_dir"
}

# Function to setup ComfyUI user data persistence
setup_persistent_comfyui_data() {
    local network_comfyui_config="$NETWORK_VOLUME/.comfyui"
    local local_comfyui_config="/root/.comfyui"
    
    # Setup ComfyUI configuration directory directly in network volume
    if [ ! -d "$network_comfyui_config" ]; then
        echo "Setting up ComfyUI config on network volume..."
        mkdir -p "$network_comfyui_config"
        echo "✅ ComfyUI configuration directory created in network volume"
    else
        echo "✅ Using existing ComfyUI config from network volume"
    fi
    
    # Link ComfyUI config to local directory
    rm -rf "$local_comfyui_config"
    create_symlink "$network_comfyui_config" "$local_comfyui_config"
    
    echo "✅ ComfyUI user data persistence setup complete"
}

# Function to setup ComfyUI installation
setup_comfyui_installation() {
    local comfyui_dir="$NETWORK_VOLUME/ComfyUI"
    
    if [ ! -d "$comfyui_dir" ]; then
        echo "Installing ComfyUI in network volume..."
        
        # Clone ComfyUI directly to network volume
        . $COMFYUI_VENV/bin/activate
        git clone https://github.com/comfyanonymous/ComfyUI "$comfyui_dir"
        cd "$comfyui_dir"
        
        # Checkout specific version if specified
        if [ "${COMFYUI_VERSION:-master}" != "master" ]; then
            git checkout "${COMFYUI_VERSION}"
        fi
        
        # Install requirements
        pip install --no-cache-dir -r requirements.txt
        pip install --no-cache-dir torch==${PYTORCH_VERSION:-2.4.0} torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
        
        deactivate
        echo "✅ ComfyUI installed in network volume"
    else
        echo "✅ Using existing ComfyUI installation from network volume"
    fi
    
    # Create symlink to standard location if not already there
    if [ "$NETWORK_VOLUME" != "/workspace" ]; then
        if [ -d "/workspace/ComfyUI" ] && [ ! -L "/workspace/ComfyUI" ]; then
            rm -rf "/workspace/ComfyUI"
        fi
        create_symlink "$comfyui_dir" "/workspace/ComfyUI"
    fi
}

# Function to setup ComfyUI Manager
setup_comfyui_manager() {
    local manager_dir="$NETWORK_VOLUME/ComfyUI/custom_nodes/ComfyUI-Manager"
    
    if [ ! -d "$manager_dir" ]; then
        echo "Installing ComfyUI Manager..."
        . $COMFYUI_VENV/bin/activate
        cd "$NETWORK_VOLUME/ComfyUI/custom_nodes"
        git clone https://github.com/ltdrdata/ComfyUI-Manager.git
        
        # Install Manager requirements if they exist
        if [ -f "ComfyUI-Manager/requirements.txt" ]; then
            echo "Installing ComfyUI Manager requirements..."
            pip install --no-cache-dir -r ComfyUI-Manager/requirements.txt
        fi
        
        deactivate
        echo "✅ ComfyUI Manager installed"
    else
        echo "✅ ComfyUI Manager already installed"
    fi
}

# Setup network volume
echo "Setting up persistent storage at $NETWORK_VOLUME"

# Setup virtual environments directly in network volume
setup_virtual_environments

# Setup Jupyter installation
setup_jupyter_installation

# Setup persistent Jupyter configuration
setup_persistent_jupyter

# Setup persistent ComfyUI user data
setup_persistent_comfyui_data

# Setup ComfyUI installation
setup_comfyui_installation

# Setup ComfyUI Manager
setup_comfyui_manager

echo "✅ All data running from network volume"

# Start JupyterLab
echo "Starting JupyterLab..."
. $JUPYTER_VENV/bin/activate
jupyter lab --ip 0.0.0.0 --port 8888 --no-browser --allow-root &
deactivate

# Print final directory structure
echo "📁 Final Directory Structure:"
tree -L 3 /workspace/ComfyUI 2>/dev/null || ls -la /workspace/ComfyUI
echo "📁 Network Volume Structure:"
tree -L 3 "$NETWORK_VOLUME" 2>/dev/null || ls -la "$NETWORK_VOLUME"

# Install custom nodes and their requirements using network volume venv
if [ -f "/workspace/ComfyUI/nodes.txt" ]; then
    echo "Installing custom nodes..."
    bash /scripts/install_nodes.sh
fi

# Start ComfyUI with the network volume virtual environment
echo "🚀 Starting ComfyUI..."
cd /workspace/ComfyUI
. $COMFYUI_VENV/bin/activate
exec python main.py --listen 0.0.0.0 --port 3000 --enable-cors-header