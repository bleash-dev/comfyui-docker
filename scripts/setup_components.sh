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
else
    echo "ComfyUI virtual environment exists, checking integrity..."
    
    # Enhanced debugging for venv checking
    echo "📊 Venv Debug Info:"
    echo "  - Path: $COMFYUI_VENV"
    echo "  - Directory exists: $([ -d "$COMFYUI_VENV" ] && echo "YES" || echo "NO")"
    if [ -d "$COMFYUI_VENV" ]; then
        echo "  - Contents: $(ls -la "$COMFYUI_VENV" 2>/dev/null | wc -l) items"
        echo "  - bin/ exists: $([ -d "$COMFYUI_VENV/bin" ] && echo "YES" || echo "NO")"
        if [ -d "$COMFYUI_VENV/bin" ]; then
            echo "  - bin/ contents: $(ls "$COMFYUI_VENV/bin" 2>/dev/null | tr '\n' ' ')"
        fi
        echo "  - python exists: $([ -f "$COMFYUI_VENV/bin/python" ] && echo "YES" || echo "NO")"
        if [ -f "$COMFYUI_VENV/bin/python" ]; then
            echo "  - python target: $(readlink "$COMFYUI_VENV/bin/python" 2>/dev/null || echo "not a symlink")"
            echo "  - python executable: $([ -x "$COMFYUI_VENV/bin/python" ] && echo "YES" || echo "NO")"
        fi
    fi
    
    # Check if the venv Python interpreter exists and works
    if [ ! -f "$COMFYUI_VENV/bin/python" ] || ! "$COMFYUI_VENV/bin/python" --version >/dev/null 2>&1; then
        if [ ! -f "$COMFYUI_VENV/bin/python" ]; then
            echo "⚠️ Virtual environment Python executable missing"
        else
            echo "⚠️ Virtual environment Python executable broken"
            echo "    Error details: $("$COMFYUI_VENV/bin/python" --version 2>&1 || echo "Command failed completely")"
        fi
        echo "⚠️ Virtual environment is corrupted or incompatible, recreating..."
        rm -rf "$COMFYUI_VENV"
        mkdir -p "$(dirname "$COMFYUI_VENV")"
        $PYTHON_CMD -m venv "$COMFYUI_VENV"
        echo "✅ Virtual environment recreated successfully"
    else
        # Additional checks for venv integrity
        venv_python_version=$("$COMFYUI_VENV/bin/python" --version 2>&1 | awk '{print $2}' | cut -d'.' -f1,2)
        system_python_version=$($PYTHON_CMD --version 2>&1 | awk '{print $2}' | cut -d'.' -f1,2)
        
        echo "  - venv Python version: $venv_python_version"
        echo "  - system Python version: $system_python_version"
        
        if [ "$venv_python_version" != "$system_python_version" ]; then
            echo "⚠️ Virtual environment Python version ($venv_python_version) doesn't match system Python ($system_python_version), recreating..."
            rm -rf "$COMFYUI_VENV"
            mkdir -p "$(dirname "$COMFYUI_VENV")"
            $PYTHON_CMD -m venv "$COMFYUI_VENV"
            echo "✅ Virtual environment recreated with correct Python version"
        else
            # Additional check: verify pip works in the venv
            if ! "$COMFYUI_VENV/bin/python" -m pip --version >/dev/null 2>&1; then
                echo "⚠️ Virtual environment pip is broken (likely path issue), recreating..."
                echo "    Pip error: $("$COMFYUI_VENV/bin/python" -m pip --version 2>&1 || echo "Command failed")"
                rm -rf "$COMFYUI_VENV"
                mkdir -p "$(dirname "$COMFYUI_VENV")"
                $PYTHON_CMD -m venv "$COMFYUI_VENV"
                echo "✅ Virtual environment recreated successfully"
            else
                echo "✅ Virtual environment is healthy"
            fi
        fi
    fi
fi

# Ensure pip is working correctly in the venv
echo "🔧 Validating pip installation in virtual environment..."
. $COMFYUI_VENV/bin/activate

# Check if pip command exists and works
if ! command -v pip >/dev/null 2>&1 || ! pip --version >/dev/null 2>&1; then
    echo "⚠️ pip is not working, attempting to fix..."
    
    # Try to reinstall pip using ensurepip
    if python -m ensurepip --upgrade 2>/dev/null; then
        echo "✅ pip reinstalled via ensurepip"
    else
        echo "⚠️ ensurepip failed, trying alternative approach..."
        
        # Try to upgrade pip directly
        python -m pip install --upgrade pip --disable-pip-version-check 2>/dev/null || {
            echo "⚠️ pip upgrade failed, recreating venv..."
            deactivate
            rm -rf "$COMFYUI_VENV"
            mkdir -p "$(dirname "$COMFYUI_VENV")"
            $PYTHON_CMD -m venv "$COMFYUI_VENV"
            . $COMFYUI_VENV/bin/activate
            echo "✅ Virtual environment recreated"
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

# Add premium custom nodes if IS_PREMIUM is enabled
if [ "${IS_PREMIUM,,}" = "true" ]; then
    echo "🌟 Premium features enabled - adding premium custom nodes..."
    CUSTOM_NODES["ComfyUI-Copilot"]="https://github.com/gilons/ComfyUI-Copilot.git"
else
    echo "📦 Standard installation - premium nodes not included"
fi

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
    
    # Install user-specified PIP packages (after consolidated requirements)
    if [ -n "${PIP_PACKAGES:-}" ]; then
        USER_SCRIPT_LOG="$NETWORK_VOLUME/.user-script-logs.log"
        echo "📦 Installing user-specified PIP packages..." | tee -a "$USER_SCRIPT_LOG"
        echo "=== PIP PACKAGE INSTALLATION START - $(date) ===" >> "$USER_SCRIPT_LOG"
        echo "Requested packages: $PIP_PACKAGES" | tee -a "$USER_SCRIPT_LOG"
        
        # Convert comma-separated list to array
        IFS=',' read -ra PIP_ARRAY <<< "$PIP_PACKAGES"
        
        # Clean package names (remove spaces)
        CLEAN_PIP_PACKAGES=()
        for pkg in "${PIP_ARRAY[@]}"; do
            cleaned=$(echo "$pkg" | xargs)  # Remove leading/trailing spaces
            if [ -n "$cleaned" ]; then
                CLEAN_PIP_PACKAGES+=("$cleaned")
            fi
        done
        
        if [ ${#CLEAN_PIP_PACKAGES[@]} -gt 0 ]; then
            echo "Installing PIP packages: ${CLEAN_PIP_PACKAGES[*]}" | tee -a "$USER_SCRIPT_LOG"
            
            if pip install --no-cache-dir "${CLEAN_PIP_PACKAGES[@]}" >> "$USER_SCRIPT_LOG" 2>&1; then
                echo "✅ PIP packages installed successfully: ${CLEAN_PIP_PACKAGES[*]}" | tee -a "$USER_SCRIPT_LOG"
            else
                echo "❌ ERROR: Some PIP packages failed to install. Check log for details." | tee -a "$USER_SCRIPT_LOG"
                echo "⚠️ Continuing with startup despite PIP installation errors..." | tee -a "$USER_SCRIPT_LOG"
            fi
        else
            echo "⚠️ No valid PIP packages found after cleaning" | tee -a "$USER_SCRIPT_LOG"
        fi
        echo "=== PIP PACKAGE INSTALLATION END - $(date) ===" >> "$USER_SCRIPT_LOG"
        echo ""
    else
        echo "ℹ️ No user-specified PIP packages to install (PIP_PACKAGES not set)"
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

echo "✅ All components setup complete"
