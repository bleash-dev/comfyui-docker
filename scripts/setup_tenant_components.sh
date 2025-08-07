#!/bin/bash
set -eo pipefail

echo "🏠 Setting up tenant-specific ComfyUI components..."

# Validate environment variables
required_vars=("NETWORK_VOLUME" "POD_USER_NAME" "POD_ID")
for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then 
        echo "❌ ERROR: Required environment variable $var is not set."
        exit 1
    fi
done

# Set centralized venv path from environment (set by start_tenant.sh)
export BASE_VENV_PATH="${BASE_VENV_PATH:-/base/venv/comfyui}"
export BASE_COMFYUI_PATH="${BASE_COMFYUI_PATH:-/base/ComfyUI}"
export TENANT_COMFYUI_PATH="$NETWORK_VOLUME/ComfyUI"

echo "📍 Base Virtual environment: $BASE_VENV_PATH"
echo "📍 Base ComfyUI installation: $BASE_COMFYUI_PATH"
echo "📍 Tenant ComfyUI path: $TENANT_COMFYUI_PATH"

# Validate base installation exists
if [ ! -f "$BASE_VENV_PATH/bin/python" ]; then
    echo "❌ ERROR: Base virtual environment not found at $BASE_VENV_PATH"
    echo "   This AMI was not properly built with the new architecture."
    exit 1
fi

if [ ! "$BASE_VENV_PATH/bin/python" --version >/dev/null 2>&1]; then
    echo "❌ ERROR: Base virtual environment is not functional"
    exit 1
fi

if [ ! -d "$BASE_COMFYUI_PATH" ]; then
    echo "❌ ERROR: Base ComfyUI installation not found at $BASE_COMFYUI_PATH"
    echo "   This AMI was not properly built with the new architecture."
    exit 1
fi

echo "✅ Base installation validation successful"

# Validate tenant ComfyUI exists (should have been copied by sync script)
if [ ! -d "$TENANT_COMFYUI_PATH" ]; then
    echo "❌ ERROR: Tenant ComfyUI installation not found at $TENANT_COMFYUI_PATH"
    echo "   The sync script should have copied from base installation."
    exit 1
fi

if [ ! -f "$TENANT_COMFYUI_PATH/main.py" ]; then
    echo "❌ ERROR: Tenant ComfyUI installation is incomplete (missing main.py)"
    exit 1
fi

echo "✅ Tenant ComfyUI installation validation successful"

# Create tenant configuration directory
tenant_config_dir="$NETWORK_VOLUME/.comfyui"
mkdir -p "$tenant_config_dir"
echo "✅ Tenant configuration directory created: $tenant_config_dir"

