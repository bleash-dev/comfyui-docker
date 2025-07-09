#!/bin/bash
# Start all background services (sync-only, no FUSE)

echo "🚀 Starting background services..."

# Set default sync intervals (in seconds) if not provided via environment
export SYNC_INTERVAL_USER_DATA="${SYNC_INTERVAL_USER_DATA:-60}"               # 5 minutes
export SYNC_INTERVAL_SHARED_DATA="${SYNC_INTERVAL_SHARED_DATA:-60}"     # 10 minutes
export SYNC_INTERVAL_GLOBAL_MODELS="${SYNC_INTERVAL_GLOBAL_MODELS:-60}" # 5 minutes
export SYNC_INTERVAL_LOGS="${SYNC_INTERVAL_LOGS:-60}"                   # 3 minutes

echo "📋 Sync intervals configured:"
echo "  📄 User data sync: every $((SYNC_INTERVAL_USER_DATA / 60)) minutes"
echo "  🔄 Shared data sync: every $((SYNC_INTERVAL_SHARED_DATA / 60)) minutes"
echo "  🌐 Global models sync: every $((SYNC_INTERVAL_GLOBAL_MODELS / 60)) minutes"
echo "  📊 Log sync: every $((SYNC_INTERVAL_LOGS / 60)) minutes"

# Create PID file for all background processes
BACKGROUND_PIDS_FILE="$NETWORK_VOLUME/.background_services.pids"
> "$BACKGROUND_PIDS_FILE"  # Clear the file

echo "📝 Background service PIDs will be tracked in: $BACKGROUND_PIDS_FILE"

# Create individual sync daemon scripts that can handle signals properly
cat > "$NETWORK_VOLUME/scripts/sync_daemon_runner.sh" << EOF
#!/bin/bash
# Individual sync daemon with proper signal handling

handle_sync_signal() {
    echo "📢 Sync daemon received signal, stopping..."
    exit 0
}

trap handle_sync_signal SIGTERM SIGINT SIGQUIT

while true; do
    "\$NETWORK_VOLUME/scripts/sync_user_data.sh" || echo "⚠️ Sync failed, continuing..."
    sleep $SYNC_INTERVAL_USER_DATA
done
EOF

cat > "$NETWORK_VOLUME/scripts/sync_shared_daemon_runner.sh" << EOF
#!/bin/bash
# Individual shared sync daemon with proper signal handling

handle_sync_shared_signal() {
    echo "📢 Shared sync daemon received signal, stopping..."
    exit 0
}

trap handle_sync_shared_signal SIGTERM SIGINT SIGQUIT

while true; do
    "\$NETWORK_VOLUME/scripts/sync_user_shared_data.sh" || echo "⚠️ Shared sync failed, continuing..."
    sleep $SYNC_INTERVAL_SHARED_DATA
done
EOF

cat > "$NETWORK_VOLUME/scripts/log_sync_daemon_runner.sh" << EOF
#!/bin/bash
# Individual log sync daemon with proper signal handling

handle_log_sync_signal() {
    echo "📢 Log sync daemon received signal, stopping..."
    exit 0
}

trap handle_log_sync_signal SIGTERM SIGINT SIGQUIT

while true; do
    "\$NETWORK_VOLUME/scripts/sync_logs.sh" || echo "⚠️ Log sync failed, continuing..."
    sleep $SYNC_INTERVAL_LOGS
done
EOF

cat > "$NETWORK_VOLUME/scripts/global_shared_sync_daemon_runner.sh" << EOF
#!/bin/bash
# Individual global shared sync daemon with proper signal handling

handle_global_sync_signal() {
    echo "📢 Global shared sync daemon received signal, stopping..."
    exit 0
}

trap handle_global_sync_signal SIGTERM SIGINT SIGQUIT

while true; do
    "\$NETWORK_VOLUME/scripts/sync_global_shared_models.sh" || echo "⚠️ Global shared sync failed, continuing..."
    sleep $SYNC_INTERVAL_GLOBAL_MODELS
done
EOF

cat > "$NETWORK_VOLUME/scripts/model_discovery_daemon_runner.sh" << EOF
#!/bin/bash
# Model discovery daemon with proper signal handling

handle_model_discovery_signal() {
    echo "📢 Model discovery daemon received signal, stopping..."
    exit 0
}

trap handle_model_discovery_signal SIGTERM SIGINT SIGQUIT

echo "✅ ComfyUI is ready, starting model discovery..."

# Run the model discovery script
"\$NETWORK_VOLUME/scripts/model_discovery.sh"
EOF

cat > "$NETWORK_VOLUME/scripts/comfyui_assets_sync_daemon_runner.sh" << EOF
#!/bin/bash
# ComfyUI assets sync daemon with proper signal handling

handle_assets_sync_signal() {
    echo "📢 ComfyUI assets sync daemon received signal, stopping..."
    exit 0
}

trap handle_assets_sync_signal SIGTERM SIGINT SIGQUIT

