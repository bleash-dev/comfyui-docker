#!/bin/bash
# Pod execution analytics and reporting

# Validate required environment variables
required_vars=("AWS_BUCKET_NAME" "POD_USER_NAME")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ Required variable $var is not set"
        exit 1
    fi
done

# Wait for NETWORK_VOLUME if not set
if [ -z "$NETWORK_VOLUME" ]; then
    if [ -d "/runpod-volume" ]; then
        NETWORK_VOLUME="/runpod-volume"
    elif [ -w "/workspace" ]; then
        NETWORK_VOLUME="/workspace"
    else
        echo "❌ NETWORK_VOLUME not available"
        exit 1
    fi
fi

# Get current POD_ID if available
CURRENT_POD_ID="${POD_ID:-}"

TRACKING_DIR="$NETWORK_VOLUME/.pod_tracking"
# Use current pod's summary if POD_ID is available
if [ -n "$CURRENT_POD_ID" ]; then
    S3_CURRENT_POD_SUMMARY="s3:$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME/$CURRENT_POD_ID/_pod_tracking/execution_summary.json"
fi
S3_USER_SESSIONS_BASE="s3:$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME"
TEMP_DIR="$TRACKING_DIR/analytics"

echo "📊 Pod Execution Analytics for User: $POD_USER_NAME"
if [ -n "$CURRENT_POD_ID" ]; then
    echo "🆔 Current Pod: $CURRENT_POD_ID"
else
    echo "⚠️ No POD_ID available - some features will be limited"
fi
echo "=================================================="

# Check for jq availability
if ! command -v jq >/dev/null 2>&1; then
    echo "⚠️ jq not found, attempting to install..."
    apt-get update && apt-get install -y jq 2>/dev/null || {
        echo "❌ jq installation failed - analytics will be limited"
        echo "Some detailed parsing features will not be available"
        echo ""
    }
fi

mkdir -p "$TEMP_DIR"

# Function to download and display current pod summary
show_current_pod_summary() {
    echo "📈 Current Pod Execution Summary"
    echo "-------------------------------"
    
    if [ -z "$CURRENT_POD_ID" ]; then
        echo "❌ No current POD_ID available"
        echo "This pod was not started with proper POD_ID configuration"
        return
    fi
    
    if rclone copy "$S3_CURRENT_POD_SUMMARY" "$TEMP_DIR/" --retries 3 2>/dev/null; then
        local summary_file="$TEMP_DIR/execution_summary.json"
        
        if command -v jq >/dev/null 2>&1; then
            echo "Pod ID: $(jq -r '.pod_id // "unknown"' "$summary_file")"
            echo "Total Sessions: $(jq -r '.total_sessions // 0' "$summary_file")"
            echo "Total Runtime: $(jq -r '.total_duration_human // "00:00:00"' "$summary_file")"
            
            local total_sessions=$(jq -r '.total_sessions // 0' "$summary_file")
            if [ "$total_sessions" -gt 0 ]; then
                echo "Average Session: $(jq -r '(.total_duration_seconds // 0) / (.total_sessions // 1) / 60 | floor' "$summary_file") minutes"
            else
                echo "Average Session: N/A"
            fi
            
            echo "Last Updated: $(jq -r '.last_updated // "Never"' "$summary_file")"
        else
            echo "⚠️ jq not available - showing raw JSON:"
            cat "$summary_file"
        fi
    else
        echo "❌ No execution summary found for current pod"
    fi
    echo ""
}

