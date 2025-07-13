#!/bin/bash
# Integration tests for Model Management System

source "$(dirname "$0")/../test_framework.sh"

# Test complete model workflow
test_complete_model_workflow() {
    source_model_config_manager
    source_model_sync_integration
    source_api_client
    
    local config_file="$NETWORK_VOLUME/ComfyUI/models_config.json"
    local models_dir="$NETWORK_VOLUME/ComfyUI/models"
    
    # Step 1: Initialize empty config
    echo '{}' > "$config_file"
    
    # Step 2: Create test model files
    create_test_model_file "$models_dir/checkpoints/workflow_model_1.safetensors" 2048
    create_test_model_file "$models_dir/checkpoints/workflow_model_2.safetensors" 1024
    create_test_model_file "$models_dir/loras/workflow_lora_1.safetensors" 512
    
    # Step 3: Add models to config
    local model1='{
        "originalS3Path": "s3://global-test-bucket-ws/models/checkpoints/workflow_model_1.safetensors",
        "localPath": "'$models_dir'/checkpoints/workflow_model_1.safetensors",
        "modelName": "workflow_model_1",
        "modelSize": 2048,
        "downloadUrl": "https://example.com/workflow_model_1.safetensors"
    }'
    
    local model2='{
        "originalS3Path": "s3://global-test-bucket-ws/models/checkpoints/workflow_model_2.safetensors",
        "localPath": "'$models_dir'/checkpoints/workflow_model_2.safetensors",
        "modelName": "workflow_model_2",
        "modelSize": 1024,
        "downloadUrl": "https://example.com/workflow_model_2.safetensors"
    }'
    
    local lora1='{
        "originalS3Path": "s3://global-test-bucket-ws/models/loras/workflow_lora_1.safetensors",
        "localPath": "'$models_dir'/loras/workflow_lora_1.safetensors",
        "modelName": "workflow_lora_1",
        "modelSize": 512,
        "downloadUrl": "https://example.com/workflow_lora_1.safetensors"
    }'
    
    create_or_update_model "checkpoints" "$model1"
    create_or_update_model "checkpoints" "$model2"
    create_or_update_model "loras" "$lora1"
    
    # Step 4: Verify models were added correctly
    local model_count
    model_count=$(jq '[.checkpoints, .loras] | map(length) | add' "$config_file")
    assert_equals "3" "$model_count" "Should have 3 models in config"
    
    # Step 5: Check S3 path stripping
    local s3_path
    s3_path=$(jq -r '.checkpoints.workflow_model_1.originalS3Path' "$config_file")
    assert_equals "models/checkpoints/workflow_model_1.safetensors" "$s3_path" "S3 bucket prefix should be stripped"
    
    # Step 6: Test finding models
    local found_model
    found_model=$(find_model_by_path "" "$models_dir/loras/workflow_lora_1.safetensors")
    assert_command_success "[ -f '$found_model' ]" "Should find lora model"
    rm -f "$found_model"
    
    # Step 7: Test getting download URL
    local url_file
    url_file=$(mktemp)
    get_model_download_url "$models_dir/checkpoints/workflow_model_1.safetensors" "$url_file"
    local url_result=$?
    assert_equals "0" "$url_result" "Should get download URL"
    
    local download_url
    download_url=$(cat "$url_file")
    assert_equals "https://example.com/workflow_model_1.safetensors" "$download_url" "Should return correct URL"
    rm -f "$url_file"
    
    # Step 8: Test batch processing
    batch_process_models "$models_dir" "s3://global-test-bucket-ws/models" "integration_test"
    local batch_result=$?
    assert_equals "0" "$batch_result" "Batch processing should succeed"
    
    # Step 9: Test model deletion
    delete_model "checkpoints" "workflow_model_2"
    local delete_result=$?
    assert_equals "0" "$delete_result" "Model deletion should succeed"
    
    # Check that the specific model was deleted (not total count due to batch processing artifacts)
    local deleted_model
    deleted_model=$(jq -r '.checkpoints.workflow_model_2 // "missing"' "$config_file")
    assert_equals "missing" "$deleted_model" "workflow_model_2 should be deleted from config"
    
    # Step 10: Test symlink conversion
    convert_to_symlink "checkpoints" "$models_dir/checkpoints/workflow_model_1.safetensors" "s3://global-test-bucket-ws/existing/target.safetensors"
    local symlink_result=$?
    assert_equals "0" "$symlink_result" "Symlink conversion should succeed"
    
    local symlinked_from
    symlinked_from=$(jq -r '.checkpoints.workflow_model_1.symLinkedFrom' "$config_file")
    assert_equals "existing/target.safetensors" "$symlinked_from" "Symlink target should be set with stripped path"
    
    local download_url_after_symlink
    download_url_after_symlink=$(jq -r '.checkpoints.workflow_model_1.downloadUrl // "missing"' "$config_file")
    assert_equals "missing" "$download_url_after_symlink" "Download URL should be removed after symlink conversion"
}

