#!/bin/bash
set -eo pipefail

echo "🔧 Setting up ComfyUI base components for AMI..."

export TMPDIR=/workspace/tmp
mkdir -p "$TMPDIR"
# Set default script directory, Python version, and config root
export SCRIPT_DIR="${SCRIPT_DIR:-/scripts}"
export PYTHON_VERSION="${PYTHON_VERSION:-3.11}"
export PYTHON_CMD="${PYTHON_CMD:-python${PYTHON_VERSION}}"
export COMFYUI_GIT="https://github.com/gilons/vf-comfyui-cors.git"

echo "📝 Using Python: $PYTHON_CMD ($($PYTHON_CMD --version))"

# This script is for AMI build mode only - setting up base installation
# Use NETWORK_VOLUME if set (from prepare_ami.sh), otherwise fall back to /base for compatibility
BASE_ROOT="${NETWORK_VOLUME:-/base}"
echo "🏗️ AMI build mode - installing base ComfyUI at ${BASE_ROOT}/"
export BASE_VENV_PATH="${BASE_ROOT}/venv/comfyui"
export BASE_COMFYUI_PATH="${BASE_ROOT}/ComfyUI"

echo "📍 Base Virtual environment: $BASE_VENV_PATH"
echo "📍 Base ComfyUI path: $BASE_COMFYUI_PATH"

# For backward compatibility, set COMFYUI_VENV to BASE_VENV_PATH  
export COMFYUI_VENV="$BASE_VENV_PATH"

# Create consolidated requirements file for optimization
CONSOLIDATED_REQUIREMENTS="/tmp/consolidated_requirements.txt"
> "$CONSOLIDATED_REQUIREMENTS"  # Clear file

# Setup virtual environments (base installation only)
echo "🐍 Setting up base virtual environment..."
if [ ! -d "$COMFYUI_VENV" ]; then
    echo "Creating base ComfyUI virtual environment..."
    mkdir -p "$(dirname "$COMFYUI_VENV")"
    $PYTHON_CMD -m venv "$COMFYUI_VENV"
else
    echo "Base virtual environment exists, checking integrity..."
    
    # Check if the venv Python interpreter exists and works
    if [ ! -f "$COMFYUI_VENV/bin/python" ] || ! "$COMFYUI_VENV/bin/python" --version >/dev/null 2>&1; then
        echo "⚠️ Base virtual environment is corrupted, recreating..."
        rm -rf "$COMFYUI_VENV"
        mkdir -p "$(dirname "$COMFYUI_VENV")"
        $PYTHON_CMD -m venv "$COMFYUI_VENV"
        echo "✅ Base virtual environment recreated successfully"
    else
        echo "✅ Base virtual environment is healthy"
    fi
fi

# Ensure pip is working correctly in the venv
echo "🔧 Validating pip installation in base virtual environment..."
source "$COMFYUI_VENV/bin/activate"

# Check if pip command exists and works
if ! command -v pip >/dev/null 2>&1 || ! pip --version >/dev/null 2>&1; then
    echo "⚠️ pip is not working, attempting to fix..."
    
    # Try to reinstall pip using ensurepip
    if python -m ensurepip --upgrade 2>/dev/null; then
        echo "✅ pip reinstalled via ensurepip"
    else
        echo "⚠️ ensurepip failed, trying alternative approach..."
        python -m pip install --upgrade pip --disable-pip-version-check 2>/dev/null || {
            echo "❌ Failed to fix pip, but continuing..."
        }
    fi
    
    # Final check
    if pip --version >/dev/null 2>&1; then
        echo "✅ pip is now working"
    else
        echo "❌ pip is still not working, but continuing..."
    fi
else
    echo "✅ pip is working correctly"
fi

deactivate

# Setup base ComfyUI installation
comfyui_dir="$BASE_COMFYUI_PATH"

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
            git clone $COMFYUI_GIT "$comfyui_dir"
            cd "$comfyui_dir"
        else
            echo "Directory contains files but not a valid ComfyUI installation"
            echo "Contents:"
            ls -la "$comfyui_dir"
            
            # Backup existing directory and install fresh
            backup_dir="${comfyui_dir}_backup_$(date +%Y%m%d_%H%M%S)"
            echo "Backing up existing directory to $backup_dir"
            mv "$comfyui_dir" "$backup_dir"
            
            echo "Installing fresh ComfyUI..."
            git clone $COMFYUI_GIT "$comfyui_dir"
            cd "$comfyui_dir"
        fi
        
        # Add ComfyUI requirements to consolidated file
        if [ -f "requirements.txt" ]; then
            echo "# ComfyUI requirements" >> "$CONSOLIDATED_REQUIREMENTS"
            cat requirements.txt >> "$CONSOLIDATED_REQUIREMENTS"
            echo "" >> "$CONSOLIDATED_REQUIREMENTS"
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


