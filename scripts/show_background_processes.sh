#!/bin/bash
# Show all background processes related to the container

echo "🔍 Showing all background processes..."

# Set default network volume
export NETWORK_VOLUME="${NETWORK_VOLUME:-/workspace}"

echo "📋 Active background service PIDs:"
BACKGROUND_PIDS_FILE="$NETWORK_VOLUME/.background_services.pids"
if [ -f "$BACKGROUND_PIDS_FILE" ]; then
    while IFS=':' read -r service_name pid; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "  ✅ $service_name (PID: $pid) - RUNNING"
            echo "      $(ps -p $pid -o args= 2>/dev/null || echo 'Process details unavailable')"
        else
            echo "  ❌ $service_name (PID: $pid) - NOT RUNNING"
        fi
    done < "$BACKGROUND_PIDS_FILE"
else
    echo "  ⚠️ No PID file found at $BACKGROUND_PIDS_FILE"
fi

echo ""
echo "🔍 All processes containing 'sync':"
ps aux | grep -E "(sync|daemon)" | grep -v grep | while IFS= read -r line; do
    echo "  $line"
done

echo ""
echo "🔍 All processes from $NETWORK_VOLUME:"
ps aux | grep "$NETWORK_VOLUME" | grep -v grep | while IFS= read -r line; do
    echo "  $line"
done

echo ""
echo "🔍 Nohup processes:"
ps aux | grep nohup | grep -v grep | while IFS= read -r line; do
    echo "  $line"
done

echo ""
echo "💡 To kill specific processes:"
echo "   Individual: kill -9 <PID>"
echo "   All sync:   pkill -f sync"
echo "   All daemon: pkill -f daemon"
echo "   Cleanup:    $NETWORK_VOLUME/scripts/stop_background_services.sh"
