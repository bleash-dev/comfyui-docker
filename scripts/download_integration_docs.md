# =============================================================================
# DOCUMENTATION FOR API CONSUMPTION
# =============================================================================

Model Download System API Functions
==================================

This script provides a robust model download system for backend API consumption.
All downloads use S3 paths (originalS3Path) instead of external URLs.

MAIN FUNCTIONS:

1. download_models(mode, models_param, output_file)
   Purpose: Download models from S3 using queue system
   Parameters:
     - mode: "all", "missing", "list", or "single"
     - models_param: JSON array (list mode) or JSON object (single mode)
     - output_file: Optional file path for progress output
   Returns: Path to progress file
   Usage Examples:
     download_models "missing"
     download_models "single" '{"directoryGroup":"checkpoints","modelName":"model.safetensors","originalS3Path":"s3://bucket/path","localPath":"/path/model.safetensors","modelSize":1234567}'

2. get_download_progress(group, model_name, local_path, output_file)
   Purpose: Get progress for specific model download
   Parameters: Either (group + model_name) OR local_path
   Returns: Path to progress JSON file

3. get_all_download_progress(output_file)
   Purpose: Get progress for all downloads
   Returns: Path to complete progress JSON file

4. cancel_download(group, model_name, local_path)
   Purpose: Cancel queued or in-progress download (works independently)
   Parameters: Either (group + model_name) OR local_path
   Note: Works at any point during execution, can interrupt active downloads

5. cancel_download_by_path(local_path)
   Purpose: Convenience function to cancel download by local path only
   Parameters: local_path of the model file

6. cancel_all_downloads()
   Purpose: Cancel all active and queued downloads immediately
   Note: Stops worker and clears all download state

7. list_active_downloads(format)
   Purpose: List all active downloads for monitoring
   Parameters: format ("json", "table", or "simple")
   Returns: List of active downloads with progress

8. start_download_worker()
   Purpose: Start background download worker
   Note: Worker respects cancellation signals and global stop commands

9. stop_download_worker(force_stop)
   Purpose: Stop background download worker (works independently)
   Parameters: force_stop (optional, cancels all downloads if true)
   Note: Uses multiple strategies to find and stop workers

ADVANCED CANCELLATION:

- is_download_cancelled(group, model_name): Check if specific download is cancelled
- should_stop_all_downloads(): Check for global stop signal
- terminate_active_download(group, model_name): Force terminate active download process

QUEUE MANAGEMENT:

- add_to_download_queue(group, model_name, s3_path, local_path, total_size)
- remove_from_download_queue(group, model_name)
- get_next_download(output_file)

PROGRESS TRACKING:

Progress JSON structure per model:
{
  "groupName": {
    "modelName": {
      "totalSize": 1234567,
      "localPath": "/path/to/model.safetensors",
      "downloaded": 123456,
      "status": "queued|progress|completed|failed|cancelled",
      "lastUpdated": "2025-07-14T10:30:45.123Z"
    }
  }
}

KEY FEATURES:

- Uses originalS3Path from model config for S3 downloads
- Prevents duplicate queue entries
- Comprehensive progress tracking
- Download cancellation support
- Automatic symlink resolution after download
- Thread-safe queue and progress operations
- Error handling and logging

LOG FILES:

- Download Log: $MODEL_DOWNLOAD_LOG
- Progress File: $DOWNLOAD_PROGRESS_FILE
- Queue File: $DOWNLOAD_QUEUE_FILE

HELP


# Initialize download system on script load
initialize_download_system

# Display system status if called with debug flag
if [ "${1:-}" = "--debug" ] || [ "${1:-}" = "--status" ]; then
    echo "🔍 Model Download System Status"
    echo "==============================="
    echo ""
    echo "Configuration:"
    echo "  Queue File: $DOWNLOAD_QUEUE_FILE"
    echo "  Progress File: $DOWNLOAD_PROGRESS_FILE"
    echo "  Lock Directory: $DOWNLOAD_LOCK_DIR"
    echo "  PID File: $DOWNLOAD_PID_FILE"
    echo "  Log File: $MODEL_DOWNLOAD_LOG"
    echo ""
    echo "AWS Configuration:"
    echo "  AWS_BUCKET_NAME: ${AWS_BUCKET_NAME:+'Set' || 'Not set'}"
    echo "  AWS CLI: $(command -v aws >/dev/null 2>&1 && echo 'Available' || echo 'Not available')"
    echo ""
    
    # Queue status
    if [ -f "$DOWNLOAD_QUEUE_FILE" ]; then
        local queue_count
        queue_count=$(jq 'length' "$DOWNLOAD_QUEUE_FILE" 2>/dev/null || echo "0")
        echo "Queue: $queue_count items"
    else
        echo "Queue: Not initialized"
    fi
    
    # Worker status
    if [ -f "$DOWNLOAD_PID_FILE" ]; then
        local worker_pid
        worker_pid=$(cat "$DOWNLOAD_PID_FILE" 2>/dev/null || echo "")
        if [ -n "$worker_pid" ] && kill -0 "$worker_pid" 2>/dev/null; then
            echo "Worker: Running (PID: $worker_pid)"
        else
            echo "Worker: Stopped (stale PID file)"
        fi
    else
        echo "Worker: Stopped"
    fi
    
    echo ""
fi