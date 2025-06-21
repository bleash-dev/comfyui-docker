#!/bin/bash
# Health check with sync monitoring (no FUSE dependencies)

echo "🏥 Running health check..."

# Check if ComfyUI is running
if curl -f http://localhost:8080 >/dev/null 2>&1; then
    echo "✅ ComfyUI is running"
else
    echo "❌ ComfyUI is not responding"
    exit 1
fi

# Check background services using PID file
BACKGROUND_PIDS_FILE="$NETWORK_VOLUME/.background_services.pids"
if [ -f "$BACKGROUND_PIDS_FILE" ]; then
    echo "🔍 Checking background services from PID file..."
    services_running=0
    services_total=0
    
    while IFS=':' read -r service_name pid; do
        services_total=$((services_total + 1))
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "✅ $service_name (PID: $pid) is running"
            services_running=$((services_running + 1))
        else
            echo "❌ $service_name (PID: $pid) is not running"
        fi
    done < "$BACKGROUND_PIDS_FILE"
    
    if [ $services_running -eq $services_total ]; then
        echo "✅ All background services are running ($services_running/$services_total)"
    else
        echo "⚠️ Some background services are down ($services_running/$services_total)"
        echo "   Consider restarting background services"
    fi
else
    echo "⚠️ No background services PID file found"
    # Fallback check
    if pgrep -f "sync.*daemon" >/dev/null; then
        echo "✅ Some sync processes detected (fallback check)"
    else
        echo "❌ No sync daemons detected"
    fi
fi

# Check S3 connectivity instead of mount status
if aws s3 ls "s3://$AWS_BUCKET_NAME/" >/dev/null 2>&1; then
    echo "✅ S3 connectivity working"
else
    echo "⚠️ S3 connectivity issues detected"
fi

# Check last sync time
if [ -f "$NETWORK_VOLUME/.sync_daemon.log" ]; then
    last_sync=$(tail -5 "$NETWORK_VOLUME/.sync_daemon.log" | grep "User data sync completed" | tail -1)
    if [ -n "$last_sync" ]; then
        echo "✅ Recent sync activity detected"
    else
        echo "⚠️ No recent sync activity found"
    fi
fi

echo "✅ Health check completed"
