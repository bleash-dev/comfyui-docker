#!/bin/bash
# Pod execution analytics and reporting (no FUSE dependencies)

# --- Configuration & Validation ---
set -eo pipefail # Exit on error, treat unset variables as an error (optional), and pipe failures

# Validate required environment variables
required_vars=("AWS_BUCKET_NAME" "POD_USER_NAME")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ ERROR: Required environment variable $var is not set."
        exit 1
    fi
done

# Attempt to determine NETWORK_VOLUME if not set
if [ -z "$NETWORK_VOLUME" ]; then
    echo "ℹ️ NETWORK_VOLUME not explicitly set. Attempting to auto-detect..."
    if [ -d "/runpod-volume" ] && [ -w "/runpod-volume" ]; then # Check writability
        NETWORK_VOLUME="/runpod-volume"
        echo "  -> Detected and using NETWORK_VOLUME: /runpod-volume"
    elif [ -d "/workspace" ] && [ -w "/workspace" ]; then # Check writability
        NETWORK_VOLUME="/workspace"
        echo "  -> Detected and using NETWORK_VOLUME: /workspace"
    else
        # Fallback to a temporary directory in /tmp if persistent storage isn't critical for this script's temp files
        NETWORK_VOLUME="/tmp/pod_analytics_fallback_nv_$(date +%s)"
        echo "⚠️ WARNING: NETWORK_VOLUME could not be auto-detected from common paths (/runpod-volume, /workspace)."
        echo "  -> Using temporary fallback: $NETWORK_VOLUME for local tracking files."
        echo "     Current session data (if this script is run inside the tracked pod) might not be found unless $NETWORK_VOLUME matches the tracker script's."
    fi
fi

# Get current POD_ID if available from environment
CURRENT_POD_ID="${POD_ID:-}" # Use POD_ID from env if set, otherwise empty

# Define paths
TRACKING_DIR="$NETWORK_VOLUME/.pod_tracking" # For current_session.json
TEMP_DIR=$(mktemp -d -p "${TMPDIR:-/tmp}" "pod_analytics.XXXXXX") # Secure temp directory

S3_USER_SESSIONS_BASE="s3:$AWS_BUCKET_NAME/pod_sessions/$POD_USER_NAME"
S3_CURRENT_POD_SUMMARY=""
if [ -n "$CURRENT_POD_ID" ]; then
    S3_CURRENT_POD_SUMMARY="$S3_USER_SESSIONS_BASE/$CURRENT_POD_ID/_pod_tracking/execution_summary.json"
fi

echo "📊 Pod Execution Analytics for User: $POD_USER_NAME"
if [ -n "$CURRENT_POD_ID" ]; then
    echo "🆔 Current Pod ID context: $CURRENT_POD_ID"
else
    echo "⚠️ No current POD_ID context - some pod-specific features will be limited."
fi
echo "=================================================="

# Check for jq availability
if ! command -v jq >/dev/null 2>&1; then
    echo "❌ ERROR: jq is not installed or not in PATH. This script requires jq for parsing JSON data."
    echo "Please install jq (e.g., 'sudo apt-get install jq' or 'brew install jq') and try again."
    exit 1
fi

# Ensure base tracking directory for local files exists if needed (e.g. for current_session.json)
mkdir -p "$TRACKING_DIR"
# Temp dir for downloads is already created by mktemp

# --- Functions ---

# Function to download and display current pod summary
show_current_pod_summary() {
    echo ""
    echo "📈 Current Pod Execution Summary (based on POD_ID: $CURRENT_POD_ID)"
    echo "------------------------------------------------------------------"
    
    if [ -z "$CURRENT_POD_ID" ]; then
        echo "❌ No current POD_ID available (POD_ID environment variable not set)."
        echo "   Cannot fetch summary for a specific 'current' pod."
        return
    fi
    
    local summary_file="$TEMP_DIR/current_pod_execution_summary.json"
    echo "ℹ️ Attempting to download summary from: $S3_CURRENT_POD_SUMMARY"
    if rclone copyto "$S3_CURRENT_POD_SUMMARY" "$summary_file" --retries 3; then # copyto for single file
        echo "Pod ID: $(jq -r '.pod_id // "N/A"' "$summary_file")"
        echo "Total Sessions Recorded: $(jq -r '.total_sessions // 0' "$summary_file")"
        echo "Total Runtime for this Pod ID: $(jq -r '.total_duration_human // "00:00:00"' "$summary_file")"
        
        local total_duration_seconds=$(jq -r '.total_duration_seconds // 0' "$summary_file")
        local total_sessions=$(jq -r '.total_sessions // 0' "$summary_file")

        if [ "$total_sessions" -gt 0 ] && [ "$total_duration_seconds" -gt 0 ]; then
            # Using awk for potentially more precise average, converting seconds to minutes
            local avg_session_minutes=$(awk -v dur="$total_duration_seconds" -v sess="$total_sessions" 'BEGIN { printf "%.0f", dur / sess / 60 }')
            echo "Average Session Duration: $avg_session_minutes minutes"
        else
            echo "Average Session Duration: N/A"
        fi
        echo "Last Updated: $(jq -r '.last_updated // "N/A"' "$summary_file")"
    else
        echo "❌ No execution summary found for current pod ID ($CURRENT_POD_ID) in S3 or failed to download."
    fi
    echo ""
}

