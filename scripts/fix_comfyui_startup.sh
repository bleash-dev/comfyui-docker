#!/bin/bash
# Create corrected ComfyUI startup script

NETWORK_VOLUME="${NETWORK_VOLUME:-/workspace}"

cat > "$NETWORK_VOLUME/start_comfyui_with_logs.sh" << 'EOF'
#!/bin/bash
# ComfyUI startup wrapper with comprehensive logging

echo "🚀 Starting ComfyUI with comprehensive logging..."

# Set defaults
export NETWORK_VOLUME="${NETWORK_VOLUME:-/workspace}"
export COMFYUI_VENV="$NETWORK_VOLUME/venv/comfyui"
export LOG_DIR="$NETWORK_VOLUME/logs"

# Create log directory
mkdir -p "$LOG_DIR"

# Generate log filename with timestamp
LOG_FILE="$LOG_DIR/comfyui_$(date +%Y%m%d_%H%M%S).log"

echo "📁 Logs will be saved to: $LOG_FILE"

# Activate ComfyUI virtual environment
if [ -f "$COMFYUI_VENV/bin/activate" ]; then
    echo "🔄 Activating ComfyUI virtual environment..."
    . "$COMFYUI_VENV/bin/activate"
else
    echo "❌ ComfyUI virtual environment not found at $COMFYUI_VENV"
    echo "   Make sure setup_components.sh has been run successfully"
    echo "   Expected path: $COMFYUI_VENV/bin/activate"
    echo "   Current NETWORK_VOLUME: $NETWORK_VOLUME"
    exit 1
fi

# Change to ComfyUI directory
if [ -d "$NETWORK_VOLUME/ComfyUI" ]; then
    cd "$NETWORK_VOLUME/ComfyUI"
else
    echo "❌ ComfyUI directory not found at $NETWORK_VOLUME/ComfyUI"
    exit 1
fi

# Start ComfyUI with logging
echo "🎨 Starting ComfyUI server..."
python main.py \
    --listen 0.0.0.0 \
    --port 8188 \
    --output-directory "$NETWORK_VOLUME/ComfyUI/output" \
    --input-directory "$NETWORK_VOLUME/ComfyUI/input" \
    --extra-model-paths-config "$NETWORK_VOLUME/ComfyUI/extra_model_paths.yaml" \
    2>&1 | tee "$LOG_FILE"
EOF

chmod +x "$NETWORK_VOLUME/start_comfyui_with_logs.sh"
echo "✅ Created corrected start_comfyui_with_logs.sh script"