# Setup base custom nodes
echo "📝 Setting up base custom nodes..."
custom_nodes_dir="$BASE_COMFYUI_PATH/custom_nodes"

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

# Define base custom nodes to install (always installed in base)
declare -A CUSTOM_NODES=(
    ["ComfyUI-Manager"]="https://github.com/ltdrdata/ComfyUI-Manager.git"
    ["Comfyui-FileSytem-Manager"]="https://github.com/bleash-dev/Comfyui-FileSytem-Manager.git"
    ["Comfyui-Idle-Checker"]="https://github.com/bleash-dev/Comfyui-Idle-Checker.git"
    ["ComfyUI-Auth-Manager"]="https://github.com/bleash-dev/ComfyUI-Auth-Manager.git"
    ["ComfyUI-Copilot"]="https://github.com/gilons/ComfyUI-Copilot.git"  # Always install in base, removed later for non-premium
)

# Define custom node branch mappings
declare -A CUSTOM_NODE_BRANCHES=(
    ["Comfyui-FileSytem-Manager"]="${GIT_BRANCH:-main}"
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
        
        # Check if this node has a specific branch configured
        if [ -n "${CUSTOM_NODE_BRANCHES[$node_name]:-}" ]; then
            target_branch="${CUSTOM_NODE_BRANCHES[$node_name]}"
            current_branch=$(git branch --show-current 2>/dev/null || echo "unknown")
            echo "Current branch: $current_branch, Target branch: $target_branch"
            
            if [ "$current_branch" != "$target_branch" ]; then
                echo "Switching to branch $target_branch..."
                git fetch --all || echo "⚠️ Git fetch failed"
                git checkout "$target_branch" || echo "⚠️ Branch switch failed, staying on current branch"
            fi
        fi
        
        git pull || echo "⚠️ Git pull failed for $node_name, continuing with existing version"
        cd "$custom_nodes_dir"
    else
        echo "📥 Installing $node_name..."
        
        # Check if this node has a specific branch configured
        if [ -n "${CUSTOM_NODE_BRANCHES[$node_name]:-}" ]; then
            target_branch="${CUSTOM_NODE_BRANCHES[$node_name]}"
            echo "Installing $node_name on branch: $target_branch"
            git clone -b "$target_branch" "$node_url" "$node_name" || {
                echo "⚠️ Branch-specific clone failed, trying default clone for $node_name"
                git clone "$node_url" "$node_name" || echo "⚠️ Git clone failed for $node_name"
            }
        else
            git clone "$node_url" "$node_name" || echo "⚠️ Git clone failed for $node_name"
        fi
    fi
    
done

# Scan all custom node directories for requirements files
echo "🔍 Scanning all custom node directories for requirements files..."
for dir in "$custom_nodes_dir"/*; do
    if [ -d "$dir" ]; then
        dir_name=$(basename "$dir")
        requirements_file="$dir/requirements.txt"
        
        # Check if requirements.txt exists
        if [ -f "$requirements_file" ]; then
            echo "📋 Found requirements in $dir_name"
            echo "# $dir_name requirements" >> "$CONSOLIDATED_REQUIREMENTS"
            cat "$requirements_file" >> "$CONSOLIDATED_REQUIREMENTS"
            echo "" >> "$CONSOLIDATED_REQUIREMENTS"
        fi
    fi
done

echo "✅ Additional custom nodes setup complete"

# Consolidated pip install - Install all requirements in one go
if [ -s "$CONSOLIDATED_REQUIREMENTS" ]; then
    echo "🔄 Installing all consolidated requirements..."
    source "$COMFYUI_VENV/bin/activate"
    
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
    
    deactivate
    
    # Cleanup
    rm -f "$CONSOLIDATED_REQUIREMENTS" "${CONSOLIDATED_REQUIREMENTS}.clean"
    
    echo "✅ Consolidated pip installation completed"
else
    echo "ℹ️ No requirements to install"
fi

echo "✅ Base ComfyUI components setup complete"