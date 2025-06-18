#!/bin/bash
# Health check with sync monitoring

echo "🏥 Running health check..."

# Check if ComfyUI is running
if curl -f http://localhost:3000 >/dev/null 2>&1; then
    echo "✅ ComfyUI is running"
else
    echo "❌ ComfyUI is not responding"
    exit 1
fi

# Check if sync daemon is running
if pgrep -f "sync_daemon.sh" >/dev/null; then
    echo "✅ Sync daemon is running"
else
    echo "⚠️ Sync daemon is not running, restarting..."
    nohup /workspace/sync_daemon.sh > /workspace/.sync_daemon.log 2>&1 &
fi

# Check last sync time
if [ -f "/workspace/.sync_log" ]; then
    last_sync=$(tail -1 /workspace/.sync_log | grep "Sync completed" | head -1)
    if [ -n "$last_sync" ]; then
        echo "✅ Last sync: $last_sync"
    else
        echo "⚠️ No recent sync found"
    fi
fi

echo "✅ Health check completed"