while true; do
    "\$NETWORK_VOLUME/scripts/sync_comfyui_assets.sh" || echo "⚠️ ComfyUI assets sync failed, continuing..."
    sleep $SYNC_INTERVAL_GLOBAL_MODELS
done
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_daemon_runner.sh"
chmod +x "$NETWORK_VOLUME/scripts/sync_shared_daemon_runner.sh"
chmod +x "$NETWORK_VOLUME/scripts/log_sync_daemon_runner.sh"
chmod +x "$NETWORK_VOLUME/scripts/global_shared_sync_daemon_runner.sh"
chmod +x "$NETWORK_VOLUME/scripts/comfyui_assets_sync_daemon_runner.sh"
chmod +x "$NETWORK_VOLUME/scripts/model_discovery_daemon_runner.sh"

# Start sync daemon for periodic data synchronization (pod-specific data)
nohup bash "$NETWORK_VOLUME/scripts/sync_daemon_runner.sh" > "$NETWORK_VOLUME/.sync_daemon.log" 2>&1 &
SYNC_PID=$!
echo "sync_daemon:$SYNC_PID" >> "$BACKGROUND_PIDS_FILE"
echo "  📄 Pod-specific data sync daemon started (PID: $SYNC_PID)"

# Start user-shared data sync daemon (less frequent)
nohup bash "$NETWORK_VOLUME/scripts/sync_shared_daemon_runner.sh" > "$NETWORK_VOLUME/.sync_shared_daemon.log" 2>&1 &
SYNC_SHARED_PID=$!
echo "sync_shared_daemon:$SYNC_SHARED_PID" >> "$BACKGROUND_PIDS_FILE"
echo "  🔄 User-shared data sync daemon started (PID: $SYNC_SHARED_PID)"

# Start signal handler for graceful shutdown
nohup "$NETWORK_VOLUME/scripts/signal_handler.sh" > "$NETWORK_VOLUME/.signal_handler.log" 2>&1 &
SIGNAL_HANDLER_PID=$!
echo "signal_handler:$SIGNAL_HANDLER_PID" >> "$BACKGROUND_PIDS_FILE"
echo "  📡 Signal handler started (PID: $SIGNAL_HANDLER_PID)"

# Start log sync daemon
nohup bash "$NETWORK_VOLUME/scripts/log_sync_daemon_runner.sh" > "$NETWORK_VOLUME/.log_sync.log" 2>&1 &
LOG_SYNC_PID=$!
echo "log_sync_daemon:$LOG_SYNC_PID" >> "$BACKGROUND_PIDS_FILE"
echo "  📊 Log sync daemon started (PID: $LOG_SYNC_PID)"

# Start global shared models sync daemon (every 5 minutes)
nohup bash "$NETWORK_VOLUME/scripts/global_shared_sync_daemon_runner.sh" > "$NETWORK_VOLUME/.global_shared_sync_daemon.log" 2>&1 &
GLOBAL_SHARED_SYNC_PID=$!
echo "global_shared_sync_daemon:$GLOBAL_SHARED_SYNC_PID" >> "$BACKGROUND_PIDS_FILE"
echo "  🌐 Global shared models sync daemon started (PID: $GLOBAL_SHARED_SYNC_PID)"

# Start ComfyUI assets sync daemon (same interval as global models)
nohup bash "$NETWORK_VOLUME/scripts/comfyui_assets_sync_daemon_runner.sh" > "$NETWORK_VOLUME/.comfyui_assets_sync_daemon.log" 2>&1 &
COMFYUI_ASSETS_SYNC_PID=$!
echo "comfyui_assets_sync_daemon:$COMFYUI_ASSETS_SYNC_PID" >> "$BACKGROUND_PIDS_FILE"
echo "  📁 ComfyUI assets sync daemon started (PID: $COMFYUI_ASSETS_SYNC_PID)"

# Start model discovery daemon
nohup bash "$NETWORK_VOLUME/scripts/model_discovery_daemon_runner.sh" > "$NETWORK_VOLUME/.model_discovery.log" 2>&1 &
MODEL_DISCOVERY_PID=$!
echo "model_discovery_daemon:$MODEL_DISCOVERY_PID" >> "$BACKGROUND_PIDS_FILE"
echo "  🔍 Model discovery daemon started (PID: $MODEL_DISCOVERY_PID)"

echo "✅ Background services started (sync-only mode)"
echo "  📄 Pod-specific data sync: every $((SYNC_INTERVAL_USER_DATA / 60)) minutes"
echo "  🔄 User-shared data sync: every $((SYNC_INTERVAL_SHARED_DATA / 60)) minutes"
echo "  🌐 Global shared models sync: every $((SYNC_INTERVAL_GLOBAL_MODELS / 60)) minutes (no delete)"
echo "  📊 Log sync: every $((SYNC_INTERVAL_LOGS / 60)) minutes"
echo "  � Model discovery: starts after ComfyUI is ready"
echo "  �📝 All PIDs stored in: $BACKGROUND_PIDS_FILE"
