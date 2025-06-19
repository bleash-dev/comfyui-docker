#!/bin/bash
# Create utility scripts

echo "📝 Creating utility scripts..."

# Analytics shortcut
cat > "$NETWORK_VOLUME/analytics" << 'EOF'
#!/bin/bash
bash "/scripts/execution_analytics.sh" "$@"
EOF

chmod +x "$NETWORK_VOLUME/analytics"

# ComfyUI startup wrapper
cat > "$NETWORK_VOLUME/start_comfyui_with_logs.sh" << 'EOF'
#!/bin/bash
# ComfyUI startup wrapper with logging

COMFYUI_LOG="$NETWORK_VOLUME/ComfyUI/comfyui.log"
COMFYUI_ERROR_LOG="$NETWORK_VOLUME/ComfyUI/comfyui_error.log"

echo "🚀 Starting ComfyUI with logging at $(date)"

cd $NETWORK_VOLUME/ComfyUI
. $COMFYUI_VENV/bin/activate

python main.py --listen 0.0.0.0 --port 3000 --enable-cors-header \
    > >(tee -a "$COMFYUI_LOG") \
    2> >(tee -a "$COMFYUI_ERROR_LOG" >&2)
EOF

chmod +x "$NETWORK_VOLUME/start_comfyui_with_logs.sh"

echo "✅ Utility scripts created"