# Function to show user-level aggregated summary
show_user_summary() {
    echo ""
    echo "📈 User-Level Aggregated Execution Summary ($POD_USER_NAME)"
    echo "---------------------------------------------------------"
    
    local user_pods_dl_dir="$TEMP_DIR/user_pod_summaries"
    mkdir -p "$user_pods_dl_dir"
    
    echo "ℹ️ Downloading all execution_summary.json files from: $S3_USER_SESSIONS_BASE/"
    # Using --files-from with rclone lsjson to get exact files, more robust
    rclone lsjson "$S3_USER_SESSIONS_BASE/" --recursive --include "*/_pod_tracking/execution_summary.json" 2>/dev/null | \
        jq -r '.[].Path' | \
        while IFS= read -r s3_path; do
            # Create corresponding local directory structure
            local local_path_suffix=$(echo "$s3_path" | sed "s|^.*/pod_sessions/$POD_USER_NAME/||") # Get path relative to user base
            mkdir -p "$user_pods_dl_dir/$(dirname "$local_path_suffix")"
            rclone copyto "$S3_USER_SESSIONS_BASE/$s3_path" "$user_pods_dl_dir/$local_path_suffix" --retries 2 || \
                echo "⚠️ Failed to download $s3_path"
        done

    local total_sessions_all_pods=0
    local total_duration_all_pods=0
    local distinct_pod_count=0
    
    find "$user_pods_dl_dir" -name "execution_summary.json" -type f | while IFS= read -r summary_file; do
        local pod_sessions=$(jq -r '.total_sessions // 0' "$summary_file")
        local pod_duration=$(jq -r '.total_duration_seconds // 0' "$summary_file")
        
        total_sessions_all_pods=$((total_sessions_all_pods + pod_sessions))
        total_duration_all_pods=$((total_duration_all_pods + pod_duration))
        distinct_pod_count=$((distinct_pod_count + 1))
    done
    
    if [ "$distinct_pod_count" -gt 0 ]; then
        local total_h=$((total_duration_all_pods / 3600))
        local total_m=$(((total_duration_all_pods % 3600) / 60))
        local total_s=$((total_duration_all_pods % 60))
        
        echo "Total Distinct Pod IDs with Summaries: $distinct_pod_count"
        echo "Total Sessions Across All Pods: $total_sessions_all_pods"
        echo "Total Runtime Across All Pods: $(printf '%02d:%02d:%02d' "$total_h" "$total_m" "$total_s")"
        
        if [ "$total_sessions_all_pods" -gt 0 ] && [ "$total_duration_all_pods" -gt 0 ]; then
            local avg_session_minutes_all=$(awk -v dur="$total_duration_all_pods" -v sess="$total_sessions_all_pods" 'BEGIN { printf "%.0f", dur / sess / 60 }')
            echo "Average Session Duration (across all sessions): $avg_session_minutes_all minutes"
        else
             echo "Average Session Duration (across all sessions): N/A"
        fi
    else
        echo "No pod execution data found for user $POD_USER_NAME."
    fi
    echo ""
}

