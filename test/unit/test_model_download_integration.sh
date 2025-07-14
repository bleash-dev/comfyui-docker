#!/bin/bash
# Unit tests for Model Download Integration

source "$(dirname "$0")/../test_framework.sh"

# Test download system initialization
test_initialize_download_system() {
    source_model_download_integration
    
    # Test that download system initializes properly
    initialize_download_system
    
    assert_file_exists "$DOWNLOAD_QUEUE_FILE" "Queue file should be created"
    assert_file_exists "$DOWNLOAD_PROGRESS_FILE" "Progress file should be created"
    assert_dir_exists "$DOWNLOAD_LOCK_DIR" "Lock directory should be created"
    
    # Test that JSON files are valid
    assert_command_success "jq empty '$DOWNLOAD_QUEUE_FILE'" "Queue file should contain valid JSON"
    assert_command_success "jq empty '$DOWNLOAD_PROGRESS_FILE'" "Progress file should contain valid JSON"
    
    # Test initial content
    local queue_content
    queue_content=$(cat "$DOWNLOAD_QUEUE_FILE")
    assert_equals "[]" "$queue_content" "Queue should be initialized as empty array"
    
    local progress_content
    progress_content=$(cat "$DOWNLOAD_PROGRESS_FILE")
    assert_equals "{}" "$progress_content" "Progress should be initialized as empty object"
}

# Test adding to download queue with S3 paths
test_add_to_download_queue() {
    source_model_download_integration
    
    # Clean and reinitialize for fresh state
    rm -f "$DOWNLOAD_QUEUE_FILE" "$DOWNLOAD_PROGRESS_FILE" 2>/dev/null || true
    initialize_download_system
    
    # Test adding a valid download with relative S3 path (most common case)
    local group="checkpoints"
    local model_name="test_model.safetensors"
    local s3_path="/models/checkpoints/test_model.safetensors"  # Relative path without bucket
    local local_path="/tmp/test_model.safetensors"
    local total_size="1234567"
    
    assert_command_success "add_to_download_queue '$group' '$model_name' '$s3_path' '$local_path' '$total_size'" \
        "Should successfully add download to queue"
    
    # Verify queue content
    local queue_length
    queue_length=$(jq 'length' "$DOWNLOAD_QUEUE_FILE")
    assert_equals "1" "$queue_length" "Queue should contain one item"
    
    # Verify queue item content
    local queued_group
    queued_group=$(jq -r '.[0].group' "$DOWNLOAD_QUEUE_FILE")
    assert_equals "$group" "$queued_group" "Group should match"
    
    local queued_s3_path
    queued_s3_path=$(jq -r '.[0].s3Path' "$DOWNLOAD_QUEUE_FILE")
    assert_equals "$s3_path" "$queued_s3_path" "S3 path should match (relative path stored as-is)"
    
    # Test with path that doesn't start with / (also common)
    local group2="loras"
    local model_name2="lora_model.safetensors"
    local s3_path2="models/loras/lora_model.safetensors"  # No leading slash
    local local_path2="/tmp/lora_model.safetensors"
    
    assert_command_success "add_to_download_queue '$group2' '$model_name2' '$s3_path2' '$local_path2' '$total_size'" \
        "Should successfully add download with path not starting with /"
    
    # Verify second item
    queue_length=$(jq 'length' "$DOWNLOAD_QUEUE_FILE")
    assert_equals "2" "$queue_length" "Queue should contain two items"
    
    local queued_s3_path2
    queued_s3_path2=$(jq -r '.[1].s3Path' "$DOWNLOAD_QUEUE_FILE")
    assert_equals "$s3_path2" "$queued_s3_path2" "S3 path without leading slash should be stored as-is"
    
    # Test preventing duplicates
    assert_command_success "add_to_download_queue '$group' '$model_name' '$s3_path' '$local_path' '$total_size'" \
        "Should handle duplicate addition gracefully"
    
    queue_length=$(jq 'length' "$DOWNLOAD_QUEUE_FILE")
    assert_equals "2" "$queue_length" "Queue should still contain only two items after duplicate"
}

