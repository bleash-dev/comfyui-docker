#!/bin/bash
# Pod execution duration and metrics tracker

echo "🕐 Starting Pod Execution Tracker..."

# Validate required environment variables
required_vars=("AWS_BUCKET_NAME" "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_REGION" "POD_USER_NAME" "POD_ID" "NETWORK_VOLUME")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ Required tracking variable $var is not set"
        if [ "$var" = "POD_ID" ]; then
            echo "POD_ID is required for pod-specific data isolation"
        elif [ "$var" = "NETWORK_VOLUME" ]; then
            echo "NETWORK_VOLUME should have been set by start.sh"
        fi
        exit 1
    fi
done

# Define tracking paths
TRACKING_DIR="$NETWORK_VOLUME/.pod_tracking"
LOCAL_TRACKING_FILE="$TRACKING_DIR/current_session.json"
S3_TRACKING_BASE="s3:$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID"
S3_SESSION_FILE="$S3_TRACKING_BASE/_pod_tracking/session.json"
S3_SUMMARY_FILE="$S3_TRACKING_BASE/_pod_tracking/execution_summary.json"

mkdir -p "$TRACKING_DIR"

# Get startup timestamp
START_TIME=$(date +%s)
START_ISO=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)

echo "📊 Tracking: Pod $POD_ID, User $POD_USER_NAME, Start: $START_ISO"

# Detect pod information
detect_pod_info() {
    local pod_type="cpu"
    local gpu_info="none"
    local instance_type="${THIS_POD_TEMPLATE_ID:-unknown}"
    
    if command -v nvidia-smi &> /dev/null; then
        gpu_info=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits | head -1 | tr ',' '-' | tr ' ' '_')
        pod_type="gpu"
    fi
    
    echo "$pod_type,$gpu_info,$instance_type"
}

pod_info=$(detect_pod_info)
IFS=',' read -r pod_type gpu_info instance_type <<< "$pod_info"

# Create session tracking data
create_session_data() {
    local status="$1"
    local current_time=$(date +%s)
    local current_iso=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    local duration=$((current_time - START_TIME))
    
    cat > "$LOCAL_TRACKING_FILE" << EOF
{
    "pod_id": "$POD_ID",
    "user": "$POD_USER_NAME",
    "session": {
        "start_time": "$START_ISO",
        "start_timestamp": $START_TIME,
        "last_update": "$current_iso",
        "last_timestamp": $current_time,
        "status": "$status",
        "duration_seconds": $duration,
        "duration_human": "$(printf '%02d:%02d:%02d' $((duration/3600)) $((duration%3600/60)) $((duration%60)))"
    },
    "pod_info": {
        "type": "$pod_type",
        "gpu": "$gpu_info",
        "instance_type": "$instance_type",
        "hostname": "$(hostname)",
        "template_id": "${THIS_POD_TEMPLATE_ID:-unknown}",
        "network_volume": "$NETWORK_VOLUME"
    },
    "metrics": {
        "startup_completed": $([ "$status" = "running" ] && echo "true" || echo "false"),
        "comfyui_started": false,
        "jupyter_started": false,
        "s3_mounted": $([ -n "$(mount | grep rclone)" ] && echo "true" || echo "false")
    },
    "timestamps": {
        "container_start": "$START_ISO",
        "s3_setup_complete": null,
        "services_ready": null,
        "shutdown_initiated": null,
        "final_sync": null
    }
}
EOF
}

# Update functions (simplified with jq fallback)
update_session_metric() {
    local metric_name="$1"
    local metric_value="$2"
    
    if command -v jq >/dev/null 2>&1; then
        jq ".metrics.$metric_name = $metric_value | .session.last_update = \"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\" | .session.last_timestamp = $(date +%s)" "$LOCAL_TRACKING_FILE" > "$LOCAL_TRACKING_FILE.tmp" && mv "$LOCAL_TRACKING_FILE.tmp" "$LOCAL_TRACKING_FILE"
    else
        create_session_data "running"
    fi
}

update_timestamp() {
    local timestamp_name="$1"
    local current_iso=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    
    if command -v jq >/dev/null 2>&1; then
        jq ".timestamps.$timestamp_name = \"$current_iso\" | .session.last_update = \"$current_iso\" | .session.last_timestamp = $(date +%s)" "$LOCAL_TRACKING_FILE" > "$LOCAL_TRACKING_FILE.tmp" && mv "$LOCAL_TRACKING_FILE.tmp" "$LOCAL_TRACKING_FILE"
    else
        create_session_data "running"
    fi
}

