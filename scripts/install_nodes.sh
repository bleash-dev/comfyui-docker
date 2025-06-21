#!/bin/bash
# Custom node installation with consolidated requirements

# Move to script's directory to ensure relative paths work
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Set default Python version
export PYTHON_VERSION="${PYTHON_VERSION:-3.10}"
export PYTHON_CMD="${PYTHON_CMD:-python${PYTHON_VERSION}}"

echo "📝 Using Python: $PYTHON_CMD ($($PYTHON_CMD --version))"

# Get consolidated requirements file path from argument
CONSOLIDATED_REQUIREMENTS="${1:-/tmp/consolidated_requirements.txt}"

# Check if nodes.txt exists
if [ -f "$NETWORK_VOLUME/ComfyUI/nodes.txt" ]; then
    echo "📋 Installing custom nodes from nodes.txt..."
    
    # Move to custom nodes directory
    cd "$NETWORK_VOLUME/ComfyUI/custom_nodes" || exit 1
    
    # Process each line in nodes.txt
    while IFS= read -r repo_url; do
        # Skip empty lines and comments
        [[ -z "$repo_url" || "$repo_url" =~ ^[[:space:]]*# ]] && continue
        
        echo "📦 Processing repository: $repo_url"
        
        # Extract repository name from URL
        repo_name=$(basename "$repo_url" .git)
        
        # Clone or update repository
        if [ -d "$repo_name" ]; then
            echo "Directory $repo_name already exists. Updating..."
            cd "$repo_name"
            git pull || echo "⚠️ Git pull failed for $repo_name"
            cd ..
        else
            echo "Cloning $repo_name..."
            git clone "$repo_url" || echo "⚠️ Git clone failed for $repo_url"
        fi
        
        # Add requirements to consolidated file if they exist
        if [ -f "$repo_name/requirements.txt" ]; then
            echo "Adding requirements from $repo_name to consolidated file"
            echo "# $repo_name requirements" >> "$CONSOLIDATED_REQUIREMENTS"
            cat "$repo_name/requirements.txt" >> "$CONSOLIDATED_REQUIREMENTS"
            echo "" >> "$CONSOLIDATED_REQUIREMENTS"
        fi
        
    done < "$NETWORK_VOLUME/ComfyUI/nodes.txt"
    
    echo "✅ Custom node repositories processed (requirements added to consolidated file)"
else
    echo "ℹ️ No nodes.txt file found, skipping custom node installation"
fi

echo "✅ Custom node installation complete"