#!/bin/bash
# Test script for model download system

set -e

# Test configuration
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$(dirname "$TEST_DIR")/../scripts" && pwd)"
NETWORK_VOLUME="${NETWORK_VOLUME:-$TEST_DIR/test_volume}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test results tracking
TESTS_PASSED=0
TESTS_FAILED=0
TOTAL_TESTS=0

echo -e "${BLUE}🧪 Testing Model Download System${NC}"
echo "============================================="
echo ""

# Setup test environment
setup_test_environment() {
    echo -e "${BLUE}📋 Setting up test environment...${NC}"
    
    # Clean up any existing test volume
    rm -rf "$NETWORK_VOLUME"
    mkdir -p "$NETWORK_VOLUME/scripts"
    mkdir -p "$NETWORK_VOLUME/ComfyUI/models/checkpoints"
    mkdir -p "$NETWORK_VOLUME/ComfyUI/models/loras"
    mkdir -p "$NETWORK_VOLUME/ComfyUI/models/embeddings"
    
    # Set environment variables
    export NETWORK_VOLUME
    export AWS_BUCKET_NAME="test-bucket"
    export API_BASE_URL="https://api.test.com"
    export POD_ID="test-pod-123"
    export POD_USER_NAME="testuser"
    export WEBHOOK_SECRET_KEY="test-secret-key"
    export SKIP_GLOBAL_STOP_SIGNAL="true"  # Skip global stop signal in tests
    
    # Generate required scripts
    cd "$SCRIPTS_DIR"
    bash create_api_client.sh >/dev/null 2>&1
    bash create_model_config_manager.sh >/dev/null 2>&1
    bash create_model_download_integration.sh >/dev/null 2>&1
    
    # Source the model download integration script
    if [ ! -f "$NETWORK_VOLUME/scripts/model_download_integration.sh" ]; then
        echo -e "${RED}❌ Model download integration script was not created${NC}"
        exit 1
    fi
    
    source "$NETWORK_VOLUME/scripts/model_download_integration.sh"
    
    # Create mock download server using Python
    create_mock_download_server
    
    echo -e "${GREEN}✅ Test environment setup complete${NC}"
    echo ""
}

# Create mock S3 server and AWS CLI
create_mock_download_server() {
    # Create a mock AWS CLI script that simulates S3 downloads
    cat > "$NETWORK_VOLUME/aws" << 'EOF'
#!/bin/bash
# Mock AWS CLI for testing S3 downloads

# Parse command line arguments
if [ "$1" = "s3" ] && [ "$2" = "cp" ]; then
    S3_SOURCE="$3"
    LOCAL_DEST="$4"
    
    # Extract model name from S3 path
    MODEL_NAME=$(basename "$S3_SOURCE")
    
    # Create test data based on model name
    case "$MODEL_NAME" in
        "test_model_1.safetensors")
            # Create 1KB test file
            head -c 1024 </dev/zero | tr '\0' 'x' > "$LOCAL_DEST"
            echo "Downloaded $MODEL_NAME 1024 bytes" >&2
            ;;
        "test_model_2.safetensors")
            # Create 2KB test file
            head -c 2048 </dev/zero | tr '\0' 'y' > "$LOCAL_DEST"
            echo "Downloaded $MODEL_NAME 2048 bytes" >&2
            ;;
        "large_model.safetensors")
            # Create 5MB test file with progress simulation
            echo "Downloading large model..." >&2
            head -c 5242880 </dev/zero | tr '\0' 'z' > "$LOCAL_DEST"
            echo "Downloaded $MODEL_NAME 5242880 bytes" >&2
            ;;
        "error_model.safetensors")
            # Simulate download error
            echo "Error: File not found in S3" >&2
            exit 1
            ;;
        "background_test.safetensors")
            # Create slow download for timing test
            sleep 2
            head -c 512 </dev/zero | tr '\0' 't' > "$LOCAL_DEST"
            echo "Downloaded $MODEL_NAME 512 bytes" >&2
            ;;
        *)
            # Default small file
            head -c 512 </dev/zero | tr '\0' 't' > "$LOCAL_DEST"
            echo "Downloaded $MODEL_NAME 512 bytes" >&2
            ;;
    esac
    
    exit 0