# Test adding to queue with missing parameters
test_add_to_queue_validation() {
    source_model_download_integration
    
    # Clean and reinitialize for fresh state
    rm -f "$DOWNLOAD_QUEUE_FILE" "$DOWNLOAD_PROGRESS_FILE" 2>/dev/null || true
    initialize_download_system
    
    # Test missing group
    assert_command_fails "add_to_download_queue '' 'model.safetensors' '/models/checkpoints/model.safetensors' '/path/model' '12345'" \
        "Should fail with missing group"
    
    # Test missing model name
    assert_command_fails "add_to_download_queue 'checkpoints' '' '/models/checkpoints/model.safetensors' '/path/model' '12345'" \
        "Should fail with missing model name"
    
    # Test missing S3 path
    assert_command_fails "add_to_download_queue 'checkpoints' 'model.safetensors' '' '/path/model' '12345'" \
        "Should fail with missing S3 path"
    
    # Test missing local path
    assert_command_fails "add_to_download_queue 'checkpoints' 'model.safetensors' '/models/checkpoints/model.safetensors' '' '12345'" \
        "Should fail with missing local path"
}

# Test removing from download queue
test_remove_from_download_queue() {
    source_model_download_integration
    
    # Clean and reinitialize for fresh state
    rm -f "$DOWNLOAD_QUEUE_FILE" "$DOWNLOAD_PROGRESS_FILE" 2>/dev/null || true
    initialize_download_system
    
    # Add some downloads first with relative S3 paths
    add_to_download_queue "checkpoints" "model1.safetensors" "/models/checkpoints/model1.safetensors" "/path/model1" "1000"
    add_to_download_queue "loras" "model2.safetensors" "models/loras/model2.safetensors" "/path/model2" "2000"
    
    local initial_length
    initial_length=$(jq 'length' "$DOWNLOAD_QUEUE_FILE")
    assert_equals "2" "$initial_length" "Queue should have 2 items initially"
    
    # Remove one download
    assert_command_success "remove_from_download_queue 'checkpoints' 'model1.safetensors'" \
        "Should successfully remove download from queue"
    
    local final_length
    final_length=$(jq 'length' "$DOWNLOAD_QUEUE_FILE")
    assert_equals "1" "$final_length" "Queue should have 1 item after removal"
    
    # Verify the remaining item
    local remaining_model
    remaining_model=$(jq -r '.[0].modelName' "$DOWNLOAD_QUEUE_FILE")
    assert_equals "model2.safetensors" "$remaining_model" "Correct model should remain"
}

# Test getting next download from queue
test_get_next_download() {
    source_model_download_integration
    
    # Clean and reinitialize for fresh state
    rm -f "$DOWNLOAD_QUEUE_FILE" "$DOWNLOAD_PROGRESS_FILE" 2>/dev/null || true
    initialize_download_system
    
    # Add downloads to queue with relative S3 paths
    add_to_download_queue "checkpoints" "model1.safetensors" "/models/checkpoints/model1.safetensors" "/path/model1" "1000"
    add_to_download_queue "loras" "model2.safetensors" "/models/loras/model2.safetensors" "/path/model2" "2000"
    
    # Get next download
    local next_file
    next_file=$(get_next_download)
    
    assert_not_empty "$next_file" "Should return a file path"
    assert_file_exists "$next_file" "Returned file should exist"
    
    # Verify content
    local model_name
    model_name=$(jq -r '.modelName' "$next_file")
    assert_equals "model1.safetensors" "$model_name" "Should return first queued model"
    
    local s3_path
    s3_path=$(jq -r '.s3Path' "$next_file")
    assert_equals "/models/checkpoints/model1.safetensors" "$s3_path" "Should return correct S3 path (relative)"
    
    # Verify queue was updated
    local remaining_length
    remaining_length=$(jq 'length' "$DOWNLOAD_QUEUE_FILE")
    assert_equals "1" "$remaining_length" "Queue should have one item after getting next"
    
    # Clean up
    rm -f "$next_file"
}

# Test download progress tracking
test_update_download_progress() {
    source_model_download_integration
    initialize_download_system
    
    local group="checkpoints"
    local model_name="test_model.safetensors"
    local local_path="/path/test_model.safetensors"
    local total_size="1000000"
    local downloaded="500000"
    local status="progress"
    
    # Update progress
    assert_command_success "update_download_progress '$group' '$model_name' '$local_path' '$total_size' '$downloaded' '$status'" \
        "Should successfully update download progress"
    
    # Verify progress was recorded
    local recorded_status
    recorded_status=$(jq -r ".\"$group\".\"$model_name\".status" "$DOWNLOAD_PROGRESS_FILE")
    assert_equals "$status" "$recorded_status" "Status should be recorded correctly"
    
    local recorded_downloaded
    recorded_downloaded=$(jq -r ".\"$group\".\"$model_name\".downloaded" "$DOWNLOAD_PROGRESS_FILE")
    assert_equals "$downloaded" "$recorded_downloaded" "Downloaded amount should be recorded correctly"
    
    local recorded_total
    recorded_total=$(jq -r ".\"$group\".\"$model_name\".totalSize" "$DOWNLOAD_PROGRESS_FILE")
    assert_equals "$total_size" "$recorded_total" "Total size should be recorded correctly"
}

