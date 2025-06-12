#!/bin/bash
set -euo pipefail
umask 002

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
    echo "⚠️ No network volume detected, using local storage"
fi

# Function to safely create directory structure
create_dir_structure() {
    local base_path="$1"
    echo "Creating directory structure in $base_path"
    
    # Create all necessary directories
    for dir in ComfyUI/models ComfyUI/input ComfyUI/output ComfyUI/custom_nodes ComfyUI/user ComfyUI/temp ComfyUI/web/extensions venv/comfyui venv/jupyter .jupyter .comfyui pip_cache workflows; do
        mkdir -p "$base_path/$dir"
        echo "Created $base_path/$dir"
    done
}

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

# Function to move virtual environment to network volume
setup_persistent_venv() {
    local network_venv_dir="$NETWORK_VOLUME/venv"
    local local_venv_dir="/opt/venv"
    
    # ComfyUI virtual environment
    if [ ! -d "$network_venv_dir/comfyui" ]; then
        echo "Moving ComfyUI virtual environment to network volume..."
        cp -r "$local_venv_dir/comfyui" "$network_venv_dir/"
    fi
    
    # Jupyter virtual environment  
    if [ ! -d "$network_venv_dir/jupyter" ]; then
        echo "Moving Jupyter virtual environment to network volume..."
        cp -r "$local_venv_dir/jupyter" "$network_venv_dir/"
    fi
    
    # Remove local venvs and create symlinks
    rm -rf "$local_venv_dir"
    create_symlink "$network_venv_dir" "$local_venv_dir"
    
    # Update PATH to use network volume venvs
    export COMFYUI_VENV="$network_venv_dir/comfyui"
    export JUPYTER_VENV="$network_venv_dir/jupyter"
    export PATH="$COMFYUI_VENV/bin:$JUPYTER_VENV/bin:$PATH"
}

# Function to setup jupyter config persistence
setup_persistent_jupyter() {
    local network_jupyter_dir="$NETWORK_VOLUME/.jupyter"
    local local_jupyter_dir="/root/.jupyter"
    
    if [ ! -d "$network_jupyter_dir" ]; then
        echo "Setting up Jupyter config on network volume..."
        mkdir -p "$network_jupyter_dir"
        # Copy existing config if it exists
        if [ -d "$local_jupyter_dir" ]; then
            cp -r "$local_jupyter_dir"/* "$network_jupyter_dir/"
        fi
        # Generate config if it doesn't exist
        . $JUPYTER_VENV/bin/activate
        jupyter notebook --generate-config --config-dir="$network_jupyter_dir"
        echo "c.NotebookApp.token = ''" >> "$network_jupyter_dir/jupyter_notebook_config.py"
        echo "c.NotebookApp.password = ''" >> "$network_jupyter_dir/jupyter_notebook_config.py"
        deactivate
    fi
    
    # Link jupyter config
    rm -rf "$local_jupyter_dir"
    create_symlink "$network_jupyter_dir" "$local_jupyter_dir"
}

# Function to setup ComfyUI user data persistence
setup_persistent_comfyui_data() {
    local network_comfyui_config="$NETWORK_VOLUME/.comfyui"
    local local_comfyui_config="/root/.comfyui"
    
    # Setup ComfyUI configuration directory
    if [ ! -d "$network_comfyui_config" ]; then
        echo "Setting up ComfyUI config on network volume..."
        mkdir -p "$network_comfyui_config"
        if [ -d "$local_comfyui_config" ]; then
            cp -r "$local_comfyui_config"/* "$network_comfyui_config/"
        fi
    fi
    
    # Link ComfyUI config
    rm -rf "$local_comfyui_config"
    create_symlink "$network_comfyui_config" "$local_comfyui_config"
    
    echo "✅ ComfyUI user data persistence setup complete"
}

# Setup network volume if available
if [ -n "$NETWORK_VOLUME" ]; then
    echo "Setting up persistent storage at $NETWORK_VOLUME"
    create_dir_structure "$NETWORK_VOLUME"
    
    # Setup persistent virtual environments
    setup_persistent_venv
    
    # Setup persistent Jupyter configuration
    setup_persistent_jupyter
    
    # Setup persistent ComfyUI user data
    setup_persistent_comfyui_data
    
    # Handle different mount scenarios
    if [ "$NETWORK_VOLUME" = "/workspace" ]; then
        # Network volume is mounted at /workspace
        echo "Network volume mounted at /workspace - running directly from network storage"
        
        # Move ComfyUI to workspace if not already there
        if [ ! -d "/workspace/ComfyUI" ] && [ -d "/tmp/ComfyUI" ]; then
            echo "Setting up ComfyUI in workspace..."
            cp -r /tmp/ComfyUI /workspace/
        fi
        
    else
        # Network volume is at different location (e.g., /runpod-volume)
        echo "Network volume at $NETWORK_VOLUME - using symlink approach"
        
        # Link ComfyUI directories to network volume
        for dir in models input output custom_nodes user temp; do
            create_symlink "$NETWORK_VOLUME/ComfyUI/$dir" "/workspace/ComfyUI/$dir"
        done
        
        # Link web extensions
        create_symlink "$NETWORK_VOLUME/ComfyUI/web/extensions" "/workspace/ComfyUI/web/extensions"
    fi
    
    echo "✅ All data running from network volume"
else
    echo "⚠️ No network volume found, using local storage"
fi

# Start JupyterLab
echo "Starting JupyterLab..."
. $JUPYTER_VENV/bin/activate
jupyter lab --ip 0.0.0.0 --port 8888 --no-browser --allow-root &
deactivate

# Print final directory structure
echo "📁 Final Directory Structure:"
tree -L 3 /workspace/ComfyUI 2>/dev/null || ls -la /workspace/ComfyUI
if [ -n "$NETWORK_VOLUME" ]; then
    echo "📁 Network Volume Structure:"
    tree -L 3 "$NETWORK_VOLUME" 2>/dev/null || ls -la "$NETWORK_VOLUME"
fi

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