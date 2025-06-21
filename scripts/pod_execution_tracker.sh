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
        # If any required var is missing, the script cannot function reliably.
        # Consider if this script should run at all if essential tracking vars are missing.
        # For now, exiting is the safest.
        exit 1
    fi
done

# Define tracking paths
TRACKING_DIR="$NETWORK_VOLUME/.pod_tracking"
LOCAL_TRACKING_FILE="$TRACKING_DIR/current_session.json"
S3_TRACKING_BASE="s3://$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$POD_ID"
S3_SESSION_FILE="$S3_TRACKING_BASE/_pod_tracking/session.json"
S3_SUMMARY_FILE="$S3_TRACKING_BASE/_pod_tracking/execution_summary.json"

mkdir -p "$TRACKING_DIR"

# Get startup timestamp
START_TIME=$(date +%s)
START_ISO=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)

# Set default tracking sync interval (in seconds) if not provided via environment
export SYNC_INTERVAL_TRACKING="${SYNC_INTERVAL_TRACKING:-30}"  # 30 seconds

echo "📊 Tracking: Pod $POD_ID, User $POD_USER_NAME, Start: $START_ISO"
echo "🔄 Tracking sync interval: every $SYNC_INTERVAL_TRACKING seconds"

# Detect pod information
detect_pod_info() {
    local pod_type="cpu"
    local gpu_info="none"
    local instance_type="${THIS_POD_TEMPLATE_ID:-unknown}"

    if command -v nvidia-smi &> /dev/null; then
        gpu_info=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits | head -1 | tr ',' '-' | tr ' ' '_')
        if [ -z "$gpu_info" ]; then
            gpu_info="nvidia-smi_error"
        fi
        pod_type="gpu"
    fi
    echo "$pod_type,$gpu_info,$instance_type"
}

pod_info=$(detect_pod_info)
IFS=',' read -r pod_type gpu_info instance_type <<< "$pod_info"

# --- Utility: Preserve existing timestamps and metrics before overwriting LOCAL_TRACKING_FILE ---
_preserve_critical_data() {
    if command -v jq >/dev/null 2>&1 && [ -f "$LOCAL_TRACKING_FILE" ]; then
        jq '{timestamps: .timestamps, metrics: .metrics}' "$LOCAL_TRACKING_FILE" > "$LOCAL_TRACKING_FILE.preserved_data"
    fi
}

_restore_critical_data() {
    if command -v jq >/dev/null 2>&1 && [ -f "$LOCAL_TRACKING_FILE.preserved_data" ] && [ -f "$LOCAL_TRACKING_FILE" ]; then
        # Merge preserved data, letting new data take precedence for session info, but keeping old timestamps/metrics if not updated
        jq -s '.[0] * .[1]' "$LOCAL_TRACKING_FILE.preserved_data" "$LOCAL_TRACKING_FILE" > "$LOCAL_TRACKING_FILE.tmp" && \
        mv "$LOCAL_TRACKING_FILE.tmp" "$LOCAL_TRACKING_FILE"
    fi
    rm -f "$LOCAL_TRACKING_FILE.preserved_data"
}


# Create/Update session tracking data. Status is the primary input.
create_session_data() {
    local status="$1"
    _preserve_critical_data # Preserve before overwriting

    local current_time=$(date +%s)
    local current_iso=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    local duration=$((current_time - START_TIME))

    # Default metrics values - these will be merged/overwritten if preserved data exists
    local comfyui_started_val="false"
    local jupyter_started_val="false"
    local s3_mounted_val="false"
    local startup_completed_val="false"

    # Default timestamps - these will be merged/overwritten
    local s3_setup_complete_ts="null"
    local services_ready_ts="null"
    local shutdown_initiated_ts="null"
    local final_sync_ts="null"


    if [ "$status" = "running" ]; then
        startup_completed_val="true"
    fi
    # Remove FUSE mount detection, use S3 connection test instead
    s3_connected_val=$(aws s3 ls "s3://$AWS_BUCKET_NAME/" >/dev/null 2>&1 && echo "true" || echo "false")

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
        "startup_completed": $startup_completed_val,
        "comfyui_started": $comfyui_started_val,
        "jupyter_started": $jupyter_started_val,
        "s3_connected": $s3_connected_val
    },
    "timestamps": {
        "container_start": "$START_ISO",
        "s3_setup_complete": $s3_setup_complete_ts,
        "services_ready": $services_ready_ts,
        "shutdown_initiated": $shutdown_initiated_ts,
        "final_sync": $final_sync_ts
    }
}
EOF
    _restore_critical_data # Restore/Merge preserved data
}

