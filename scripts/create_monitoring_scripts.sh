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
S3_LOG_BASE="s3://$AWS_BUCKET_NAME/pod_logs/$POD_USER_NAME/logs/$LOG_DATE"
LOCAL_LOG_DIR="/tmp/log_collection"

mkdir -p "$LOCAL_LOG_DIR"

# Collect logs
[ -f "$NETWORK_VOLUME/.startup.log" ] && cp "$NETWORK_VOLUME/.startup.log" "$LOCAL_LOG_DIR/"
[ -f "$NETWORK_VOLUME/.pod_tracker.log" ] && cp "$NETWORK_VOLUME/.pod_tracker.log" "$LOCAL_LOG_DIR/"
[ -f "$NETWORK_VOLUME/ComfyUI/comfyui.log" ] && cp "$NETWORK_VOLUME/ComfyUI/comfyui.log" "$LOCAL_LOG_DIR/"

# Environment info
cat > "$LOCAL_LOG_DIR/environment.log" << ENVEOF
Timestamp: $(date)
Pod User: $POD_USER_NAME
Pod ID: $POD_ID
Network Volume: $NETWORK_VOLUME
GPU Info: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo "No GPU")
ENVEOF

TIMESTAMP=$(date +%H-%M-%S)
aws s3 sync "$LOCAL_LOG_DIR" "$S3_LOG_BASE/$TIMESTAMP" --delete
rm -rf "$LOCAL_LOG_DIR"

echo "✅ Logs synced to S3"
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_logs.sh"

echo "✅ Monitoring scripts created"