# Function to show user-level aggregated summary
show_user_summary() {
    echo "📈 User-Level Execution Summary"
    echo "------------------------------"
    
    # Download all pod summaries for the user
    local user_pods_dir="$TEMP_DIR/user_pods"
    mkdir -p "$user_pods_dir"
    
    if rclone copy "$S3_USER_SESSIONS_BASE" "$user_pods_dir" --include="_pod_tracking/execution_summary.json" --retries 3 2>/dev/null; then
        local total_sessions=0
        local total_duration=0
        local pod_count=0
        
        # Process each pod's summary
        for summary_file in "$user_pods_dir"/*/_pod_tracking/execution_summary.json; do
            if [ -f "$summary_file" ] && command -v jq >/dev/null 2>&1; then
                local pod_sessions=$(jq -r '.total_sessions // 0' "$summary_file")
                local pod_duration=$(jq -r '.total_duration_seconds // 0' "$summary_file")
                
                total_sessions=$((total_sessions + pod_sessions))
                total_duration=$((total_duration + pod_duration))
                pod_count=$((pod_count + 1))
            fi
        done
        
        if [ $pod_count -gt 0 ]; then
            local total_hours=$((total_duration / 3600))
            local total_minutes=$(((total_duration % 3600) / 60))
            local total_seconds=$((total_duration % 60))
            
            echo "Total Pods: $pod_count"
            echo "Total Sessions: $total_sessions"
            echo "Total Runtime: $(printf '%02d:%02d:%02d' $total_hours $total_minutes $total_seconds)"
            
            if [ $total_sessions -gt 0 ]; then
                echo "Average Session: $((total_duration / total_sessions / 60)) minutes"
            fi
        else
            echo "No pod execution data found"
        fi
    else
        echo "❌ Failed to download user pod data"
    fi
    echo ""
}

# Function to show recent sessions across all pods
show_recent_sessions() {
    local limit=${1:-10}
    echo "🕐 Recent Sessions Across All Pods (Last $limit)"
    echo "------------------------------------------------"
    
    # Download all pod summaries for the user
    local user_pods_dir="$TEMP_DIR/user_pods"
    mkdir -p "$user_pods_dir"
    
    if rclone copy "$S3_USER_SESSIONS_BASE" "$user_pods_dir" --include="_pod_tracking/execution_summary.json" --retries 3 2>/dev/null; then
        
        # Collect all sessions from all pods
        local all_sessions_file="$TEMP_DIR/all_sessions.json"
        echo "[]" > "$all_sessions_file"
        
        for summary_file in "$user_pods_dir"/*/_pod_tracking/execution_summary.json; do
            if [ -f "$summary_file" ] && command -v jq >/dev/null 2>&1; then
                local pod_id=$(jq -r '.pod_id // "unknown"' "$summary_file")
                
                # Add pod_id to each session and merge with all_sessions
                jq --arg pod_id "$pod_id" '.session_history | map(. + {pod_id: $pod_id})' "$summary_file" | \
                jq -s '.[0] + .[1]' "$all_sessions_file" - > "$all_sessions_file.tmp" && \
                mv "$all_sessions_file.tmp" "$all_sessions_file"
            fi
        done
        
        # Sort by session_end and show recent sessions
        if command -v jq >/dev/null 2>&1; then
            local session_count=$(jq '. | length' "$all_sessions_file")
            
            if [ "$session_count" -gt 0 ]; then
                jq -r --arg limit "$limit" 'sort_by(.session_end) | reverse | .[:($limit | tonumber)] | .[] | 
                    "Pod: " + (.pod_id // "unknown") + 
                    "\n  Started: " + (.session_start // "unknown") + 
                    "\n  Ended: " + (.session_end // "unknown") +
                    "\n  Duration: " + (.duration_human // "00:00:00") + 
                    "\n  Status: " + (.status // "unknown") + 
                    "\n  Type: " + (.pod_type // "unknown") + " - " + (.gpu // "none") + 
                    "\n  Services: ComfyUI=" + (.services.comfyui_started | tostring) + 
                    ", Jupyter=" + (.services.jupyter_started | tostring) + "\n"' "$all_sessions_file"
            else
                echo "No sessions found"
            fi
        fi
        
        rm -f "$all_sessions_file" "$all_sessions_file.tmp"
    else
        echo "❌ Failed to download session data"
    fi
}

# Function to show current session info
show_current_session() {
    echo "🏃 Current Session"
    echo "------------------"
    
    if [ -f "$TRACKING_DIR/current_session.json" ]; then
        if command -v jq >/dev/null 2>&1; then
            echo "Pod ID: $(jq -r '.pod_id // "unknown"' "$TRACKING_DIR/current_session.json")"
            echo "Started: $(jq -r '.session.start_time // "unknown"' "$TRACKING_DIR/current_session.json")"
            echo "Duration: $(jq -r '.session.duration_human // "00:00:00"' "$TRACKING_DIR/current_session.json")"
            echo "Status: $(jq -r '.session.status // "unknown"' "$TRACKING_DIR/current_session.json")"
            echo "ComfyUI: $(jq -r '.metrics.comfyui_started // false' "$TRACKING_DIR/current_session.json")"
            echo "Jupyter: $(jq -r '.metrics.jupyter_started // false' "$TRACKING_DIR/current_session.json")"
            echo "S3 Mounted: $(jq -r '.metrics.s3_mounted // false' "$TRACKING_DIR/current_session.json")"
            echo "Network Volume: $(jq -r '.pod_info.network_volume // "unknown"' "$TRACKING_DIR/current_session.json")"
        else
            echo "Current session file found but jq not available:"
            cat "$TRACKING_DIR/current_session.json"
        fi
    else
        echo "No current session tracking found"
    fi
    echo ""
}

# Function to show S3 integration status
show_s3_status() {
    echo "🗂️ S3 Integration Status"
    echo "------------------------"
    
    # Check if we can access S3
    if rclone lsd "$S3_USER_SESSIONS_BASE/" --retries 1 2>/dev/null; then
        echo "✅ S3 access: Working"
        
        # List user's pod sessions
        echo "📁 Your pod sessions in S3:"
        rclone lsd "$S3_USER_SESSIONS_BASE/" | while read -r line; do
            if [[ "$line" =~ ([a-zA-Z0-9_-]+)$ ]]; then
                pod_id="${BASH_REMATCH[1]}"
                echo "  - $pod_id"
            fi
        done
        
        # Show shared resources
        echo "🔗 Shared resources available:"
        if rclone lsd "s3:$AWS_BUCKET_NAME/pod_sessions/shared/" 2>/dev/null | grep -q .; then
            rclone lsd "s3:$AWS_BUCKET_NAME/pod_sessions/shared/" | while read -r line; do
                if [[ "$line" =~ ([a-zA-Z0-9_.-]+)$ ]]; then
                    shared_item="${BASH_REMATCH[1]}"
                    echo "  - $shared_item"
                fi
            done
        else
            echo "  - No shared resources found"
        fi
    else
        echo "❌ S3 access: Failed"
        echo "Check your AWS credentials and network connectivity"
    fi
    echo ""
}

# Main execution
case "${1:-summary}" in
    "summary")
        if [ -n "$CURRENT_POD_ID" ]; then
            show_current_pod_summary
        fi
        show_user_summary
        show_current_session
        ;;
    "recent")
        show_recent_sessions "${2:-10}"
        ;;
    "current")
        show_current_session
        ;;
    "pod")
        if [ -n "$CURRENT_POD_ID" ]; then
            show_current_pod_summary
        else
            echo "❌ No current POD_ID available"
        fi
        ;;
    "user")
        show_user_summary
        ;;
    "s3")
        show_s3_status
        ;;
    "full")
        if [ -n "$CURRENT_POD_ID" ]; then
            show_current_pod_summary
        fi
        show_user_summary
        show_current_session
        show_recent_sessions 20
        show_s3_status
        ;;
    *)
        echo "Usage: $0 [summary|recent|current|pod|user|s3|full]"
        echo ""
        echo "Commands:"
        echo "  summary  - Show user summary and current session (default)"
        echo "  recent   - Show recent sessions across all pods"
        echo "  current  - Show only current session"
        echo "  pod      - Show current pod execution summary"
        echo "  user     - Show user-level aggregated summary"
        echo "  s3       - Show S3 integration status"
        echo "  full     - Show all information"
        echo ""
        echo "Examples:"
        echo "  $0 recent 5    # Show last 5 sessions"
        echo "  $0 user        # Show aggregated user statistics"
        echo "  $0 pod         # Show current pod statistics"
        ;;
esac

# Cleanup
rm -rf "$TEMP_DIR"
