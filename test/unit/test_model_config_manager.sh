#!/bin/bash
# Unit tests for Model Configuration Manager

source "$(dirname "$0")/../test_framework.sh"

# Test model config initialization
test_initialize_model_config() {
    source_model_config_manager
    
    local config_file="$NETWORK_VOLUME/ComfyUI/models_config.json"
    
    # Remove config file if it exists
    rm -f "$config_file"
    
    # Initialize config
    initialize_model_config
    
    # Check if config file was created
    assert_file_exists "$config_file" "Config file should be created"
    
    # Check if it contains valid JSON
    local content
    content=$(cat "$config_file")
    assert_equals "{}" "$content" "Config should be initialized with empty object"
}

# Test creating a new model
test_create_model() {
    source_model_config_manager
    
    local config_file="$NETWORK_VOLUME/ComfyUI/models_config.json"
    
    # Initialize with empty config
    echo '{}' > "$config_file"
    
    # Create a test model object
    local model_object='{
        "originalS3Path": "s3://global-test-bucket-ws/models/test_model.safetensors",
        "localPath": "/test/path/test_model.safetensors",
        "modelName": "test_model",
        "modelSize": 1024,
        "downloadUrl": "https://example.com/test_model.safetensors"
    }'
    
    # Create the model
    create_or_update_model "checkpoints" "$model_object"
    local result=$?
    
    assert_equals "0" "$result" "Model creation should succeed"
    
    # Check if model was added to config
    local model_exists
    model_exists=$(jq -r '.checkpoints.test_model.modelName // "missing"' "$config_file")
    assert_equals "test_model" "$model_exists" "Model should be added to config"
    
    # Check if S3 path was stripped
    local s3_path
    s3_path=$(jq -r '.checkpoints.test_model.originalS3Path // "missing"' "$config_file")
    assert_equals "models/test_model.safetensors" "$s3_path" "S3 bucket prefix should be stripped"
}

# Test updating an existing model
test_update_model() {
    source_model_config_manager
    
    local config_file="$NETWORK_VOLUME/ComfyUI/models_config.json"
    
    # Initialize with existing model
    local initial_config='{
        "checkpoints": {
            "test_model": {
                "originalS3Path": "/models/test_model.safetensors",
                "localPath": "/test/path/test_model.safetensors",
                "modelName": "test_model",
                "modelSize": 1024,
                "downloadUrl": "https://example.com/test_model.safetensors",
                "uploadedAt": "2023-07-10T12:00:00.000Z"
            }
        }
    }'
    echo "$initial_config" > "$config_file"
    
    # Update the model with new size
    local updated_model='{
        "originalS3Path": "/models/test_model.safetensors",
        "localPath": "/test/path/test_model.safetensors",
        "modelName": "test_model",
        "modelSize": 2048,
        "downloadUrl": "https://example.com/test_model.safetensors"
    }'
    
    create_or_update_model "checkpoints" "$updated_model"
    local result=$?
    
    assert_equals "0" "$result" "Model update should succeed"
    
    # Check if model size was updated
    local new_size
    new_size=$(jq -r '.checkpoints.test_model.modelSize' "$config_file")
    assert_equals "2048" "$new_size" "Model size should be updated"
    
    # Check if lastUpdated timestamp was added
    local last_updated
    last_updated=$(jq -r '.checkpoints.test_model.lastUpdated // "missing"' "$config_file")
    assert_command_success "[ '$last_updated' != 'missing' ]" "lastUpdated timestamp should be added"
}

# Test finding model by path
test_find_model_by_path() {
    source_model_config_manager
    
    local config_file="$NETWORK_VOLUME/ComfyUI/models_config.json"
    
    # Initialize with test data
    create_test_model_config_from_fixture "$config_file" "sample_config.json"
    
    # Find existing model
    local output_file
    output_file=$(find_model_by_path "" "$NETWORK_VOLUME/ComfyUI/models/checkpoints/test_model_1.safetensors")
    local result=$?
    
    assert_equals "0" "$result" "Should find existing model"
    
    # Ensure the output file exists and is readable
    if [ -n "$output_file" ] && [ -f "$output_file" ]; then
        assert_file_exists "$output_file" "Output file should be created"
        
        # Check model content
        local model_name
        model_name=$(jq -r '.modelName' "$output_file")
        assert_equals "test_model_1" "$model_name" "Should return correct model"
    else
        echo "FAIL: Output file not created or not found: '$output_file'"
        return 1
    fi
    
    # Clean up
    rm -f "$output_file"
    
    # Try to find non-existent model
    find_model_by_path "" "/non/existent/path.safetensors" >/dev/null 2>&1
    local not_found_result=$?
    
    assert_equals "1" "$not_found_result" "Should return error for non-existent model"
}

