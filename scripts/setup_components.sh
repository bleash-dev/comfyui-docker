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

# Define custom nodes to install
declare -A CUSTOM_NODES=(
    ["ComfyUI-Manager"]="https://github.com/ltdrdata/ComfyUI-Manager.git"
    ["Comfyui-FileSytem-Manager"]="https://github.com/bleash-dev/Comfyui-FileSytem-Manager.git"
    ["Comfyui-Idle-Checker"]="https://github.com/bleash-dev/Comfyui-Idle-Checker.git"
    ["ComfyUI-Auth-Manager"]="https://github.com/bleash-dev/ComfyUI-Auth-Manager.git"
)

# Change to the custom_nodes directory
cd "$custom_nodes_dir"
if [ $? -ne 0 ]; then
    echo "❌ ERROR: Failed to change directory to $custom_nodes_dir even after creation check. Exiting."
    exit 1
fi
echo "➡️  Currently in directory: $(pwd)"

# Install each custom node
for node_name in "${!CUSTOM_NODES[@]}"; do
    node_url="${CUSTOM_NODES[$node_name]}"
    node_dir="$custom_nodes_dir/$node_name"
    
    echo "🔧 Processing custom node: $node_name"
    
    if [ -d "$node_dir" ] && [ -f "$node_dir/__init__.py" ]; then
        echo "✅ $node_name already exists (from mounted storage)"
        cd "$node_dir"
        echo "🔄 Updating $node_name..."
        git pull || echo "⚠️ Git pull failed for $node_name, continuing with existing version"
        cd "$custom_nodes_dir"
    else
        echo "📥 Installing $node_name..."
        git clone "$node_url" "$node_name" || echo "⚠️ Git clone failed for $node_name"
    fi
    
    # Add requirements to consolidated file if they exist
    if [ -f "$node_dir/requirements.txt" ]; then
        echo "📋 Adding requirements from $node_name to consolidated file"
        echo "# $node_name requirements" >> "$CONSOLIDATED_REQUIREMENTS"
        cat "$node_dir/requirements.txt" >> "$CONSOLIDATED_REQUIREMENTS"
        echo "" >> "$CONSOLIDATED_REQUIREMENTS"
    fi
done

echo "✅ Additional custom nodes setup complete"

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
    
    # Run install.py for predefined custom nodes
    for node_name in "${!CUSTOM_NODES[@]}"; do
        node_dir="$custom_nodes_dir/$node_name"
        if [ -f "$node_dir/install.py" ]; then
            echo "Running install.py for $node_name..."
            cd "$node_dir"
            python install.py || echo "⚠️ $node_name install.py failed"
            cd "$custom_nodes_dir"
        fi
    done
    
    # Run install.py for any custom nodes from nodes.txt
    if [ -f "$NETWORK_VOLUME/ComfyUI/nodes.txt" ]; then
        echo "Running install.py scripts for custom nodes from nodes.txt..."
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
    
    deactivate
    
    # Cleanup
    rm -f "$CONSOLIDATED_REQUIREMENTS" "${CONSOLIDATED_REQUIREMENTS}.clean"
    
    echo "✅ Consolidated pip installation completed"
else
    echo "ℹ️ No requirements to install"
fi

echo "✅ All components setup complete"
echo "✅ All components setup complete"
