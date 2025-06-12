#!/bin/bash
# set -euo pipefail

# Move to script's directory to ensure relative paths work
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Detect network volume location
NETWORK_VOLUME=""

if mountpoint -q /workspace 2>/dev/null || [ -w "/workspace" ]; then
    NETWORK_VOLUME="/workspace"
if [ -d "/runpod-volume" ]; then
    NETWORK_VOLUME="/runpod-volume"
fi

# Require network volume venv
if [ -n "$NETWORK_VOLUME" ] && [ -d "$NETWORK_VOLUME/venv/comfyui" ]; then
    export COMFYUI_VENV="$NETWORK_VOLUME/venv/comfyui"
    export PIP_CACHE_DIR="$NETWORK_VOLUME/pip_cache"
    echo "Using persistent virtual environment: $COMFYUI_VENV"
    . $COMFYUI_VENV/bin/activate
else
    echo "❌ No network volume virtual environment found!"
    echo "This script requires a persistent virtual environment in the network volume."
    exit 1
fi

cd /workspace/ComfyUI/custom_nodes

# Read and install nodes from nodes.txt
if [ -f "../nodes.txt" ]; then
    while IFS= read -r repo; do
        # Skip empty lines and comments
        [[ -z "$repo" || "$repo" =~ ^#.*$ ]] && continue
        
        # Extract repo name from URL
        repo_name=$(basename "$repo" .git)
        
        echo "Installing $repo_name..."
        if [ -d "$repo_name" ]; then
            echo "$repo_name already exists, updating..."
            cd "$repo_name"
            git pull
            cd ..
        else
            git clone "$repo"
        fi
        
        # Install requirements if they exist
        if [ -f "$repo_name/requirements.txt" ]; then
            echo "Installing requirements for $repo_name"
            pip3 install --cache-dir="${PIP_CACHE_DIR:-/tmp/pip}" -r "$repo_name/requirements.txt"
        fi
    done < "../nodes.txt"
else
    echo "No nodes.txt file found, skipping custom node installation"
fi

echo "✅ Custom node installation complete"