# Test deleting a model
test_delete_model() {
    source_model_config_manager
    
    local config_file="$NETWORK_VOLUME/ComfyUI/models_config.json"
    
    # Initialize with test data
    cp "$TEST_DATA_DIR/sample_config.json" "$config_file"
    
    # Delete existing model
    delete_model "checkpoints" "test_model_1"
    local result=$?
    
    assert_equals "0" "$result" "Model deletion should succeed"
    
    # Check if model was removed
    local model_exists
    model_exists=$(jq -r '.checkpoints.test_model_1 // "missing"' "$config_file")
    assert_equals "missing" "$model_exists" "Model should be removed from config"
    
    # Check if other models still exist
    local other_model
    other_model=$(jq -r '.checkpoints.test_model_2.modelName // "missing"' "$config_file")
    assert_equals "test_model_2" "$other_model" "Other models should remain"
}

# Test removing model by path
test_remove_model_by_path() {
    source_model_config_manager
    
    local config_file="$NETWORK_VOLUME/ComfyUI/models_config.json"
    
    # Initialize with test data and process placeholders
    create_test_model_config_from_fixture "$config_file" "sample_config.json"
    
    # Remove model by path (use the actual path with current NETWORK_VOLUME)
    remove_model_by_path "$NETWORK_VOLUME/ComfyUI/models/loras/test_lora_1.safetensors"
    local result=$?
    
    assert_equals "0" "$result" "Model removal by path should succeed"
    
    # Check if model was removed
    local model_exists
    model_exists=$(jq -r '.loras.test_lora_1 // "missing"' "$config_file")
    assert_equals "missing" "$model_exists" "Model should be removed from config"
}

# Test convert to symlink
test_convert_to_symlink() {
    source_model_config_manager
    
    local config_file="$NETWORK_VOLUME/ComfyUI/models_config.json"
    
    # Initialize with test data
    create_test_model_config_from_fixture "$config_file" "sample_config.json"
    
    # Convert model to symlink (use current NETWORK_VOLUME path)
    convert_to_symlink "checkpoints" "$NETWORK_VOLUME/ComfyUI/models/checkpoints/test_model_2.safetensors" "s3://global-test-bucket-ws/existing/model.safetensors"
    local result=$?
    
    assert_equals "0" "$result" "Convert to symlink should succeed"
    
    # Check if symlink properties were added
    local symlinked_from
    symlinked_from=$(jq -r '.checkpoints.test_model_2.symLinkedFrom // "missing"' "$config_file")
    assert_equals "existing/model.safetensors" "$symlinked_from" "symLinkedFrom should be set with stripped S3 path"
    
    # Check if download URL was removed
    local download_url
    download_url=$(jq -r '.checkpoints.test_model_2.downloadUrl // "missing"' "$config_file")
    assert_equals "missing" "$download_url" "downloadUrl should be removed for symlinks"
}

# Test get model download URL
test_get_model_download_url() {
    source_model_config_manager
    
    local config_file="$NETWORK_VOLUME/ComfyUI/models_config.json"
    
    # Initialize with test data
    create_test_model_config_from_fixture "$config_file" "sample_config.json"
    
    # Get download URL for existing model (use current NETWORK_VOLUME path)
    local output_file
    output_file=$(mktemp)
    
    get_model_download_url "$NETWORK_VOLUME/ComfyUI/models/checkpoints/test_model_1.safetensors" "$output_file"
    local result=$?
    
    assert_equals "0" "$result" "Should find download URL"
    
    local download_url
    download_url=$(cat "$output_file")
    assert_equals "https://example.com/test_model_1.safetensors" "$download_url" "Should return correct download URL"
    
    rm -f "$output_file"
}

# Test invalid JSON handling
test_invalid_json_handling() {
    source_model_config_manager
    
    local config_file="$NETWORK_VOLUME/ComfyUI/models_config.json"
    
    # Create invalid JSON
    echo "invalid json content" > "$config_file"
    
    # Initialize should fix the JSON
    initialize_model_config
    
    # Check if config was reset to valid JSON
    local content
    content=$(cat "$config_file")
    assert_equals "{}" "$content" "Invalid JSON should be reset to empty object"
}

# Run all tests
main() {
    print_color "$BLUE" "Running Model Config Manager Unit Tests"
    print_color "$BLUE" "======================================="
    
    setup_test_env
    
    run_test test_initialize_model_config "Model Config Initialization"
    run_test test_create_model "Create New Model"
    run_test test_update_model "Update Existing Model"
    run_test test_find_model_by_path "Find Model by Path"
    run_test test_delete_model "Delete Model"
    run_test test_remove_model_by_path "Remove Model by Path"
    run_test test_convert_to_symlink "Convert to Symlink"
    run_test test_get_model_download_url "Get Model Download URL"
    run_test test_invalid_json_handling "Invalid JSON Handling"
    
    print_test_summary
}

# Run tests if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