# Check for tenant-specific custom nodes and install their dependencies
custom_nodes_dir="$TENANT_COMFYUI_PATH/custom_nodes"
if [ -d "$custom_nodes_dir" ]; then
    echo "🔧 Processing tenant custom nodes dependencies..."
    
    # Create consolidated requirements file for tenant-specific packages
    TENANT_REQUIREMENTS="$NETWORK_VOLUME/tmp/tenant_requirements_${POD_ID}.txt"
    > "$TENANT_REQUIREMENTS"  # Clear file
    
    # Scan custom node directories for requirements files
    echo "🔍 Scanning custom node directories for requirements..."
    found_requirements=false
    
    for dir in "$custom_nodes_dir"/*; do
        if [ -d "$dir" ]; then
            dir_name=$(basename "$dir")
            requirements_file="$dir/requirements.txt"
            
            # Skip if requirements.txt doesn't exist
            if [ ! -f "$requirements_file" ]; then
                continue
            fi
            
            echo "📋 Found requirements in $dir_name"
            echo "# $dir_name requirements" >> "$TENANT_REQUIREMENTS"
            cat "$requirements_file" >> "$TENANT_REQUIREMENTS"
            echo "" >> "$TENANT_REQUIREMENTS"
            found_requirements=true
        fi
    done
    
    # Install consolidated requirements if any were found
    if [ "$found_requirements" = true ] && [ -s "$TENANT_REQUIREMENTS" ]; then
        echo "🔄 Installing tenant custom node dependencies..."
        
        # Activate base virtual environment
        source "$BASE_VENV_PATH/bin/activate"
        
        # Remove duplicates and empty lines, filter out comments
        sort "$TENANT_REQUIREMENTS" | uniq | grep -v '^$' | grep -v '^#' > "${TENANT_REQUIREMENTS}.clean"
        
        if [ -s "${TENANT_REQUIREMENTS}.clean" ]; then
            echo "📦 Installing consolidated requirements..."
            if pip install --no-cache-dir -r "${TENANT_REQUIREMENTS}.clean"; then
                echo "✅ Tenant custom node dependencies installed successfully"
            else
                echo "⚠️ Some dependencies failed to install, but continuing..."
            fi
        else
            echo "ℹ️ No valid requirements found after cleaning"
        fi
        
        deactivate
        
        # Cleanup
        rm -f "$TENANT_REQUIREMENTS" "${TENANT_REQUIREMENTS}.clean"
    else
        echo "ℹ️ No custom node requirements found for tenant"
    fi
    
    # Handle premium features for non-premium users
    if [ "${IS_PREMIUM,,}" != "true" ]; then
        echo "📦 Non-premium user detected - removing premium-only custom nodes..."
        
        # List of premium-only custom nodes
        premium_nodes=("ComfyUI-Copilot")
        
        for premium_node in "${premium_nodes[@]}"; do
            premium_node_dir="$custom_nodes_dir/$premium_node"
            if [ -d "$premium_node_dir" ]; then
                echo "🗑️ Removing premium node: $premium_node"
                rm -rf "$premium_node_dir"
                echo "✅ Removed $premium_node (not available for non-premium users)"
            fi
        done
    else
        echo "🌟 Premium user - all custom nodes available"
    fi
    
else
    echo "ℹ️ No custom nodes directory found, skipping dependency installation"
fi

# Install user-specified PIP packages if provided
if [ -n "${PIP_PACKAGES:-}" ]; then
    echo "📦 Installing user-specified PIP packages..."
    
    USER_SCRIPT_LOG="$NETWORK_VOLUME/.user-script-logs.log"
    echo "=== TENANT PIP PACKAGE INSTALLATION START - $(date) ===" >> "$USER_SCRIPT_LOG"
    echo "Requested packages: $PIP_PACKAGES" | tee -a "$USER_SCRIPT_LOG"
    
    # Activate base virtual environment
    source "$BASE_VENV_PATH/bin/activate"
    
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
            echo "✅ User PIP packages installed successfully: ${CLEAN_PIP_PACKAGES[*]}" | tee -a "$USER_SCRIPT_LOG"
        else
            echo "❌ ERROR: Some user PIP packages failed to install. Check log for details." | tee -a "$USER_SCRIPT_LOG"
            echo "⚠️ Continuing with startup despite PIP installation errors..." | tee -a "$USER_SCRIPT_LOG"
        fi
    else
        echo "⚠️ No valid PIP packages found after cleaning" | tee -a "$USER_SCRIPT_LOG"
    fi
    
    deactivate
    echo "=== TENANT PIP PACKAGE INSTALLATION END - $(date) ===" >> "$USER_SCRIPT_LOG"
else
    echo "ℹ️ No user-specified PIP packages to install (PIP_PACKAGES not set)"
fi
echo "🔍 Detecting GPU availability..."
HAS_GPU=false
GPU_VENDOR="none"

# Check for nvidia-smi (NVIDIA GPUs)
if command -v nvidia-smi >/dev/null 2>&1; then
    if nvidia-smi >/dev/null 2>&1; then
        echo "✅ NVIDIA GPU detected"
        HAS_GPU=true
        GPU_VENDOR="nvidia"
    else
        echo "⚠️ nvidia-smi found but not working properly"
    fi
else
    echo "ℹ️ nvidia-smi not found"
fi

# Configure ComfyUI accordingly
if [ "$HAS_GPU" = false ]; then
    echo "🖥️ Configuring ComfyUI for CPU-only mode..."
    GPU_CONFIG="
# Force CPU-only mode
export CUDA_VISIBLE_DEVICES=\"\"
export FORCE_CUDA=\"0\"
export PYTORCH_CUDA_ALLOC_CONF=\"\"
export COMFYUI_CPU_ONLY=\"1\""
else
    echo "🚀 Configuring ComfyUI for GPU ($GPU_VENDOR) mode..."
    GPU_CONFIG="
# GPU mode configuration
export PYTORCH_CUDA_ALLOC_CONF=\"expandable_segments:True\""
fi