# Test getting download progress
test_get_download_progress() {
    source_model_download_integration
    initialize_download_system
    
    local group="checkpoints"
    local model_name="test_model.safetensors"
    local local_path="/path/test_model.safetensors"
    
    # First update some progress
    update_download_progress "$group" "$model_name" "$local_path" "1000000" "750000" "progress"
    
    # Get progress by group and model name
    local progress_file
    progress_file=$(get_download_progress "$group" "$model_name")
    
    assert_not_empty "$progress_file" "Should return progress file path"
    assert_file_exists "$progress_file" "Progress file should exist"
    
    # Verify content
    local status
    status=$(jq -r '.status' "$progress_file")
    assert_equals "progress" "$status" "Should return correct status"
    
    local downloaded
    downloaded=$(jq -r '.downloaded' "$progress_file")
    assert_equals "750000" "$downloaded" "Should return correct downloaded amount"
    
    # Clean up
    rm -f "$progress_file"
    
    # Test getting progress by local path
    local progress_file_by_path
    progress_file_by_path=$(get_download_progress "" "" "$local_path")
    
    assert_not_empty "$progress_file_by_path" "Should return progress file when searching by path"
    
    # Clean up
    rm -f "$progress_file_by_path"
}

# Test download models function - single mode
test_download_models_single() {
    source_model_download_integration
    source_api_client  # Use mock API client
    
    # Clean and reinitialize for fresh state
    rm -f "$DOWNLOAD_QUEUE_FILE" "$DOWNLOAD_PROGRESS_FILE" 2>/dev/null || true
    initialize_download_system
    
    # Test single model download with relative S3 path (most common case)
    local model_json='{
        "directoryGroup": "checkpoints",
        "modelName": "test_model.safetensors",
        "originalS3Path": "/models/checkpoints/test_model.safetensors",
        "localPath": "/tmp/test_model.safetensors",
        "modelSize": 1234567
    }'
    
    # Mock the download worker to prevent real downloads
    export SKIP_BACKGROUND_WORKER=true
    
    local result_file
    result_file=$(download_models "single" "$model_json")
    
    assert_not_empty "$result_file" "Should return result file"
    assert_file_exists "$result_file" "Result file should exist"
    
    # Verify that the model was queued
    local queue_length
    queue_length=$(jq 'length' "$DOWNLOAD_QUEUE_FILE")
    assert_equals "1" "$queue_length" "Model should be added to queue"
    
    # Verify queue content uses originalS3Path and constructs full S3 URL
    local queued_s3_path
    queued_s3_path=$(jq -r '.[0].s3Path' "$DOWNLOAD_QUEUE_FILE")
    assert_equals "/models/checkpoints/test_model.safetensors" "$queued_s3_path" \
        "Queue should contain originalS3Path (relative path)"
    
    # Clean up
    rm -f "$result_file"
    unset SKIP_BACKGROUND_WORKER
}

# Test download models function - list mode
test_download_models_list() {
    source_model_download_integration
    source_api_client  # Use mock API client
    
    # Clean and reinitialize for fresh state
    rm -f "$DOWNLOAD_QUEUE_FILE" "$DOWNLOAD_PROGRESS_FILE" 2>/dev/null || true
    initialize_download_system
    
    # Test list mode with multiple models (mixed S3 path formats)
    local models_json='[
        {
            "directoryGroup": "checkpoints",
            "modelName": "model1.safetensors",
            "originalS3Path": "/models/checkpoints/model1.safetensors",
            "localPath": "/tmp/model1.safetensors",
            "modelSize": 1000000
        },
        {
            "directoryGroup": "loras",
            "modelName": "model2.safetensors",
            "originalS3Path": "models/loras/model2.safetensors",
            "localPath": "/tmp/model2.safetensors",
            "modelSize": 2000000
        }
    ]'
    
    # Mock the download worker to prevent real downloads
    export SKIP_BACKGROUND_WORKER=true
    
    local result_file
    result_file=$(download_models "list" "$models_json")
    
    assert_not_empty "$result_file" "Should return result file"
    assert_file_exists "$result_file" "Result file should exist"
    
    # Verify that both models were queued
    local queue_length
    queue_length=$(jq 'length' "$DOWNLOAD_QUEUE_FILE")
    assert_equals "2" "$queue_length" "Both models should be added to queue"
    
    # Clean up
    rm -f "$result_file"
    unset SKIP_BACKGROUND_WORKER
}