elif [ "$1" = "s3api" ] && [ "$2" = "head-object" ]; then
    # Mock S3 HeadObject operation for file existence check
    echo "Mock HeadObject operation" >&2
    exit 0
else
    # For other AWS commands, just return success
    echo "Mock AWS CLI: $*" >&2
    exit 0
fi
EOF
    
    chmod +x "$NETWORK_VOLUME/aws"
    
    # Add mock AWS to PATH
    export PATH="$NETWORK_VOLUME:$PATH"
    
    echo "Mock AWS CLI created and added to PATH"
}

# Cleanup test environment
cleanup_test_environment() {
    echo -e "${BLUE}🧹 Cleaning up test environment...${NC}"
    
    # Clean up test volume
    rm -rf "$NETWORK_VOLUME"
    
    echo -e "${GREEN}✅ Cleanup complete${NC}"
}

# Helper function to run a test
run_test() {
    local test_name="$1"
    local test_function="$2"
    
    echo -e "${YELLOW}🔍 Running: $test_name${NC}"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    if $test_function; then
        echo -e "${GREEN}✅ PASS: $test_name${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}❌ FAIL: $test_name${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    echo ""
}

# Helper function to wait for downloads to complete
wait_for_downloads() {
    local max_wait="$1"
    local waited=0
    
    while [ $waited -lt $max_wait ]; do
        # Check if queue is empty
        local queue_length
        queue_length=$(jq 'length' "$DOWNLOAD_QUEUE_FILE" 2>/dev/null || echo "0")
        
        if [ "$queue_length" -eq 0 ]; then
            return 0
        fi
        
        sleep 1
        waited=$((waited + 1))
    done
    
    return 1
}

# Test 1: Setup test data
test_setup_download_data() {
    echo "Setting up test models in configuration..."
    
    # Create test model configurations with S3 paths
    local model1_json='{
        "modelName": "test_model_1",
        "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/checkpoints/test_model_1.safetensors",
        "originalS3Path": "/models/checkpoints/test_model_1.safetensors",
        "modelSize": 1024,
        "downloadUrl": "https://example.com/test_model_1.safetensors"
    }'
    
    local model2_json='{
        "modelName": "test_model_2",
        "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/loras/test_model_2.safetensors",
        "originalS3Path": "models/loras/test_model_2.safetensors",
        "modelSize": 2048,
        "downloadUrl": "https://example.com/test_model_2.safetensors"
    }'
    
    local model3_json='{
        "modelName": "large_model",
        "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/checkpoints/large_model.safetensors",
        "originalS3Path": "models/checkpoints/large_model.safetensors",
        "modelSize": 5242880,
        "downloadUrl": "https://example.com/large_model.safetensors"
    }'
    
    local model4_json='{
        "modelName": "error_model",
        "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/embeddings/error_model.safetensors",
        "originalS3Path": "models/embeddings/error_model.safetensors",
        "modelSize": 1024,
        "downloadUrl": "http://localhost:8765/error_model.safetensors"
    }'
    
    # Add symlink model (should not be downloaded)
    local symlink_json='{
        "modelName": "symlink_model",
        "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/checkpoints/symlink_model.safetensors",
        "originalS3Path": "models/checkpoints/symlink_model.safetensors",
        "symLinkedFrom": "models/checkpoints/test_model_1.safetensors",
        "modelSize": 1024
    }'
    
    # Add models to config
    create_or_update_model "checkpoints" "$model1_json"
    create_or_update_model "loras" "$model2_json" 
    create_or_update_model "checkpoints" "$model3_json"
    create_or_update_model "embeddings" "$model4_json"
    create_or_update_model "checkpoints" "$symlink_json"
    
    echo "Test data setup complete: 4 local models + 1 symlink"
    return 0
}

