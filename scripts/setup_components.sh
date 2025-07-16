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
REQUIREMENTS_CACHE_DIR="$NETWORK_VOLUME/ComfyUI/.requirements_cache"
REQUIREMENTS_HASH_FILE="$REQUIREMENTS_CACHE_DIR/last_requirements.hash"
INSTALLED_PACKAGES_FILE="$REQUIREMENTS_CACHE_DIR/installed_packages.txt"

# Ensure cache directory exists
mkdir -p "$REQUIREMENTS_CACHE_DIR"

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
        fi
    fi
else
    echo "Installing ComfyUI..."
    git clone $COMFYUI_GIT "$comfyui_dir"
    cd "$comfyui_dir"
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

echo "✅ Additional custom nodes setup complete"

# Function to calculate hash of all requirements sources
calculate_requirements_hash() {
    local hash_input=""
    
    # Include ComfyUI requirements if exists
    if [ -f "$comfyui_dir/requirements.txt" ]; then
        hash_input+="comfyui:$(cat "$comfyui_dir/requirements.txt" | sort)"
    fi
    
    # Include all custom node requirements
    for dir in "$custom_nodes_dir"/*; do
        if [ -d "$dir" ]; then
            dir_name=$(basename "$dir")
            requirements_file="$dir/requirements.txt"
            if [ -f "$requirements_file" ]; then
                hash_input+="${dir_name}:$(cat "$requirements_file" | sort)"
            fi
        fi
    done
    
    # Include user-specified packages
    hash_input+="user_packages:${PIP_PACKAGES:-}"
    
    # Include premium status (affects which nodes are installed)
    hash_input+="premium:$(echo "${IS_PREMIUM:-false}" | tr '[:upper:]' '[:lower:]')"
    
    # Include PyTorch version
    hash_input+="pytorch:${PYTORCH_VERSION:-2.4.0}"
    
    # Calculate SHA256 hash
    echo -n "$hash_input" | sha256sum | cut -d' ' -f1
}

# Function to check if packages need to be reinstalled
needs_package_install() {
    local current_hash
    local previous_hash=""
    
    # Calculate current requirements hash
    current_hash=$(calculate_requirements_hash)
    
    # Read previous hash if exists
    if [ -f "$REQUIREMENTS_HASH_FILE" ]; then
        previous_hash=$(cat "$REQUIREMENTS_HASH_FILE")
    fi
    
    # Check if venv has required core packages
    local venv_healthy=true
    if ! "$COMFYUI_VENV/bin/python" -c "import torch" 2>/dev/null; then
        echo "🔍 PyTorch not found in venv"
        venv_healthy=false
    fi
    
    if [ ! -f "$INSTALLED_PACKAGES_FILE" ]; then
        echo "🔍 No previous package installation record found"
        venv_healthy=false
    fi
    
    # Compare hashes
    if [ "$current_hash" != "$previous_hash" ]; then
        echo "🔍 Requirements composition changed:"
        echo "   Previous: ${previous_hash:-none}"
        echo "   Current:  $current_hash"
        return 0  # needs install
    elif [ "$venv_healthy" = false ]; then
        echo "🔍 Virtual environment missing core packages"
        return 0  # needs install
    else
        echo "✅ Requirements unchanged since last install (hash: ${current_hash:0:12}...)"
        return 1  # no install needed
    fi
}

# Function to save current requirements state
save_requirements_state() {
    local current_hash
    current_hash=$(calculate_requirements_hash)
    
    # Save hash
    echo "$current_hash" > "$REQUIREMENTS_HASH_FILE"
    
    # Save list of installed packages for debugging
    if [ -f "$COMFYUI_VENV/bin/python" ]; then
        "$COMFYUI_VENV/bin/python" -m pip list --format=freeze > "$INSTALLED_PACKAGES_FILE" 2>/dev/null || true
    fi
    
    echo "💾 Requirements state saved (hash: ${current_hash:0:12}...)"
}

# Function to clean up old cache if corrupted
cleanup_corrupted_cache() {
    if [ -f "$REQUIREMENTS_HASH_FILE" ] && [ ! -s "$REQUIREMENTS_HASH_FILE" ]; then
        echo "🧹 Removing corrupted cache file"
        rm -f "$REQUIREMENTS_HASH_FILE"
    fi
    
    if [ -f "$INSTALLED_PACKAGES_FILE" ] && [ ! -s "$INSTALLED_PACKAGES_FILE" ]; then
        echo "🧹 Removing corrupted packages file"
        rm -f "$INSTALLED_PACKAGES_FILE"
    fi
}

# Function to show cache status for debugging
show_cache_status() {
    echo "📊 Requirements Cache Status:"
    echo "   Cache directory: $REQUIREMENTS_CACHE_DIR"
    if [ -f "$REQUIREMENTS_HASH_FILE" ]; then
        local hash_age
        hash_age=$(stat -f%Sm "$REQUIREMENTS_HASH_FILE" 2>/dev/null || stat -c%y "$REQUIREMENTS_HASH_FILE" 2>/dev/null || echo "unknown")
        echo "   Last hash: $(cat "$REQUIREMENTS_HASH_FILE" | cut -c1-12)... (saved: $hash_age)"
    else
        echo "   Last hash: none"
    fi
    
    if [ -f "$INSTALLED_PACKAGES_FILE" ]; then
        local pkg_count
        pkg_count=$(cat "$INSTALLED_PACKAGES_FILE" | wc -l)
        echo "   Cached packages: $pkg_count"
    else
        echo "   Cached packages: none"
    fi
}

# Smart consolidated pip install - only install if requirements changed
echo "🔍 Checking if package installation is needed..."

# Clean up any corrupted cache files
cleanup_corrupted_cache

# Show current cache status for debugging
show_cache_status

# First, collect all requirements to build the hash
echo "📋 Collecting requirements from all sources..."

# Build consolidated requirements for hash calculation (and potential installation)
if [ -f "$comfyui_dir/requirements.txt" ]; then
    echo "# ComfyUI requirements" >> "$CONSOLIDATED_REQUIREMENTS"
    cat "$comfyui_dir/requirements.txt" >> "$CONSOLIDATED_REQUIREMENTS"
    echo "" >> "$CONSOLIDATED_REQUIREMENTS"
fi

for dir in "$custom_nodes_dir"/*; do
    if [ -d "$dir" ]; then
        dir_name=$(basename "$dir")
        requirements_file="$dir/requirements.txt"
        
        if [ -f "$requirements_file" ]; then
            echo "# $dir_name requirements" >> "$CONSOLIDATED_REQUIREMENTS"
            cat "$requirements_file" >> "$CONSOLIDATED_REQUIREMENTS"
            echo "" >> "$CONSOLIDATED_REQUIREMENTS"
        fi
    fi
done

# Check if installation is needed
if [ "${FORCE_REINSTALL_PACKAGES,,}" = "true" ]; then
    echo "🔄 FORCE_REINSTALL_PACKAGES=true - forcing package reinstallation"
    needs_install=true
elif needs_package_install; then
    needs_install=true
else
    needs_install=false
fi

if [ "$needs_install" = true ]; then
    if [ -s "$CONSOLIDATED_REQUIREMENTS" ]; then
        echo "🔄 Requirements changed - installing consolidated requirements..."
        install_start_time=$(date +%s)
        
        . $COMFYUI_VENV/bin/activate
        
        # Remove duplicates and empty lines
        sort "$CONSOLIDATED_REQUIREMENTS" | uniq | grep -v '^$' | grep -v '^#' > "${CONSOLIDATED_REQUIREMENTS}.clean"
        
        echo "📦 Installing $(cat "${CONSOLIDATED_REQUIREMENTS}.clean" | wc -l) unique requirements..."
        
        # Install all requirements at once
        if pip install --no-cache-dir -r "${CONSOLIDATED_REQUIREMENTS}.clean"; then
            echo "✅ Consolidated requirements installed successfully"
        else
            echo "⚠️ Some requirements failed to install, but continuing..."
        fi
        
        # Install PyTorch if needed
        if ! python -c "import torch" 2>/dev/null; then
            echo "📦 Installing PyTorch ${PYTORCH_VERSION:-2.4.0}..."
            pip install --no-cache-dir torch==${PYTORCH_VERSION:-2.4.0} torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
        else
            echo "✅ PyTorch already available"
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
        
        # Save the current requirements state after successful installation
        save_requirements_state
        
        deactivate
        
        install_end_time=$(date +%s)
        install_duration=$((install_end_time - install_start_time))
        echo "✅ Package installation completed in ${install_duration}s and state saved"
    else
        echo "ℹ️ No requirements found, but saving state anyway"
        save_requirements_state
    fi
else
    skip_start_time=$(date +%s)
    echo "🚀 Skipping package installation - no changes detected"
    echo "📊 Cached installation info:"
    if [ -f "$INSTALLED_PACKAGES_FILE" ]; then
        package_count=$(cat "$INSTALLED_PACKAGES_FILE" | wc -l)
        echo "   - $package_count packages previously installed"
        echo "   - Last updated: $(stat -f%Sm "$INSTALLED_PACKAGES_FILE" 2>/dev/null || stat -c%y "$INSTALLED_PACKAGES_FILE" 2>/dev/null || echo "unknown")"
    fi
    
    # Still run custom installation scripts even if pip packages haven't changed
    # (in case the scripts themselves have been updated)
    echo "🔧 Running custom installation scripts (scripts may have changed)..."
    . $COMFYUI_VENV/bin/activate
    
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
    
    skip_end_time=$(date +%s)
    skip_duration=$((skip_end_time - skip_start_time))
    echo "✅ Custom scripts completed in ${skip_duration}s (skipped package installation)"
fi

# Cleanup temporary files
rm -f "$CONSOLIDATED_REQUIREMENTS" "${CONSOLIDATED_REQUIREMENTS}.clean"

echo "✅ All components setup complete"
echo "🔧 Smart requirements caching enabled"
echo "   💡 Tip: Set FORCE_REINSTALL_PACKAGES=true to force reinstallation"
echo "   📁 Cache location: $REQUIREMENTS_CACHE_DIR"