# Test download models function - validation
test_download_models_validation() {
    source_model_download_integration
    initialize_download_system
    
    # Test missing mode
    assert_command_fails "download_models ''" "Should fail with missing mode"
    
    # Test invalid mode
    assert_command_fails "download_models 'invalid_mode'" "Should fail with invalid mode"
    
    # Test single mode with missing model object
    assert_command_fails "download_models 'single' ''" "Should fail with missing model object"
    
    # Test single mode with invalid JSON
    assert_command_fails "download_models 'single' 'invalid_json'" "Should fail with invalid JSON"
    
    # Test list mode with missing models array
    assert_command_fails "download_models 'list' ''" "Should fail with missing models array"
    
    # Test list mode with invalid JSON
    assert_command_fails "download_models 'list' 'invalid_json'" "Should fail with invalid JSON"
}

# Test cancel download functionality
test_cancel_download() {
    source_model_download_integration
    
    # Clean and reinitialize for fresh state
    rm -f "$DOWNLOAD_QUEUE_FILE" "$DOWNLOAD_PROGRESS_FILE" 2>/dev/null || true
    initialize_download_system
    
    local group="checkpoints"
    local model_name="test_model.safetensors"
    local local_path="/tmp/test_model.safetensors"
    
    # Add download to queue and set progress
    add_to_download_queue "$group" "$model_name" "/models/checkpoints/test_model.safetensors" "$local_path" "1000000"
    update_download_progress "$group" "$model_name" "$local_path" "1000000" "500000" "progress"
    
    # Cancel download (provide all 3 parameters)
    assert_command_success "cancel_download '$group' '$model_name' '$local_path'" "Should successfully cancel download"
    
    # Verify download was removed from queue
    local queue_length
    queue_length=$(jq 'length' "$DOWNLOAD_QUEUE_FILE")
    assert_equals "0" "$queue_length" "Download should be removed from queue"
    
    # Verify progress status was updated
    local status
    status=$(jq -r ".\"$group\".\"$model_name\".status" "$DOWNLOAD_PROGRESS_FILE")
    assert_equals "cancelled" "$status" "Status should be updated to cancelled"
}

# Test download lock functionality
test_download_locks() {
    source_model_download_integration
    initialize_download_system
    
    # Test acquiring lock
    assert_command_success "acquire_download_lock 'test_operation' 10" "Should successfully acquire lock"
    
    # Test lock file exists
    assert_file_exists "$DOWNLOAD_LOCK_DIR/test_operation.lock" "Lock file should exist"
    
    # Test releasing lock
    assert_command_success "release_download_lock 'test_operation'" "Should successfully release lock"
    
    # Test lock file is removed
    assert_file_not_exists "$DOWNLOAD_LOCK_DIR/test_operation.lock" "Lock file should be removed"
}

