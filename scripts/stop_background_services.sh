#!/bin/bash
# Manual script to stop background services

echo "🛑 Manually stopping background services..."

# Set default network volume
export NETWORK_VOLUME="${NETWORK_VOLUME:-/workspace}"

# Stop models config file watcher first
echo "🔍 Stopping models config file watcher..."
if [ -f "$NETWORK_VOLUME/scripts/models_config_watcher.sh" ]; then
    "$NETWORK_VOLUME/scripts/models_config_watcher.sh" stop
    if [ $? -eq 0 ]; then
        echo "✅ Models config file watcher stopped successfully"
    else
        echo "⚠️ Failed to stop models config file watcher gracefully"
    fi
else
    echo "⚠️ Models config file watcher script not found"
fi

# Method 1: Use PID file if it exists
BACKGROUND_PIDS_FILE="$NETWORK_VOLUME/.background_services.pids"
if [ -f "$BACKGROUND_PIDS_FILE" ]; then
    echo "🔄 Reading PIDs from: $BACKGROUND_PIDS_FILE"
    while IFS=':' read -r service_name pid; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "  Stopping $service_name (PID: $pid)..."
            kill -TERM "$pid" 2>/dev/null || true
            sleep 1
            # Force kill if still running
            if kill -0 "$pid" 2>/dev/null; then
                echo "  Force killing $service_name (PID: $pid)..."
                kill -9 "$pid" 2>/dev/null || true
            fi
        else
            echo "  $service_name (PID: $pid) already stopped or invalid"
        fi
    done < "$BACKGROUND_PIDS_FILE"
    rm -f "$BACKGROUND_PIDS_FILE"
    echo "✅ PID file method completed"
else
    echo "⚠️ No background services PID file found at $BACKGROUND_PIDS_FILE"
fi

# Method 2: Kill by process pattern matching
echo "🔍 Using pattern matching to find and kill lingering processes..."

# Kill sync daemon runners
echo "  Stopping sync daemon runners..."
pkill -f "sync_daemon_runner.sh" 2>/dev/null && echo "    ✅ Killed sync_daemon_runner processes" || echo "    ℹ️ No sync_daemon_runner processes found"
pkill -f "sync_shared_daemon_runner.sh" 2>/dev/null && echo "    ✅ Killed sync_shared_daemon_runner processes" || echo "    ℹ️ No sync_shared_daemon_runner processes found"
pkill -f "log_sync_daemon_runner.sh" 2>/dev/null && echo "    ✅ Killed log_sync_daemon_runner processes" || echo "    ℹ️ No log_sync_daemon_runner processes found"

# Kill signal handler
echo "  Stopping signal handler..."
pkill -f "signal_handler.sh" 2>/dev/null && echo "    ✅ Killed signal_handler processes" || echo "    ℹ️ No signal_handler processes found"

# Kill any processes running sync scripts
echo "  Stopping any sync script processes..."
pkill -f "sync_user_data.sh" 2>/dev/null && echo "    ✅ Killed sync_user_data processes" || echo "    ℹ️ No sync_user_data processes found"
pkill -f "sync_user_shared_data.sh" 2>/dev/null && echo "    ✅ Killed sync_user_shared_data processes" || echo "    ℹ️ No sync_user_shared_data processes found"
pkill -f "sync_logs.sh" 2>/dev/null && echo "    ✅ Killed sync_logs processes" || echo "    ℹ️ No sync_logs processes found"

# Kill pod tracker
echo "  Stopping pod execution tracker..."
pkill -f "pod_execution_tracker.sh" 2>/dev/null && echo "    ✅ Killed pod_execution_tracker processes" || echo "    ℹ️ No pod_execution_tracker processes found"

# Method 3: Kill by parent directory pattern
echo "  Stopping processes from $NETWORK_VOLUME/scripts/..."
pkill -f "$NETWORK_VOLUME/scripts/" 2>/dev/null && echo "    ✅ Killed processes from scripts directory" || echo "    ℹ️ No processes from scripts directory found"

# Method 4: Show any remaining background processes for manual inspection
echo "🔍 Checking for any remaining related processes..."
echo "Processes containing 'sync':"
pgrep -f sync | while read pid; do
    if kill -0 "$pid" 2>/dev/null; then
        echo "  PID $pid: $(ps -p $pid -o args= 2>/dev/null || echo 'Process info unavailable')"
    fi
done

echo "Processes containing 'daemon':"
pgrep -f daemon | while read pid; do
    if kill -0 "$pid" 2>/dev/null; then
        echo "  PID $pid: $(ps -p $pid -o args= 2>/dev/null || echo 'Process info unavailable')"
    fi
done

echo "Processes from $NETWORK_VOLUME:"
pgrep -f "$NETWORK_VOLUME" | while read pid; do
    if kill -0 "$pid" 2>/dev/null; then
        echo "  PID $pid: $(ps -p $pid -o args= 2>/dev/null || echo 'Process info unavailable')"
    fi
done

echo "✅ Background service cleanup completed"
echo ""
echo "💡 If you see any remaining processes above that need to be killed manually:"
echo "   Use: kill -9 <PID>"
echo "   Or:  sudo kill -9 <PID> (if permission denied)"
