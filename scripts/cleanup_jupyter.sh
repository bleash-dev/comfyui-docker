#!/bin/bash
# Cleanup script to remove all Jupyter-related configurations

echo "🧹 Cleaning up Jupyter configurations..."

# Set default network volume
export NETWORK_VOLUME="${NETWORK_VOLUME:-/workspace}"

# Remove Jupyter virtual environment
if [ -d "$NETWORK_VOLUME/venv/jupyter" ]; then
    echo "🗑️ Removing Jupyter virtual environment..."
    rm -rf "$NETWORK_VOLUME/venv/jupyter"
fi

# Remove Jupyter configuration directory
if [ -d "$NETWORK_VOLUME/.jupyter" ]; then
    echo "🗑️ Removing Jupyter configuration directory..."
    rm -rf "$NETWORK_VOLUME/.jupyter"
fi

# Remove Jupyter startup script if it exists
if [ -f "$NETWORK_VOLUME/start_jupyter" ]; then
    echo "🗑️ Removing Jupyter startup script..."
    rm -f "$NETWORK_VOLUME/start_jupyter"
fi

# Remove any Jupyter processes
echo "🔄 Stopping any running Jupyter processes..."
pkill -f "jupyter" 2>/dev/null || echo "ℹ️ No Jupyter processes found"

echo "✅ Jupyter cleanup completed"