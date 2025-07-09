#!/bin/bash
# Create all monitoring scripts

echo "📝 Creating monitoring scripts..."

# Set default script directory
export SCRIPT_DIR="${SCRIPT_DIR:-/scripts}"

# Log sync script
cat > "$NETWORK_VOLUME/scripts/sync_logs.sh" << 'EOF'
#!/bin/bash
# Sync logs to S3

LOG_DATE=$(date +%Y-%m-%d)
S3_LOG_BASE="s3://$AWS_BUCKET_NAME/pod_logs/$POD_ID/logs/$LOG_DATE"
LOCAL_LOG_DIR="/tmp/log_collection"

mkdir -p "$LOCAL_LOG_DIR"

# Collect logs
[ -f "$NETWORK_VOLUME/.startup.log" ] && cp "$NETWORK_VOLUME/.startup.log" "$LOCAL_LOG_DIR/"
[ -f "$NETWORK_VOLUME/.pod_tracker.log" ] && cp "$NETWORK_VOLUME/.pod_tracker.log" "$LOCAL_LOG_DIR/"
[ -f "$NETWORK_VOLUME/ComfyUI/comfyui.log" ] && cp "$NETWORK_VOLUME/ComfyUI/comfyui.log" "$LOCAL_LOG_DIR/"

# Collect user script logs (always include in every sync batch)
if [ -f "$NETWORK_VOLUME/.user-script-logs.log" ]; then
    # Create timestamped copy to preserve history
    TIMESTAMP=$(date +%H-%M-%S)
    cp "$NETWORK_VOLUME/.user-script-logs.log" "$LOCAL_LOG_DIR/user-script-logs-$TIMESTAMP.log"
    # Also include the main file
    cp "$NETWORK_VOLUME/.user-script-logs.log" "$LOCAL_LOG_DIR/"
fi

# Collect all sync logs
[ -f "$NETWORK_VOLUME/.sync_daemon.log" ] && cp "$NETWORK_VOLUME/.sync_daemon.log" "$LOCAL_LOG_DIR/"
[ -f "$NETWORK_VOLUME/.sync_shared_daemon.log" ] && cp "$NETWORK_VOLUME/.sync_shared_daemon.log" "$LOCAL_LOG_DIR/"
[ -f "$NETWORK_VOLUME/.log_sync.log" ] && cp "$NETWORK_VOLUME/.log_sync.log" "$LOCAL_LOG_DIR/"
[ -f "$NETWORK_VOLUME/.global_shared_sync_daemon.log" ] && cp "$NETWORK_VOLUME/.global_shared_sync_daemon.log" "$LOCAL_LOG_DIR/"
[ -f "$NETWORK_VOLUME/.comfyui_assets_sync_daemon.log" ] && cp "$NETWORK_VOLUME/.comfyui_assets_sync_daemon.log" "$LOCAL_LOG_DIR/"
[ -f "$NETWORK_VOLUME/.signal_handler.log" ] && cp "$NETWORK_VOLUME/.signal_handler.log" "$LOCAL_LOG_DIR/"
[ -f "$NETWORK_VOLUME/.model_discovery.log" ] && cp "$NETWORK_VOLUME/.model_discovery.log" "$LOCAL_LOG_DIR/"
[ -f "$NETWORK_VOLUME/.initial_model_sync.log" ] && cp "$NETWORK_VOLUME/.initial_model_sync.log" "$LOCAL_LOG_DIR/"

# Environment info
cat > "$LOCAL_LOG_DIR/environment.log" << ENVEOF
Timestamp: $(date)
Pod User: $POD_USER_NAME
Pod ID: $POD_ID
Network Volume: $NETWORK_VOLUME
GPU Info: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo "No GPU")
Browser Sessions: $([ -d "$NETWORK_VOLUME/ComfyUI/.browser-sessions" ] && echo "Enabled" || echo "Not Found")
Global Models: $([ -d "$NETWORK_VOLUME/ComfyUI/models" ] && echo "$(ls -1 "$NETWORK_VOLUME/ComfyUI/models" | wc -l) directories" || echo "Not Found")
ComfyUI Input: $([ -d "$NETWORK_VOLUME/ComfyUI/input" ] && echo "$(find "$NETWORK_VOLUME/ComfyUI/input" -type f | wc -l) files" || echo "Not Found")
ComfyUI Output: $([ -d "$NETWORK_VOLUME/ComfyUI/output" ] && echo "$(find "$NETWORK_VOLUME/ComfyUI/output" -type f | wc -l) files" || echo "Not Found")
ENVEOF

TIMESTAMP=$(date +%H-%M-%S)
aws s3 sync "$LOCAL_LOG_DIR" "$S3_LOG_BASE/$TIMESTAMP" --delete
rm -rf "$LOCAL_LOG_DIR"

echo "✅ Logs synced to S3"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_logs.sh"

echo "✅ Monitoring scripts created"