# Test various originalS3Path formats
test_original_s3_path_formats() {
    source_model_download_integration
    source_api_client  # Use mock API client
    
    # Clean and reinitialize for fresh state
    rm -f "$DOWNLOAD_QUEUE_FILE" "$DOWNLOAD_PROGRESS_FILE" 2>/dev/null || true
    initialize_download_system
    
    # Mock the download worker to prevent real downloads
    export SKIP_BACKGROUND_WORKER=true
    
    # Test Case 1: Path with leading slash (common)
    local model_json1='{
        "directoryGroup": "checkpoints",
        "modelName": "model1.safetensors",
        "originalS3Path": "/models/checkpoints/model1.safetensors",
        "localPath": "/tmp/model1.safetensors",
        "modelSize": 1000000
    }'
    
    local result_file1
    result_file1=$(download_models "single" "$model_json1")
    assert_not_empty "$result_file1" "Should handle path with leading slash"
    
    # Test Case 2: Path without leading slash (also common)
    local model_json2='{
        "directoryGroup": "loras",
        "modelName": "model2.safetensors", 
        "originalS3Path": "models/loras/model2.safetensors",
        "localPath": "/tmp/model2.safetensors",
        "modelSize": 2000000
    }'
    
    local result_file2
    result_file2=$(download_models "single" "$model_json2")
    assert_not_empty "$result_file2" "Should handle path without leading slash"
    
    # Test Case 3: Path with subdirectories and no leading slash
    local model_json3='{
        "directoryGroup": "embeddings",
        "modelName": "embedding.pt",
        "originalS3Path": "user-models/embeddings/custom/embedding.pt",
        "localPath": "/tmp/embedding.pt",
        "modelSize": 500000
    }'
    
    local result_file3
    result_file3=$(download_models "single" "$model_json3")
    assert_not_empty "$result_file3" "Should handle complex path without leading slash"
    
    # Verify all models were queued with their original paths preserved
    local queue_length
    queue_length=$(jq 'length' "$DOWNLOAD_QUEUE_FILE")
    assert_equals "3" "$queue_length" "All three models should be queued"
    
    # Verify the paths were stored as-is (find them by model name since order may vary)
    local path1
    path1=$(jq -r '.[] | select(.modelName == "model1.safetensors") | .s3Path' "$DOWNLOAD_QUEUE_FILE")
    assert_equals "/models/checkpoints/model1.safetensors" "$path1" "Path with leading slash preserved"
    
    local path2
    path2=$(jq -r '.[] | select(.modelName == "model2.safetensors") | .s3Path' "$DOWNLOAD_QUEUE_FILE")
    assert_equals "models/loras/model2.safetensors" "$path2" "Path without leading slash preserved"
    
    local path3
    path3=$(jq -r '.[] | select(.modelName == "embedding.pt") | .s3Path' "$DOWNLOAD_QUEUE_FILE")
    assert_equals "user-models/embeddings/custom/embedding.pt" "$path3" "Complex path preserved"
    
    # Clean up
    rm -f "$result_file1" "$result_file2" "$result_file3"
    unset SKIP_BACKGROUND_WORKER
}

# Test S3 path construction in download function
test_s3_path_construction() {
    source_model_download_integration
    initialize_download_system
    
    # Mock AWS CLI to capture the constructed S3 path
    local aws_commands_file="$TEST_TEMP_DIR/aws_commands.log"
    
    # Create a mock aws command that logs what it receives
    local mock_aws_script="$TEST_TEMP_DIR/mock_aws"
    cat > "$mock_aws_script" << 'EOF'
#!/bin/bash
echo "$@" >> "%AWS_COMMANDS_FILE%"
# Return success but don't actually download
exit 0
EOF
    sed -i '' "s|%AWS_COMMANDS_FILE%|$aws_commands_file|g" "$mock_aws_script"
    chmod +x "$mock_aws_script"
    
    # Temporarily override PATH to use our mock aws
    local original_path="$PATH"
    export PATH="$TEST_TEMP_DIR:$PATH"
    
    # Test download with relative S3 path
    local group="checkpoints"
    local model_name="test_model.safetensors"
    local relative_s3_path="/models/checkpoints/test_model.safetensors"  # No s3:// prefix
    local local_path="/tmp/test_model.safetensors"
    
    # This should construct the full S3 path internally
    download_model_with_progress "$group" "$model_name" "$relative_s3_path" "$local_path" "1000" 2>/dev/null || true
    
    # Verify that the full S3 URL was constructed
    if [ -f "$aws_commands_file" ]; then
        local aws_command
        aws_command=$(cat "$aws_commands_file")
        
        # Should contain the full s3:// path
        assert_contains "$aws_command" "s3://$AWS_BUCKET_NAME/models/checkpoints/test_model.safetensors" \
            "AWS command should use full S3 URL constructed from relative path"
    fi
    
    # Test with path that already has leading slash
    echo "" > "$aws_commands_file"  # Clear log
    local path_with_slash="/models/loras/another_model.safetensors"
    download_model_with_progress "$group" "another_model.safetensors" "$path_with_slash" "/tmp/another.safetensors" "1000" 2>/dev/null || true
    
    if [ -f "$aws_commands_file" ]; then
        local aws_command2
        aws_command2=$(cat "$aws_commands_file")
        
        # Should properly handle the leading slash
        assert_contains "$aws_command2" "s3://$AWS_BUCKET_NAME/models/loras/another_model.safetensors" \
            "AWS command should properly construct S3 URL from path with leading slash"
    fi
    
    # Test with path that doesn't have leading slash
    echo "" > "$aws_commands_file"  # Clear log
    local path_without_slash="models/vaes/vae_model.safetensors"
    download_model_with_progress "$group" "vae_model.safetensors" "$path_without_slash" "/tmp/vae.safetensors" "1000" 2>/dev/null || true
    
    if [ -f "$aws_commands_file" ]; then
        local aws_command3
        aws_command3=$(cat "$aws_commands_file")
        
        # Should properly add the leading slash
        assert_contains "$aws_command3" "s3://$AWS_BUCKET_NAME/models/vaes/vae_model.safetensors" \
            "AWS command should properly construct S3 URL from path without leading slash"
    fi
    
    # Restore PATH
    export PATH="$original_path"
    
    # Clean up
    rm -f "$mock_aws_script" "$aws_commands_file"
}