update_session_metric() {
    local metric_name="$1"
    local metric_value="$2"

    if ! [ -f "$LOCAL_TRACKING_FILE" ]; then create_session_data "initializing"; fi

    if command -v jq >/dev/null 2>&1; then
        jq ".metrics.$metric_name = $metric_value | .session.last_update = \"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\" | .session.last_timestamp = $(date +%s)" "$LOCAL_TRACKING_FILE" > "$LOCAL_TRACKING_FILE.tmp" && mv "$LOCAL_TRACKING_FILE.tmp" "$LOCAL_TRACKING_FILE"
    else
        echo "⚠️ jq not found. Recreating session data to update metric '$metric_name'. Some incremental data might be reset."
        create_session_data "running" # Fallback, status is a guess here
        # Manual update for specific metric without jq is complex, this is a simplification
        if [ "$metric_name" = "comfyui_started" ]; then sed -i "s/\"comfyui_started\": .*,/\"comfyui_started\": $metric_value,/" "$LOCAL_TRACKING_FILE"; fi
        if [ "$metric_name" = "jupyter_started" ]; then sed -i "s/\"jupyter_started\": .*,/\"jupyter_started\": $metric_value,/" "$LOCAL_TRACKING_FILE"; fi

    fi
}

update_timestamp() {
    local timestamp_name="$1"
    local current_iso=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)

    if ! [ -f "$LOCAL_TRACKING_FILE" ]; then create_session_data "initializing"; fi

    if command -v jq >/dev/null 2>&1; then
        jq ".timestamps.$timestamp_name = \"$current_iso\" | .session.last_update = \"$current_iso\" | .session.last_timestamp = $(date +%s)" "$LOCAL_TRACKING_FILE" > "$LOCAL_TRACKING_FILE.tmp" && mv "$LOCAL_TRACKING_FILE.tmp" "$LOCAL_TRACKING_FILE"
    else
        echo "⚠️ jq not found. Recreating session data to update timestamp '$timestamp_name'. Some incremental data might be reset."
        create_session_data "running" # Fallback
        # Manual update for specific timestamp without jq is complex
        # Example using sed (fragile):
        # sed -i "s|\"$timestamp_name\": .*|\"$timestamp_name\": \"$current_iso\",|" "$LOCAL_TRACKING_FILE"
    fi
}

sync_tracking_data() {
    if [ -f "$LOCAL_TRACKING_FILE" ]; then
        local current_time=$(date +%s)
        local duration=$((current_time - START_TIME))

        if command -v jq >/dev/null 2>&1; then
            # Update S3 connectivity status instead of mount status
            local s3_connected=$(aws s3 ls "s3://$AWS_BUCKET_NAME/" >/dev/null 2>&1 && echo "true" || echo "false")
            jq ".session.duration_seconds = $duration | .session.duration_human = \"$(printf '%02d:%02d:%02d' $((duration/3600)) $((duration%3600/60)) $((duration%60)))\" | .session.last_update = \"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\" | .session.last_timestamp = $current_time | .metrics.s3_connected = $s3_connected" "$LOCAL_TRACKING_FILE" > "$LOCAL_TRACKING_FILE.tmp" && mv "$LOCAL_TRACKING_FILE.tmp" "$LOCAL_TRACKING_FILE"
        else
            # If jq not found, create_session_data (called by periodic loop) will handle updating duration
            :
        fi
        
        if aws s3 cp "$LOCAL_TRACKING_FILE" "$S3_SESSION_FILE" --only-show-errors; then
            echo "✅ Tracking data synced to S3: $S3_SESSION_FILE"
        else
            echo "❌ Failed to sync tracking data to S3."
        fi
    fi
}