# Function to show recent sessions across all user's pods
show_recent_sessions() {
    local limit="${1:-10}" # Default to 10 if not provided
    echo ""
    echo "🕐 Recent Sessions Across All Pods for $POD_USER_NAME (Last $limit)"
    echo "----------------------------------------------------------------"
    
    local user_pods_dl_dir="$TEMP_DIR/user_pod_summaries_for_recent" # Use a different temp dir or ensure it's cleared
    mkdir -p "$user_pods_dl_dir"

    echo "ℹ️ Downloading all execution_summary.json files for recent session analysis..."
    rclone lsjson "$S3_USER_SESSIONS_BASE/" --recursive --include "*/_pod_tracking/execution_summary.json" 2>/dev/null | \
        jq -r '.[].Path' | \
        while IFS= read -r s3_path; do
            local local_path_suffix=$(echo "$s3_path" | sed "s|^.*/pod_sessions/$POD_USER_NAME/||")
            mkdir -p "$user_pods_dl_dir/$(dirname "$local_path_suffix")"
            rclone copyto "$S3_USER_SESSIONS_BASE/$s3_path" "$user_pods_dl_dir/$local_path_suffix" --retries 2 || \
                echo "⚠️ Failed to download $s3_path for recent session analysis"
        done
        
    local all_sessions_file="$TEMP_DIR/all_sessions_collected.json"
    # Initialize as an empty array
    echo "[]" > "$all_sessions_file"
    
    find "$user_pods_dl_dir" -name "execution_summary.json" -type f | while IFS= read -r summary_file; do
        local pod_id_from_summary=$(jq -r '.pod_id // "unknown_pod"' "$summary_file")
        
        # Add pod_id to each session history entry and merge with the main collection
        jq --arg pid "$pod_id_from_summary" \
           'if .session_history and (.session_history | length > 0) then .session_history | map(. + {pod_id_source: $pid}) else [] end' \
           "$summary_file" | \
        jq -s '.[0] + .[1]' "$all_sessions_file" - > "$all_sessions_file.tmp" && \
        mv "$all_sessions_file.tmp" "$all_sessions_file"
    done
    
    local session_count=$(jq '. | length' "$all_sessions_file")
    if [ "$session_count" -gt 0 ]; then
        jq -r --argjson limit "$limit" '
            sort_by(.session_end // "0000-00-00T00:00:00Z") | reverse | .[:$limit] | .[] |
            "-----------------------------------------" +
            "\nPod ID: \(.pod_id_source // .pod_id // "N/A")" +
            "\n  Started: \(.session_start // "N/A")" +
            "\n  Ended: \(.session_end // "N/A")" +
            "\n  Duration: \(.duration_human // "00:00:00")" +
            "\n  Status: \(.status // "N/A")" +
            "\n  Type: \(.pod_type // "N/A") - GPU: \(.gpu // "none")" +
            "\n  Services: ComfyUI=\((.services.comfyui_started // false) | tostring), Jupyter=\((.services.jupyter_started // false) | tostring)"
        ' "$all_sessions_file"
        echo "-----------------------------------------"
    else
        echo "No sessions found to display."
    fi
    # rm -f "$all_sessions_file" "$all_sessions_file.tmp" # Temp dir will be cleaned up
    echo ""
}

# Function to show current session info from local file
show_current_session_local() {
    echo ""
    echo "🏃 Current Session (from local file, if running inside a tracked pod)"
    echo "--------------------------------------------------------------------"
    
    local local_current_session_file="$TRACKING_DIR/current_session.json"
    if [ -f "$local_current_session_file" ]; then
        echo "Pod ID: $(jq -r '.pod_id // "N/A"' "$local_current_session_file")"
        echo "User: $(jq -r '.user // "N/A"' "$local_current_session_file")"
        echo "Started: $(jq -r '.session.start_time // "N/A"' "$local_current_session_file")"
        echo "Current Duration: $(jq -r '.session.duration_human // "00:00:00"' "$local_current_session_file")"
        echo "Status: $(jq -r '.session.status // "N/A"' "$local_current_session_file")"
        echo "Last Update: $(jq -r '.session.last_update // "N/A"' "$local_current_session_file")"
        echo "--- Metrics ---"
        echo "ComfyUI Started: $(jq -r '.metrics.comfyui_started // false' "$local_current_session_file")"
        echo "Jupyter Started: $(jq -r '.metrics.jupyter_started // false' "$local_current_session_file")"
        echo "S3 Mounted: $(jq -r '.metrics.s3_mounted // false' "$local_current_session_file")"
        echo "--- Pod Info ---"
        echo "Type: $(jq -r '.pod_info.type // "N/A"' "$local_current_session_file")"
        echo "GPU: $(jq -r '.pod_info.gpu // "N/A"' "$local_current_session_file")"
        echo "Hostname: $(jq -r '.pod_info.hostname // "N/A"' "$local_current_session_file")"
        echo "Network Volume: $(jq -r '.pod_info.network_volume // "N/A"' "$local_current_session_file")"
    else
        echo "No local current_session.json file found at $local_current_session_file."
        echo "This command is most useful when run inside a pod being actively tracked."
    fi
    echo ""
}

# Function to show S3 integration status
show_s3_status() {
    echo ""
    echo "🗂️ S3 Integration Status for $POD_USER_NAME"
    echo "------------------------------------------"
    
    echo "ℹ️ Checking S3 connectivity to base path: $S3_USER_SESSIONS_BASE/"
    if rclone lsd "$S3_USER_SESSIONS_BASE/" --retries 1 --max-depth 1; then
        echo "✅ S3 connectivity: Working"
        echo "📊 Sync-only mode: All operations use rclone sync/copy (no FUSE mounts)"
        
        echo "📁 Your tracked Pod ID directories in S3:"
        local found_pods=false
        rclone lsf "$S3_USER_SESSIONS_BASE/" --dirs-only --retries 1 | while IFS= read -r pod_dir; do
            echo "  - ${pod_dir%/}" # Remove trailing slash
            found_pods=true
        done
        if ! $found_pods; then
            echo "  No pod directories found for user $POD_USER_NAME under $S3_USER_SESSIONS_BASE/"
        fi
        
        # Example for shared resources - adapt path as needed
        local s3_shared_base="s3:$AWS_BUCKET_NAME/pod_sessions/global_shared/"
        echo "🔗 Checking for global shared resources (example path: $s3_shared_base):"
        if rclone lsd "$s3_shared_base" --retries 1 --max-depth 1 2>/dev/null; then
             rclone lsf "$s3_shared_base" --dirs-only --retries 1 | while IFS= read -r shared_item; do
                echo "  - Global: ${shared_item%/}"
            done
        else
            echo "  - No global shared resources found at $s3_shared_base or path not accessible."
        fi
    else
        echo "❌ S3 connectivity ($S3_USER_SESSIONS_BASE/): Failed"
        echo "   Please check your AWS credentials (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION),"
        echo "   rclone configuration, and network connectivity."
    fi
    echo ""
}

# --- Main Execution Logic ---
COMMAND="${1:-summary}" # Default to summary

# Cleanup function to be called on exit
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        echo "ℹ️ Cleaning up temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT # Register cleanup function

case "$COMMAND" in
    "summary")
        if [ -n "$CURRENT_POD_ID" ]; then
            show_current_pod_summary
        fi
        show_user_summary
        show_current_session_local # Show local file info
        ;;
    "recent")
        show_recent_sessions "${2:-10}" # Pass optional limit
        ;;
    "current") # Specifically for the local current_session.json
        show_current_session_local
        ;;
    "pod") # Specifically for the current POD_ID's summary from S3
        show_current_pod_summary
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
        show_current_session_local
        show_recent_sessions "${2:-20}" # Allow overriding limit for full report
        show_s3_status
        ;;
    "help"|"--help"|"-h")
        echo "Usage: $0 [COMMAND] [OPTIONS]"
        echo ""
        echo "Commands:"
        echo "  summary            - Show current pod S3 summary (if POD_ID set), aggregated user summary, and local session info (default)."
        echo "  recent [N]         - Show N most recent sessions across all user's pods (default N=10)."
        echo "  current            - Show details from the local 'current_session.json' file (if present)."
        echo "  pod                - Show current pod's execution summary from S3 (requires POD_ID env var)."
        echo "  user               - Show user-level aggregated summary from all their pod data in S3."
        echo "  s3                 - Show S3 integration status and list tracked pod directories."
        echo "  full [N]           - Show all available information (recent sessions N=20 by default)."
        echo "  help               - Display this help message."
        echo ""
        echo "Environment Variables:"
        echo "  Required: AWS_BUCKET_NAME, POD_USER_NAME"
        echo "  Optional: POD_ID (for 'pod' and context-aware 'summary'/'full'), NETWORK_VOLUME (for 'current')"
        echo ""
        echo "Examples:"
        echo "  $0                     # Default summary view"
        echo "  $0 recent 5            # Show last 5 sessions"
        echo "  export POD_ID=xyz123; $0 pod # Show S3 summary for pod xyz123"
        ;;
    *)
        echo "❌ Invalid command: $COMMAND"
        echo "Run '$0 help' for usage information."
        exit 1
        ;;
esac

exit 0