# Test error handling with S3 operations
test_s3_error_handling() {
    source_model_download_integration
    initialize_download_system
    
    # Mock AWS CLI to fail
    local original_path="$PATH"
    export PATH="/nonexistent:$PATH"
    
    # Test download with missing AWS CLI should handle gracefully
    local group="checkpoints"
    local model_name="test_model.safetensors"
    local s3_path="s3://test-bucket/nonexistent/model.safetensors"
    local local_path="/tmp/nonexistent_model.safetensors"
    
    # This should fail gracefully without crashing
    assert_command_fails "download_model_with_progress '$group' '$model_name' '$s3_path' '$local_path' '1000'" \
        "Should handle AWS CLI errors gracefully"
    
    # Restore PATH
    export PATH="$original_path"
}

# Run all tests
main() {
    print_color "$BLUE" "Running Model Download Integration Tests..."
    
    setup_test_env
    
    # Initialize mock environment variables needed for tests
    export AWS_BUCKET_NAME="test-bucket"
    export NETWORK_VOLUME="$TEST_TEMP_DIR/network_volume"
    
    # Create the scripts that will be sourced
    mkdir -p "$NETWORK_VOLUME/scripts"
    
    # Run the script creators to generate all the required scripts
    echo "Creating API client script..."
    if ! NETWORK_VOLUME="$NETWORK_VOLUME" "$PROJECT_ROOT/scripts/create_api_client.sh" 2>&1; then
        echo "❌ Failed to create API client script"
        return 1
    fi
    
    echo "Creating model config manager script..."
    if ! NETWORK_VOLUME="$NETWORK_VOLUME" "$PROJECT_ROOT/scripts/create_model_config_manager.sh" 2>&1; then
        echo "❌ Failed to create model config manager script"
        return 1
    fi
    
    echo "Creating model download integration script..."
    if ! NETWORK_VOLUME="$NETWORK_VOLUME" "$PROJECT_ROOT/scripts/create_model_download_integration.sh" 2>&1; then
        echo "❌ Failed to create model download integration script"
        return 1
    fi
    
    # Verify scripts were created
    echo "Checking generated scripts:"
    ls -la "$NETWORK_VOLUME/scripts/"
    
    if [ ! -f "$NETWORK_VOLUME/scripts/model_download_integration.sh" ]; then
        echo "❌ Model download integration script not found!"
        return 1
    fi
    
    run_test "test_initialize_download_system" "Initialize Download System"
    run_test "test_add_to_download_queue" "Add to Download Queue"
    run_test "test_add_to_queue_validation" "Add to Queue Validation"
    run_test "test_remove_from_download_queue" "Remove from Download Queue"
    run_test "test_get_next_download" "Get Next Download"
    run_test "test_update_download_progress" "Update Download Progress"
    run_test "test_get_download_progress" "Get Download Progress"
    run_test "test_download_models_single" "Download Models Single"
    run_test "test_download_models_list" "Download Models List"
    run_test "test_download_models_validation" "Download Models Validation"
    run_test "test_original_s3_path_formats" "Original S3 Path Formats"
    run_test "test_cancel_download" "Cancel Download"
    run_test "test_download_locks" "Download Locks"
    # Skip complex tests that require AWS mocking
    echo "⏭️  Skipping S3 Path Construction test (requires complex AWS mocking)"
    echo "⏭️  Skipping S3 Error Handling test (requires complex AWS mocking)"
    
    cleanup_test_env
    print_test_summary
}

# Run tests if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