update_execution_summary() {
    if [ ! -f "$LOCAL_TRACKING_FILE" ]; then
        echo "⚠️ Local tracking file not found. Cannot update execution summary."
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "⚠️ jq not found. Cannot update execution summary."
        return 1
    fi

    local temp_summary_local="$TRACKING_DIR/execution_summary.json"
    local temp_summary_download="$TRACKING_DIR/execution_summary_download.json"

    # Try to download existing summary from S3
    if aws s3 cp "$S3_SUMMARY_FILE" "$temp_summary_download" --only-show-errors 2>/dev/null; then
        echo "ℹ️ Downloaded existing execution summary from S3."
        mv "$temp_summary_download" "$temp_summary_local"
    else
        echo "ℹ️ No existing S3 summary found or failed to download. Creating new summary."
        cat > "$temp_summary_local" << EOF
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
    fi

    local session_summary
    session_summary=$(jq '{
        session_start: .session.start_time,
        session_end: .session.last_update,
        duration_seconds: .session.duration_seconds,
        duration_human: .session.duration_human,
        status: .session.status,
        pod_type: .pod_info.type,
        gpu: .pod_info.gpu,
        services: {
            comfyui_started: (.metrics.comfyui_started // false),
            jupyter_started: (.metrics.jupyter_started // false)
        }
    }' "$LOCAL_TRACKING_FILE")

    if [ -z "$session_summary" ]; then
        echo "❌ Failed to create session summary from local tracking file. Aborting summary update."
        rm -f "$temp_summary_local"
        return 1
    fi

    local current_iso_date=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    jq --argjson new_session "$session_summary" \
       --arg current_iso_date "$current_iso_date" \
       '.session_history = ([$new_session] + .session_history)[:100] |
        .total_sessions = (.session_history | length) |
        .total_duration_seconds = ([.session_history[] .duration_seconds] | add // 0) |
        .last_updated = $current_iso_date' \
       "$temp_summary_local" > "$temp_summary_local.tmp" && mv "$temp_summary_local.tmp" "$temp_summary_local"

    # Upload updated summary to S3
    if aws s3 cp "$temp_summary_local" "$S3_SUMMARY_FILE" --only-show-errors; then
        echo "✅ Execution summary updated for pod: $POD_ID to $S3_SUMMARY_FILE"
    else
        echo "❌ Failed to update execution summary to S3."
    fi
    rm -f "$temp_summary_local"
}

_shutdown_in_progress=false
handle_shutdown() {
    # Prevent re-entry if signal is received multiple times
    if [[ "$_shutdown_in_progress" == true ]]; then
        echo "ℹ️ Shutdown already in progress."
        return
    fi
    _shutdown_in_progress=true

    echo "🛑 Pod tracker shutdown detected, finalizing tracking..."
    
    if [ ! -f "$LOCAL_TRACKING_FILE" ]; then create_session_data "shutting_down"; fi
    
    update_timestamp "shutdown_initiated"
    create_session_data "shutting_down" # Update status to shutting_down, preserves other fields
    sync_tracking_data
    
    update_timestamp "final_sync"
    create_session_data "stopped" # Final status, preserves other fields
    sync_tracking_data
    update_execution_summary
    
    echo "✅ Pod execution tracking completed."
    local final_duration_seconds=$(( $(date +%s) - START_TIME ))
    echo "📊 Session Duration: $(printf '%02d:%02d:%02d' $((final_duration_seconds/3600)) $((final_duration_seconds%3600/60)) $((final_duration_seconds%60)))"
    
    # Clean up background PIDs explicitly if they are still around
    if ps -p $MONITOR_PID > /dev/null 2>&1; then kill $MONITOR_PID 2>/dev/null; fi
    if ps -p $SYNC_PID > /dev/null 2>&1; then kill $SYNC_PID 2>/dev/null; fi
    
    exit 0 # Ensure script exits after trap
}

trap handle_shutdown SIGTERM SIGINT SIGQUIT

# --- Main Execution Flow ---

create_session_data "initializing"
sync_tracking_data

echo "⏳ Waiting indefinitely for S3 setup to complete (AWS CLI setup or $NETWORK_VOLUME/.setup_complete)..."
s3_setup_done=false
while true; do
    if aws s3 ls "s3://$AWS_BUCKET_NAME/" >/dev/null 2>&1 || [ -f "$NETWORK_VOLUME/.setup_complete" ]; then
        echo "✅ S3 setup detected as complete."
        update_timestamp "s3_setup_complete"
        s3_setup_done=true # Set flag
        break
    fi
    sleep 5 # Check every 5 seconds
done

create_session_data "starting" # Update status to "starting"
sync_tracking_data

monitor_services() {
    local comfyui_started_flag=false
    local jupyter_started_flag=false
    
    echo "🏃 Starting service monitoring..."
    while true; do
        if [ "$comfyui_started_flag" = false ] && pgrep -f "python.*main.py.*--listen.*--port.*8080" >/dev/null; then
            echo "🎨 ComfyUI service detected as started"
            update_session_metric "comfyui_started" "true"
            comfyui_started_flag=true
        fi
        
        if [ "$jupyter_started_flag" = false ] && pgrep -f "jupyter.*lab.*--port.*8888" >/dev/null; then
            echo "📊 Jupyter service detected as started"
            update_session_metric "jupyter_started" "true"
            jupyter_started_flag=true
        fi
        
        # Condition: S3 setup must be done AND ( .setup_complete file exists OR both services are up)
        if [ "$s3_setup_done" = true ] && \
           ( [ -f "$NETWORK_VOLUME/.setup_complete" ] || \
             ( [ "$comfyui_started_flag" = true ] && [ "$jupyter_started_flag" = true ] ) ); then
            update_timestamp "services_ready"
            create_session_data "running"
            sync_tracking_data
            echo "🎉 Pod is fully operational."
            break # Exit monitor_services
        fi
        sleep 10
    done
}

monitor_services &
MONITOR_PID=$!

echo "🔄 Starting periodic sync loop (every $SYNC_INTERVAL_TRACKING seconds)..."
while true; do
    # Check if monitor_services is still running. If not, services are assumed to be up.
    if ! ps -p $MONITOR_PID > /dev/null 2>&1 && [ -f "$LOCAL_TRACKING_FILE" ]; then
        # Monitor_services has exited (services ready), ensure status is 'running'
        # Only update to "running" if not already shutting down
        current_status=$(jq -r .session.status "$LOCAL_TRACKING_FILE" 2>/dev/null || echo "unknown")
        if [ "$current_status" != "shutting_down" ] && [ "$current_status" != "stopped" ]; then
             create_session_data "running" # This will preserve other metrics/timestamps
        fi
    elif [ ! -f "$LOCAL_TRACKING_FILE" ]; then
        # File might have been deleted, or this is very early. Re-initialize if monitor is still up.
        if ps -p $MONITOR_PID > /dev/null 2>&1; then
            create_session_data "starting" # Or "initializing" if s3_setup_done is false
        fi
    fi
    sync_tracking_data
    sleep $SYNC_INTERVAL_TRACKING
done &
SYNC_PID=$!

# Wait for monitor_services to complete.
# If it's killed by a signal, the trap will handle shutdown.
wait $MONITOR_PID 2>/dev/null # Suppress "Terminated" message if killed by trap

# After monitor_services exits (meaning pod is operational or setup is considered complete),
# the script's main job is done by the SYNC_PID and waiting for termination signals.
# The `wait` command without arguments will wait for all background jobs.
# If a signal (SIGTERM, etc.) is received, the trap `handle_shutdown` will execute and then exit.
echo "🏁 Service monitoring completed. Pod operational. Main script waiting for termination signal..."
wait # Wait for SYNC_PID or any other child, effectively waits for termination signal to trigger trap