# Test 2: Download progress management
test_download_progress_management() {
    echo "Testing download progress management..."
    
    # Clean up any existing locks first
    stop_download_worker force >/dev/null 2>&1
    sleep 1
    
    # Remove any global stop signals immediately
    rm -f "$NETWORK_VOLUME/.stop_all_downloads" 2>/dev/null || true
    
    # Force clean up any stale lock files
    rm -rf "$DOWNLOAD_LOCK_DIR"/*.lock 2>/dev/null || true
    mkdir -p "$DOWNLOAD_LOCK_DIR"
    
    # Test updating progress
    update_download_progress "checkpoints" "test_model" "/test/path/model.safetensors" "1024" "0" "queued"
    
    # Test getting progress
    local progress_file
    progress_file=$(get_download_progress "checkpoints" "test_model")
    
    if [ ! -f "$progress_file" ]; then
        echo "Failed to get progress file"
        return 1
    fi
    
    local status
    status=$(jq -r '.status // empty' "$progress_file")
    rm -f "$progress_file"
    
    if [ "$status" != "queued" ]; then
        echo "Expected status 'queued', got '$status'"
        return 1
    fi
    
    # Test updating with download progress
    update_download_progress "checkpoints" "test_model" "/test/path/model.safetensors" "1024" "512" "downloading"
    
    progress_file=$(get_download_progress "checkpoints" "test_model")
    local downloaded total_size
    downloaded=$(jq -r '.downloaded // empty' "$progress_file")
    total_size=$(jq -r '.totalSize // empty' "$progress_file")
    rm -f "$progress_file"
    
    if [ "$downloaded" != "512" ] || [ "$total_size" != "1024" ]; then
        echo "Progress update failed: downloaded=$downloaded, total=$total_size"
        return 1
    fi
    
    echo "Download progress management working correctly"
    return 0
}

# Test 3: Download queue management
test_download_queue_management() {
    echo "Testing download queue management..."
    
    # Initialize the download system
    initialize_download_system
    
    # Test adding to queue
    add_to_download_queue "checkpoints" "queue_test" "/test_model_1.safetensors" "$NETWORK_VOLUME/ComfyUI/models/checkpoints/test.safetensors" "1024"
    
    # Check if queue has items
    local queue_length
    queue_length=$(jq 'length' "$DOWNLOAD_QUEUE_FILE" 2>/dev/null || echo "0")
    if [ "$queue_length" -ne 1 ]; then
        echo "Queue should have 1 item, has $queue_length"
        return 1
    fi
    
    # Verify queue file content
    local queue_model_name
    queue_model_name=$(jq -r '.[0].modelName // empty' "$DOWNLOAD_QUEUE_FILE")
    
    if [ "$queue_model_name" != "queue_test" ]; then
        echo "Queue data incorrect: expected 'queue_test', got '$queue_model_name'"
        return 1
    fi
    
    # Test preventing duplicates
    add_to_download_queue "checkpoints" "queue_test" "/test_model_1.safetensors" "$NETWORK_VOLUME/ComfyUI/models/checkpoints/test.safetensors" "1024"
    
    # Should still be only one item
    queue_length=$(jq 'length' "$DOWNLOAD_QUEUE_FILE" 2>/dev/null || echo "0")
    if [ "$queue_length" -ne 1 ]; then
        echo "Duplicate prevention failed: found $queue_length queue items"
        return 1
    fi
    
    # Test removing from queue
    remove_from_download_queue "checkpoints" "queue_test"
    
    # Check queue is now empty
    queue_length=$(jq 'length' "$DOWNLOAD_QUEUE_FILE" 2>/dev/null || echo "0")
    if [ "$queue_length" -ne 0 ]; then
        echo "Queue should be empty after removal, has $queue_length items"
        return 1
    fi
    
    echo "Download queue management working correctly"
    return 0
}

# Test 4: Single model download
test_single_model_download() {
    echo "Testing single model download..."
    
    initialize_download_system
    
    local test_path="$NETWORK_VOLUME/ComfyUI/models/checkpoints/test_single.safetensors"
    
    # Ensure file doesn't exist
    rm -f "$test_path"
    
    # Create test model object
    local test_model='{
        "directoryGroup": "checkpoints",
        "modelName": "test_single.safetensors",
        "originalS3Path": "/test_model_1.safetensors",
        "localPath": "'$test_path'",
        "modelSize": 1024
    }'
    
    # Test successful download
    local result_file
    result_file=$(download_models "single" "$test_model")
    
    if [ ! -f "$result_file" ]; then
        echo "Download result file not returned"
        return 1
    fi
    
    # Wait for download to complete  
    if ! wait_for_downloads 10; then
        echo "Download did not complete within timeout"
        return 1
    fi
    
    if [ ! -f "$test_path" ]; then
        echo "Download succeeded but file was not created"
        return 1
    fi
    
    local file_size
    file_size=$(stat -f%z "$test_path" 2>/dev/null || stat -c%s "$test_path" 2>/dev/null || echo "0")
    
    if [ "$file_size" != "1024" ]; then
        echo "Downloaded file has wrong size: expected 1024, got $file_size"
        return 1
    fi
    
    echo "Single model download working correctly"
    rm -f "$result_file"
    return 0
}

# Test 5: Download missing models
test_download_missing_models() {
    echo "Testing download missing models..."
    
    # Ensure some files don't exist (should be downloaded)
    rm -f "$NETWORK_VOLUME/ComfyUI/models/checkpoints/test_model_1.safetensors"
    rm -f "$NETWORK_VOLUME/ComfyUI/models/loras/test_model_2.safetensors"
    
    # Ensure one file exists (should be skipped)
    echo "existing content" > "$NETWORK_VOLUME/ComfyUI/models/checkpoints/large_model.safetensors"
    
    # Start download of missing models
    local progress_file
    progress_file=$(download_models "missing")
    
    if [ ! -f "$progress_file" ]; then
        echo "Progress file was not returned"
        return 1
    fi
    
    # Wait for downloads to complete
    if ! wait_for_downloads 30; then
        echo "Downloads did not complete within timeout"
        return 1
    fi
    
    # Check that missing files were downloaded
    if [ ! -f "$NETWORK_VOLUME/ComfyUI/models/checkpoints/test_model_1.safetensors" ]; then
        echo "Missing model 1 was not downloaded"
        return 1
    fi
    
    if [ ! -f "$NETWORK_VOLUME/ComfyUI/models/loras/test_model_2.safetensors" ]; then
        echo "Missing model 2 was not downloaded"
        return 1
    fi
    
    # Check file sizes
    local size1 size2
    size1=$(stat -f%z "$NETWORK_VOLUME/ComfyUI/models/checkpoints/test_model_1.safetensors" 2>/dev/null || stat -c%s "$NETWORK_VOLUME/ComfyUI/models/checkpoints/test_model_1.safetensors" 2>/dev/null || echo "0")
    size2=$(stat -f%z "$NETWORK_VOLUME/ComfyUI/models/loras/test_model_2.safetensors" 2>/dev/null || stat -c%s "$NETWORK_VOLUME/ComfyUI/models/loras/test_model_2.safetensors" 2>/dev/null || echo "0")
    
    if [ "$size1" != "1024" ]; then
        echo "Downloaded model 1 has wrong size: expected 1024, got $size1"
        return 1
    fi
    
    if [ "$size2" != "2048" ]; then
        echo "Downloaded model 2 has wrong size: expected 2048, got $size2"
        return 1
    fi
    
    echo "Download missing models working correctly"
    return 0
}

# Test 6: Download cancellation
test_download_cancellation() {
    echo "Testing download cancellation..."
    
    # Add a large model to queue (won't start immediately due to processing delay)
    add_to_download_queue "checkpoints" "cancel_test" "http://localhost:8765/large_model.safetensors" "$NETWORK_VOLUME/ComfyUI/models/cancel_test.safetensors" "5242880"
    
    # Verify it's in queue using the queue management function
    local queue_count
    queue_count=$(jq --arg group "checkpoints" --arg modelName "cancel_test" \
        '[.[] | select(.group == $group and .modelName == $modelName)] | length' \
        "$DOWNLOAD_QUEUE_FILE" 2>/dev/null || echo "0")
    
    if [ "$queue_count" -eq 0 ]; then
        echo "Model was not added to queue"
        return 1
    fi
    
    # Cancel the download
    cancel_download "checkpoints" "cancel_test"
    
    # Verify it's removed from queue
    queue_count=$(jq --arg group "checkpoints" --arg modelName "cancel_test" \
        '[.[] | select(.group == $group and .modelName == $modelName)] | length' \
        "$DOWNLOAD_QUEUE_FILE" 2>/dev/null || echo "0")
    
    if [ "$queue_count" -gt 0 ]; then
        echo "Model was not removed from queue after cancellation"
        return 1
    fi
    
    # Verify progress status
    local progress_file
    progress_file=$(get_download_progress "checkpoints" "cancel_test")
    
    if [ -f "$progress_file" ]; then
        local status
        status=$(jq -r '.status // empty' "$progress_file")
        rm -f "$progress_file"
        
        if [ "$status" != "cancelled" ]; then
            echo "Expected status 'cancelled', got '$status'"
            return 1
        fi
    fi
    
    echo "Download cancellation working correctly"
    return 0
}

# Test 7: Download list of models
test_download_model_list() {
    echo "Testing download from model list..."
    
    # Create test models list
    local models_list='[
        {
            "directoryGroup": "checkpoints",
            "modelName": "list_test_1",
            "originalS3Path": "/test_model_1.safetensors",
            "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/checkpoints/list_test_1.safetensors",
            "modelSize": 1024
        },
        {
            "directoryGroup": "loras", 
            "modelName": "list_test_2",
            "originalS3Path": "/test_model_2.safetensors",
            "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/loras/list_test_2.safetensors",
            "modelSize": 2048
        }
    ]'
    
    # Start download from list
    local progress_file
    progress_file=$(download_models "list" "$models_list")
    
    if [ ! -f "$progress_file" ]; then
        echo "Progress file was not returned"
        return 1
    fi
    
    # Wait for downloads to complete
    if ! wait_for_downloads 15; then
        echo "Downloads did not complete within timeout"
        return 1
    fi
    
    # Check that files were downloaded
    if [ ! -f "$NETWORK_VOLUME/ComfyUI/models/checkpoints/list_test_1.safetensors" ]; then
        echo "List model 1 was not downloaded"
        return 1
    fi
    
    if [ ! -f "$NETWORK_VOLUME/ComfyUI/models/loras/list_test_2.safetensors" ]; then
        echo "List model 2 was not downloaded"
        return 1
    fi
    
    echo "Download from model list working correctly"
    return 0
}

# Test 8: Download progress by path
test_download_progress_by_path() {
    echo "Testing download progress by path..."
    
    local test_path="$NETWORK_VOLUME/ComfyUI/models/checkpoints/path_test.safetensors"
    
    # Update progress for a model
    update_download_progress "checkpoints" "path_test" "$test_path" "1024" "512" "downloading"
    
    # Get progress by path
    local progress_file
    progress_file=$(get_download_progress_by_path "$test_path")
    
    if [ ! -f "$progress_file" ]; then
        echo "Progress file was not returned"
        return 1
    fi
    
    local status downloaded
    status=$(jq -r '.status // empty' "$progress_file")
    downloaded=$(jq -r '.downloaded // empty' "$progress_file")
    rm -f "$progress_file"
    
    if [ "$status" != "downloading" ]; then
        echo "Expected status 'downloading', got '$status'"
        return 1
    fi
    
    if [ "$downloaded" != "512" ]; then
        echo "Expected downloaded '512', got '$downloaded'"
        return 1
    fi
    
    echo "Download progress by path working correctly"
    return 0
}

# Test 9: Error handling
test_error_handling() {
    echo "Testing error handling..."
    
    # Test invalid mode
    if download_models "invalid_mode" ""; then
        echo "Should have failed with invalid mode"
        return 1
    fi
    
    # Test missing parameters
    if update_download_progress "" "test" "queued"; then
        echo "Should have failed with missing group"
        return 1
    fi
    
    if get_download_progress "" "test"; then
        echo "Should have failed with missing group"
        return 1
    fi
    
    # Test invalid JSON for list mode
    if download_models "list" "invalid json"; then
        echo "Should have failed with invalid JSON"
        return 1
    fi
    
    echo "Error handling working correctly"
    return 0
}

# Test 10: Symlink resolution after download
test_symlink_resolution_after_download() {
    echo "Testing symlink resolution after download..."
    
    # Remove the target file first so it will be downloaded again
    rm -f "$NETWORK_VOLUME/ComfyUI/models/checkpoints/test_model_1.safetensors"
    
    # Download a model that should create symlinks
    local single_model='{
        "directoryGroup": "checkpoints",
        "modelName": "test_model_1.safetensors",
        "originalS3Path": "/test_model_1.safetensors",
        "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/checkpoints/test_model_1.safetensors",
        "modelSize": 1024
    }'
    
    # This should trigger symlink resolution after download
    download_models "single" "$single_model"
    
    # Wait for processing
    sleep 3
    
    # Check if the target file was downloaded
    if [ ! -f "$NETWORK_VOLUME/ComfyUI/models/checkpoints/test_model_1.safetensors" ]; then
        echo "Target model was not downloaded"
        return 1
    fi
    
    # Check if symlink was created (we have a symlinked model in config pointing to test_model_1)
    local symlink_path="$NETWORK_VOLUME/ComfyUI/models/checkpoints/symlink_model.safetensors"
    
    if [ ! -L "$symlink_path" ]; then
        echo "Symlink was not created after download"
        return 1
    fi
    
    # Verify symlink points to correct target
    local link_target
    link_target=$(readlink "$symlink_path")
    
    if [[ "$link_target" != *"test_model_1.safetensors" ]]; then
        echo "Symlink points to wrong target: $link_target"
        return 1
    fi
    
    echo "Symlink resolution after download working correctly"
    return 0
}

# Test 11: Background worker behavior
test_background_worker_behavior() {
    echo "Testing background worker behavior..."
    
    # Add a download to test immediate return
    local test_model='{
        "directoryGroup": "checkpoints",
        "modelName": "background_test.safetensors",
        "originalS3Path": "/models/checkpoints/background_test.safetensors",
        "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/checkpoints/background_test.safetensors",
        "modelSize": 1000
    }'
    
    # Test that download_models returns immediately
    local start_time=$(date +%s)
    
    local result_file
    result_file=$(download_models "single" "$test_model")
    local download_result=$?
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    if [ "$download_result" -ne 0 ] || [ "$duration" -ge 6 ]; then
        echo "❌ download_models should return within 6s took ${duration}s"
        return 1
    fi
    
    # Verify download was processed (check progress file instead of queue since it processes fast)
    local progress_status
    if [ -f "$result_file" ]; then
        progress_status=$(jq -r '.checkpoints["background_test.safetensors"].status // empty' "$result_file" 2>/dev/null)
        if [ -z "$progress_status" ]; then
            echo "❌ Download should be tracked in progress"
            return 1
        fi
    else
        echo "❌ Progress file should exist"
        return 1
    fi
    
    # Verify worker was started (check immediately or that work was done)
    local worker_started=false
    if [ -f "$DOWNLOAD_PID_FILE" ]; then
        worker_started=true
    else
        # Worker might have already finished, check if work was done
        if [ -f "$NETWORK_VOLUME/ComfyUI/models/checkpoints/background_test.safetensors" ]; then
            worker_started=true
        fi
    fi
    
    if [ "$worker_started" = false ]; then
        echo "❌ Worker should be started or work should be done"
        return 1
    fi
    
    # Wait for download to complete
    wait_for_downloads 10
    
    # Verify file was downloaded
    if [ ! -f "$NETWORK_VOLUME/ComfyUI/models/checkpoints/background_test.safetensors" ]; then
        echo "❌ File should be downloaded"
        return 1
    fi
    
    # Verify worker stops when queue is empty
    sleep 5  # Wait for worker to detect empty queue
    
    if [ -f "$DOWNLOAD_PID_FILE" ]; then
        local worker_pid
        worker_pid=$(cat "$DOWNLOAD_PID_FILE" 2>/dev/null || echo "")
        if [ -n "$worker_pid" ] && kill -0 "$worker_pid" 2>/dev/null; then
            echo "❌ Worker should stop when queue is empty"
            stop_download_worker true  # Force stop for cleanup
            rm -f "$NETWORK_VOLUME/.stop_all_downloads" 2>/dev/null || true
            return 1
        fi
    fi
    
    echo "✅ Background worker behavior test passed"
    rm -f "$result_file"
    return 0
}

# Test 12: Worker locking mechanism
test_worker_locking_mechanism() {
    echo "Testing worker locking mechanism..."
    
    # Temporarily disable SKIP_BACKGROUND_WORKER for this test
    local original_skip="${SKIP_BACKGROUND_WORKER:-false}"
    export SKIP_BACKGROUND_WORKER=false
    export SKIP_GLOBAL_STOP_SIGNAL=true  # Prevent global stop signals during test
    export SKIP_FORCE_KILL=true  # Skip force killing to avoid killing test process
    
    # Clean state - use gentle stop first
    stop_download_worker false
    # Remove any global stop signals
    rm -f "$NETWORK_VOLUME/.stop_all_downloads" 2>/dev/null || true
    sleep 2
    
    # Start first worker
    start_download_worker
    sleep 1
    
    # Check worker status
    local status_file
    status_file=$(get_worker_status)
    local first_status
    first_status=$(jq -r '.status' "$status_file" 2>/dev/null || echo "unknown")
    local first_pid
    first_pid=$(jq -r '.pid' "$status_file" 2>/dev/null || echo "")
    rm -f "$status_file"
    
    if [ "$first_status" != "running" ]; then
        echo "First worker should be running, status: $first_status"
        export SKIP_BACKGROUND_WORKER="$original_skip"
        export SKIP_GLOBAL_STOP_SIGNAL=false
        return 1
    fi
    
    # Try to start second worker (should be prevented by locking)
    start_download_worker
    sleep 1
    
    # Check that only one worker is running
    status_file=$(get_worker_status)
    local second_status
    second_status=$(jq -r '.status' "$status_file" 2>/dev/null || echo "unknown")
    local second_pid
    second_pid=$(jq -r '.pid' "$status_file" 2>/dev/null || echo "")
    rm -f "$status_file"
    
    if [ "$second_status" != "running" ]; then
        echo "Worker should still be running after second start attempt"
        export SKIP_BACKGROUND_WORKER="$original_skip"
        export SKIP_GLOBAL_STOP_SIGNAL=false
        return 1
    fi
    
    if [ "$first_pid" != "$second_pid" ]; then
        echo "Worker PID should not change (locking failed): $first_pid != $second_pid"
        export SKIP_BACKGROUND_WORKER="$original_skip"
        export SKIP_GLOBAL_STOP_SIGNAL=false
        return 1
    fi
    
    # Test gentle stop first
    stop_download_worker false
    rm -f "$NETWORK_VOLUME/.stop_all_downloads" 2>/dev/null || true
    sleep 3
    
    # Verify worker is stopped
    status_file=$(get_worker_status)
    local final_status
    final_status=$(jq -r '.status' "$status_file" 2>/dev/null || echo "unknown")
    rm -f "$status_file"
    
    if [ "$final_status" = "running" ]; then
        # If gentle stop didn't work, try force stop but be more careful
        echo "Gentle stop failed, trying force stop..."
        stop_download_worker true
        sleep 3
        
        status_file=$(get_worker_status)
        final_status=$(jq -r '.status' "$status_file" 2>/dev/null || echo "unknown")
        rm -f "$status_file"
        
        if [ "$final_status" = "running" ]; then
            echo "Worker should be stopped after force stop"
            export SKIP_BACKGROUND_WORKER="$original_skip"
            export SKIP_GLOBAL_STOP_SIGNAL=false
            return 1
        fi
    fi
    
    # Restore original settings
    export SKIP_BACKGROUND_WORKER="$original_skip"
    export SKIP_GLOBAL_STOP_SIGNAL=false
    
    echo "Worker locking mechanism working correctly"
    return 0
}

# Main test execution
main() {
    # Setup
    setup_test_environment
    
    # Run tests
    run_test "Setup Download Test Data" test_setup_download_data
    run_test "Download Progress Management" test_download_progress_management
    run_test "Download Queue Management" test_download_queue_management
    run_test "Single Model Download" test_single_model_download
    run_test "Download Missing Models" test_download_missing_models
    run_test "Download Cancellation" test_download_cancellation
    run_test "Download Model List" test_download_model_list
    run_test "Download Progress By Path" test_download_progress_by_path
    run_test "Error Handling" test_error_handling
    run_test "Symlink Resolution After Download" test_symlink_resolution_after_download
    run_test "Background Worker Behavior" test_background_worker_behavior
    run_test "Worker Locking Mechanism" test_worker_locking_mechanism
    
    # Cleanup
    cleanup_test_environment
    
    echo "============================================="
    echo "📊 Test Results Summary"
    echo "============================================="
    echo "Total Tests: $TOTAL_TESTS"
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"
    echo ""
    
    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}🎉 All tests passed! Model download system is working correctly.${NC}"
        exit 0
    else
        echo -e "${RED}❌ Some tests failed. Please check the output above.${NC}"
        exit 1
    fi
}

# Run main function
main "$@"
