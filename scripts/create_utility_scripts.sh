#!/bin/bash
# Create utility scripts

echo "📝 Creating utility scripts..."

# Set default script directory, Python version, and config root
export SCRIPT_DIR="${SCRIPT_DIR:-/scripts}"
export PYTHON_VERSION="${PYTHON_VERSION:-3.10}"
export PYTHON_CMD="${PYTHON_CMD:-python${PYTHON_VERSION}}"
export CONFIG_ROOT="${CONFIG_ROOT:-/root}"
export COMFYUI_VENV="$NETWORK_VOLUME/venv/comfyui"

# Analytics shortcut
cat > "$NETWORK_VOLUME/analytics" << EOF
#!/bin/bash
bash "$SCRIPT_DIR/execution_analytics.sh" "\$@"
EOF

chmod +x "$NETWORK_VOLUME/analytics"

# ComfyUI startup wrapper
cat > "$NETWORK_VOLUME/start_comfyui_with_logs.sh" << EOF
#!/bin/bash
# ComfyUI startup wrapper with logging

COMFYUI_LOG="$NETWORK_VOLUME/ComfyUI/comfyui.log"
COMFYUI_ERROR_LOG="$NETWORK_VOLUME/ComfyUI/comfyui_error.log"

# Set Python version and config variables
export PYTHON_VERSION="${PYTHON_VERSION:-${PYTHON_VERSION}}"
export PYTHON_CMD="${PYTHON_CMD:-python${PYTHON_VERSION}}"
export CONFIG_ROOT="${CONFIG_ROOT:-${CONFIG_ROOT}}"

echo "🚀 Starting ComfyUI with logging at $(date)"
echo "📝 Using Python: $PYTHON_CMD ($($PYTHON_CMD --version))"
echo "📁 Using Config Root: $CONFIG_ROOT"

cd $NETWORK_VOLUME/ComfyUI
. $COMFYUI_VENV/bin/activate

$PYTHON_CMD main.py --listen 0.0.0.0 --port 8080 --enable-cors-header "*" \\
    > >(tee -a "$COMFYUI_LOG") \\
    2> >(tee -a "$COMFYUI_ERROR_LOG" >&2)
EOF

chmod +x "$NETWORK_VOLUME/start_comfyui_with_logs.sh"

echo "✅ Utility scripts created"