# Test cross-group model handling workflow
test_duplicate_handling_workflow() {
    source_model_config_manager
    source_model_sync_integration
    
    local config_file="$NETWORK_VOLUME/ComfyUI/models_config.json"
    local models_dir="$NETWORK_VOLUME/ComfyUI/models"
    
    # Use fixture with models across different groups
    create_test_model_config_from_fixture "$config_file" "config_with_duplicates.json"
    
    # Create test files for models in different groups
    mkdir -p "$models_dir/checkpoints"
    mkdir -p "$models_dir/loras"
    create_test_model_file "$models_dir/checkpoints/duplicate_model_v1.safetensors" 1024
    create_test_model_file "$models_dir/loras/duplicate_model_v2.safetensors" 2048
    # Don't create missing_file.safetensors to test its removal
    
    # Verify we have the expected models initially (1 checkpoint + 1 lora + 1 missing)
    local checkpoint_count
    checkpoint_count=$(jq '.checkpoints | length' "$config_file")
    assert_equals "2" "$checkpoint_count" "Should start with 2 checkpoint models (including missing)"
    
    local lora_count
    lora_count=$(jq '.loras | length' "$config_file")
    assert_equals "1" "$lora_count" "Should start with 1 lora model"
    
    # Run sanitization
    sanitize_model_config
    local sanitize_result=$?
    assert_equals "0" "$sanitize_result" "Sanitization should succeed"
    
    # Check that missing file was removed but valid models remain
    local final_checkpoint_count
    final_checkpoint_count=$(jq '.checkpoints | length' "$config_file")
    assert_equals "1" "$final_checkpoint_count" "Should have 1 checkpoint model (missing file removed)"
    
    local final_lora_count
    final_lora_count=$(jq '.loras | length' "$config_file")
    assert_equals "1" "$final_lora_count" "Should still have 1 lora model"
    
    # Verify the models have different names (no true duplicates within groups)
    local checkpoint_name
    checkpoint_name=$(jq -r '.checkpoints | to_entries[0] | .value.modelName' "$config_file")
    local lora_name
    lora_name=$(jq -r '.loras | to_entries[0] | .value.modelName' "$config_file")
    
    assert_not_equals "$checkpoint_name" "$lora_name" "Models in different groups should have different names"
}

# Test missing file cleanup workflow
test_missing_file_cleanup_workflow() {
    source_model_config_manager
    source_model_sync_integration
    
    local config_file="$NETWORK_VOLUME/ComfyUI/models_config.json"
    local models_dir="$NETWORK_VOLUME/ComfyUI/models"
    
    # Initialize config with models
    echo '{}' > "$config_file"
    
    # Create only some of the model files
    create_test_model_file "$models_dir/checkpoints/existing_model.safetensors" 1024
    # Note: missing_model.safetensors is intentionally not created
    
    # Add both models to config
    local existing_model='{
        "originalS3Path": "/models/checkpoints/existing_model.safetensors",
        "localPath": "'$models_dir'/checkpoints/existing_model.safetensors",
        "modelName": "existing_model",
        "modelSize": 1024,
        "downloadUrl": "https://example.com/existing_model.safetensors"
    }'
    
    local missing_model='{
        "originalS3Path": "/models/checkpoints/missing_model.safetensors",
        "localPath": "'$models_dir'/checkpoints/missing_model.safetensors",
        "modelName": "missing_model",
        "modelSize": 1024,
        "downloadUrl": "https://example.com/missing_model.safetensors"
    }'
    
    create_or_update_model "checkpoints" "$existing_model"
    create_or_update_model "checkpoints" "$missing_model"
    
    # Verify we have 2 models initially
    local initial_count
    initial_count=$(jq '.checkpoints | length' "$config_file")
    assert_equals "2" "$initial_count" "Should start with 2 models"
    
    # Run sanitization
    sanitize_model_config
    local sanitize_result=$?
    assert_equals "0" "$sanitize_result" "Sanitization should succeed"
    
    # Check that only the existing model remains
    local final_count
    final_count=$(jq '.checkpoints | length' "$config_file")
    assert_equals "1" "$final_count" "Should have only 1 model after cleanup"
    
    # Check that the correct model remains
    local remaining_model
    remaining_model=$(jq -r '.checkpoints.existing_model.modelName // "missing"' "$config_file")
    assert_equals "existing_model" "$remaining_model" "Should keep the existing model"
    
    # Check that the missing model was removed
    local missing_model_check
    missing_model_check=$(jq -r '.checkpoints.missing_model // "missing"' "$config_file")
    assert_equals "missing" "$missing_model_check" "Should remove the missing model"
}

# Test error recovery workflow
test_error_recovery_workflow() {
    source_model_config_manager
    source_model_sync_integration
    
    local config_file="$NETWORK_VOLUME/ComfyUI/models_config.json"
    
    # Test recovery from corrupted config
    echo "invalid json content" > "$config_file"
    
    # Initialize should recover
    initialize_model_config
    
    local recovered_content
    recovered_content=$(cat "$config_file")
    assert_equals "{}" "$recovered_content" "Should recover from corrupted config"
    
    # Test handling of models with missing download URLs
    local model_without_url='{
        "originalS3Path": "/models/checkpoints/no_url_model.safetensors",
        "localPath": "/test/path/no_url_model.safetensors",
        "modelName": "no_url_model",
        "modelSize": 1024
    }'
    
    create_or_update_model "checkpoints" "$model_without_url"
    
    # Try to process model without URL (should fail gracefully)
    process_model_for_sync "/test/path/no_url_model.safetensors" "s3://global-test-bucket-ws/models/no_url_model.safetensors" "checkpoints"
    local no_url_result=$?
    assert_equals "1" "$no_url_result" "Should handle missing download URL gracefully"
}

# Run all integration tests
main() {
    print_color "$BLUE" "Running Model Management Integration Tests"
    print_color "$BLUE" "========================================="
    
    setup_test_env
    
    run_test test_complete_model_workflow "Complete Model Workflow"
    run_test test_duplicate_handling_workflow "Duplicate Handling Workflow"
    run_test test_missing_file_cleanup_workflow "Missing File Cleanup Workflow"
    run_test test_error_recovery_workflow "Error Recovery Workflow"
    
    print_test_summary
}

# Run tests if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