# Sync tracking data to S3
sync_tracking_data() {
    if [ -f "$LOCAL_TRACKING_FILE" ]; then
        local current_time=$(date +%s)
        local duration=$((current_time - START_TIME))
        
        if command -v jq >/dev/null 2>&1; then
            jq ".session.duration_seconds = $duration | .session.duration_human = \"$(printf '%02d:%02d:%02d' $((duration/3600)) $((duration%3600/60)) $((duration%60)))\" | .session.last_update = \"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\" | .session.last_timestamp = $current_time" "$LOCAL_TRACKING_FILE" > "$LOCAL_TRACKING_FILE.tmp" && mv "$LOCAL_TRACKING_FILE.tmp" "$LOCAL_TRACKING_FILE"
        fi
        
        mkdir -p "$TRACKING_DIR/upload"
        cp "$LOCAL_TRACKING_FILE" "$TRACKING_DIR/upload/session.json"
        
        if rclone copy "$TRACKING_DIR/upload/session.json" "$(dirname "$S3_SESSION_FILE")" --retries 3 2>/dev/null; then
            echo "✅ Tracking data synced to S3"
        fi
        
        rm -f "$TRACKING_DIR/upload/session.json"
    fi
}

# Update execution summary (simplified)
update_execution_summary() {
    if [ -f "$LOCAL_TRACKING_FILE" ] && command -v jq >/dev/null 2>&1; then
        local temp_summary="$TRACKING_DIR/execution_summary.json"
        
        # Create or download existing summary
        if ! rclone copy "$S3_SUMMARY_FILE" "$TRACKING_DIR/" --retries 3 2>/dev/null; then
            cat > "$temp_summary" << EOF
{
    "pod_id": "$POD_ID",
    "user": "$POD_USER_NAME",
    "total_sessions": 0,
    "total_duration_seconds": 0,
    "total_duration_human": "00:00:00",
    "last_updated": "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)",
    "session_history": []
}
EOF
        else
            cp "$TRACKING_DIR/$(basename "$S3_SUMMARY_FILE")" "$temp_summary"
        fi
        
        # Add current session and update
        local session_summary=$(jq '{session_start: .session.start_time, session_end: .session.last_update, duration_seconds: .session.duration_seconds, duration_human: .session.duration_human, status: .session.status, pod_type: .pod_info.type, gpu: .pod_info.gpu, services: {comfyui_started: .metrics.comfyui_started, jupyter_started: .metrics.jupyter_started}}' "$LOCAL_TRACKING_FILE")
        
        jq --argjson new_session "$session_summary" '.session_history = ([$new_session] + .session_history)[:100] | .total_sessions = (.session_history | length) | .total_duration_seconds = (.session_history | map(.duration_seconds) | add) | .last_updated = "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"' "$temp_summary" > "$temp_summary.tmp" && mv "$temp_summary.tmp" "$temp_summary"
        
        rclone copy "$temp_summary" "$(dirname "$S3_SUMMARY_FILE")" --retries 3 2>/dev/null
        rm -f "$temp_summary" "$temp_summary.tmp"
    fi
}

# Graceful shutdown handler
handle_shutdown() {
    echo "🛑 Pod tracker shutdown, finalizing..."
    update_timestamp "shutdown_initiated"
    create_session_data "shutting_down"
    sync_tracking_data
    
    update_timestamp "final_sync"
    create_session_data "stopped"
    sync_tracking_data
    update_execution_summary
    
    echo "✅ Pod execution tracking completed"
}

trap handle_shutdown SIGTERM SIGINT SIGQUIT

# Wait for S3 setup to complete
echo "⏳ Waiting for S3 setup to complete..."
while [ -z "$(mount | grep rclone)" ] && [ ! -f "$NETWORK_VOLUME/.setup_complete" ]; do
    sleep 5
done

update_timestamp "s3_setup_complete"
create_session_data "starting"
sync_tracking_data

# Monitor services
monitor_services() {
    local comfyui_started=false
    local jupyter_started=false
    
    while true; do
        if [ "$comfyui_started" = false ] && pgrep -f "python.*main.py.*--listen.*--port.*3000" >/dev/null; then
            echo "🎨 ComfyUI service started"
            update_session_metric "comfyui_started" "true"
            comfyui_started=true
        fi
        
        if [ "$jupyter_started" = false ] && pgrep -f "jupyter.*lab.*--port.*8888" >/dev/null; then
            echo "📊 Jupyter service started"
            update_session_metric "jupyter_started" "true"
            jupyter_started=true
        fi
        
        if [ -f "$NETWORK_VOLUME/.setup_complete" ] || ([ "$comfyui_started" = true ] && [ "$jupyter_started" = true ]); then
            update_timestamp "services_ready"
            create_session_data "running"
            echo "🎉 Pod is fully operational"
            break
        fi
        
        sleep 10
    done
}

# Main execution
monitor_services &
MONITOR_PID=$!

# Periodic sync loop
while true; do
    create_session_data "running"
    sync_tracking_data
    sleep 30
done &
SYNC_PID=$!

wait
kill $MONITOR_PID $SYNC_PID 2>/dev/null || true
handle_shutdown
        ' "$temp_summary" > "$temp_summary.tmp" && mv "$temp_summary.tmp" "$temp_summary"
        
        # Sync summary back to S3
        if rclone copy "$temp_summary" "$(dirname "$S3_SUMMARY_FILE")" --retries 3 2>/dev/null; then
            echo "✅ Execution summary updated for pod: $POD_ID"
        else
            echo "❌ Failed to update execution summary"
        fi
    fi
    
    rm -f "$temp_summary" "$temp_summary.tmp"
}

# Function for graceful shutdown tracking
handle_shutdown() {
    echo "🛑 Pod tracker shutdown detected, finalizing tracking..."
    
    update_timestamp "shutdown_initiated"
    create_session_data "shutting_down"
    sync_tracking_data
    
    # Final sync
    update_timestamp "final_sync"
    create_session_data "stopped"
    sync_tracking_data
    update_execution_summary
    
    echo "✅ Pod execution tracking completed"
    echo "📊 Session Duration: $(printf '%02d:%02d:%02d' $((($(date +%s) - START_TIME)/3600)) $(((($(date +%s) - START_TIME)%3600)/60)) $((($(date +%s) - START_TIME)%60)))"
}

# Set up signal handlers for graceful shutdown
trap handle_shutdown SIGTERM SIGINT SIGQUIT

# Wait for S3 setup to complete (indicated by rclone mounts or setup completion)
echo "⏳ Waiting for S3 setup to complete..."
while [ -z "$(mount | grep rclone)" ] && [ ! -f "$NETWORK_VOLUME/.setup_complete" ]; do
    sleep 5
done

update_timestamp "s3_setup_complete"

# Create initial session data
create_session_data "starting"
sync_tracking_data

# Function to monitor service status
monitor_services() {
    local comfyui_started=false
    local jupyter_started=false
    
    while true; do
        # Check if ComfyUI is running
        if [ "$comfyui_started" = false ] && pgrep -f "python.*main.py.*--listen.*--port.*3000" >/dev/null; then
            echo "🎨 ComfyUI service detected as started"
            update_session_metric "comfyui_started" "true"
            comfyui_started=true
        fi
        
        # Check if Jupyter is running
        if [ "$jupyter_started" = false ] && pgrep -f "jupyter.*lab.*--port.*8888" >/dev/null; then
            echo "📊 Jupyter service detected as started"
            update_session_metric "jupyter_started" "true"
            jupyter_started=true
        fi
        
        # Mark as running once both services are up or setup is complete
        if [ -f "$NETWORK_VOLUME/.setup_complete" ] || ([ "$comfyui_started" = true ] && [ "$jupyter_started" = true ]); then
            update_timestamp "services_ready"
            create_session_data "running"
            echo "🎉 Pod is fully operational"
            break
        fi
        
        sleep 10
    done
}

# Main tracking loop
echo "🏃 Starting service monitoring..."
monitor_services &
MONITOR_PID=$!

# Periodic sync loop (every 5 minutes to match existing sync intervals)
while true; do
    create_session_data "running"
    sync_tracking_data
    sleep 300
done &
SYNC_PID=$!

# Wait for shutdown signal
wait

# Clean up background processes
kill $MONITOR_PID $SYNC_PID 2>/dev/null || true
handle_shutdown
# Wait for shutdown signal
wait

# Clean up background processes
kill $MONITOR_PID $SYNC_PID 2>/dev/null || true
handle_shutdown
