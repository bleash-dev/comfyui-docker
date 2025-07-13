#!/bin/bash
# Integration tests for sync scripts and complete workflows

# Source the test framework
source "$(dirname "${BASH_SOURCE[0]}")/../test_framework.sh"

# Mock environment variables
export NETWORK_VOLUME="$TEST_TEMP_DIR/network_volume"
export AWS_BUCKET_NAME="test-sync-bucket"
export POD_ID="test-sync-pod-456"
export POD_USER_NAME="test-sync-user"
export API_BASE_URL="https://api.sync.test.com"
export WEBHOOK_SECRET_KEY="test-sync-secret"

# Test that sync scripts are generated correctly
test_sync_scripts_generation() {
    start_test "Sync Scripts Generation"
    
    # Setup test environment with directories and files
    mkdir -p "$NETWORK_VOLUME/scripts"
    mkdir -p "$NETWORK_VOLUME/ComfyUI/models"
    mkdir -p "$NETWORK_VOLUME/ComfyUI/input"
    mkdir -p "$NETWORK_VOLUME/ComfyUI/output"
    mkdir -p "$NETWORK_VOLUME/ComfyUI/user/default/workflows"
    mkdir -p "$NETWORK_VOLUME/.sync_locks"
    
    # Create test files
    echo '{"version": "1.0"}' > "$NETWORK_VOLUME/ComfyUI/models_config.json"
    echo '{"workflow": "test"}' > "$NETWORK_VOLUME/ComfyUI/user/default/workflows/test.json"
    echo "input data" > "$NETWORK_VOLUME/ComfyUI/input/test.png"
    echo "output data" > "$NETWORK_VOLUME/ComfyUI/output/result.png"
    
    # Generate scripts
    source "$PROJECT_ROOT/scripts/create_sync_scripts.sh"
    source "$PROJECT_ROOT/scripts/create_model_sync_integration.sh"
    
    # Check that main sync scripts were created
    local expected_scripts=(
        "$NETWORK_VOLUME/scripts/sync_user_data.sh"
        "$NETWORK_VOLUME/scripts/sync_pod_metadata.sh"
        "$NETWORK_VOLUME/scripts/sync_comfyui_assets.sh"
    )
    
    local scripts_found=0
    for script in "${expected_scripts[@]}"; do
        if [ -f "$script" ] && [ -x "$script" ]; then
            scripts_found=$((scripts_found + 1))
            echo "✅ Found script: $(basename "$script")"
        else
            echo "❌ Missing or non-executable script: $script"
            end_test 1
            return 1
        fi
    done
    
    # Check that scripts use sync_to_s3_with_progress
    local progress_scripts=0
    for script in "${expected_scripts[@]}"; do
        if grep -q "sync_to_s3_with_progress" "$script"; then
            progress_scripts=$((progress_scripts + 1))
            echo "✅ Script uses progress function: $(basename "$script")"
        fi
    done
    
    if [ $progress_scripts -gt 0 ]; then
        echo "✅ $progress_scripts scripts use progress tracking"
    else
        echo "❌ No scripts use progress tracking"
        end_test 1
        return 1
    fi
    
    # Check that model sync integration exists
    if [ -f "$NETWORK_VOLUME/scripts/model_sync_integration.sh" ]; then
        echo "✅ Model sync integration script created"
        
        # Check for sync_to_s3_with_progress function
        if grep -q "sync_to_s3_with_progress()" "$NETWORK_VOLUME/scripts/model_sync_integration.sh"; then
            echo "✅ sync_to_s3_with_progress function found"
        else
            echo "❌ sync_to_s3_with_progress function not found"
            end_test 1
            return 1
        fi
    else
        echo "❌ Model sync integration script not created"
        end_test 1
        return 1
    fi
    
    echo "✅ Found $scripts_found sync scripts with proper progress tracking"
    end_test 0
    return 0
}

# Test sync_to_s3_with_progress function directly
test_sync_to_s3_with_progress_function() {
    start_test "sync_to_s3_with_progress Function"
    
    # Generate the model sync integration script
    source "$PROJECT_ROOT/scripts/create_model_sync_integration.sh"
    source "$PROJECT_ROOT/scripts/create_api_client.sh"
    
    # Mock AWS CLI for this specific test
    cat > /tmp/aws_function_mock << 'EOF'
#!/bin/bash
echo "AWS_FUNCTION_MOCK: $*" >> /tmp/aws_function_mock.log
exit 0
EOF
    chmod +x /tmp/aws_function_mock
    
    ORIGINAL_PATH="$PATH"
    export PATH="/tmp:$PATH"
    ln -sf /tmp/aws_function_mock /tmp/aws
    echo "" > /tmp/aws_function_mock.log
    
    # Source the model sync integration to get the function
    source "$NETWORK_VOLUME/scripts/model_sync_integration.sh"
    
    # Test file upload
    echo "test file content" > /tmp/test_sync_file.txt
    if sync_to_s3_with_progress "/tmp/test_sync_file.txt" "s3://test-bucket/test-file.txt" "test_sync" 1 2 "cp"; then
        echo "✅ File upload with sync_to_s3_with_progress succeeded"
        
        if grep -q "s3.*cp.*test_sync_file.txt" /tmp/aws_function_mock.log; then
            echo "✅ Correct AWS S3 cp command was called"
        else
            echo "❌ Expected AWS S3 cp command not found"
        fi
    else
        echo "❌ File upload with sync_to_s3_with_progress failed"
        end_test 1
        return 1
    fi
    
    # Test directory sync
    mkdir -p /tmp/test_sync_dir
    echo "dir file 1" > /tmp/test_sync_dir/file1.txt
    echo "dir file 2" > /tmp/test_sync_dir/file2.txt
    
    if sync_to_s3_with_progress "/tmp/test_sync_dir" "s3://test-bucket/test-dir/" "test_sync" 2 2 "sync"; then
        echo "✅ Directory sync with sync_to_s3_with_progress succeeded"
        
        if grep -q "s3.*sync.*test_sync_dir" /tmp/aws_function_mock.log; then
            echo "✅ Correct AWS S3 sync command was called"
        else
            echo "❌ Expected AWS S3 sync command not found"
        fi
    else
        echo "❌ Directory sync with sync_to_s3_with_progress failed"
        end_test 1
        return 1
    fi
    
    # Cleanup
    export PATH="$ORIGINAL_PATH"
    rm -f /tmp/aws_function_mock /tmp/aws /tmp/aws_function_mock.log
    rm -f /tmp/test_sync_file.txt
    rm -rf /tmp/test_sync_dir
    
    end_test 0
    return 0
}

# Test complete sync workflow with mocked AWS but real scripts
test_sync_workflow_with_real_scripts() {
    start_test "Sync Workflow with Real Scripts"
    
    # Generate the real scripts first
    source "$PROJECT_ROOT/scripts/create_sync_scripts.sh"
    source "$PROJECT_ROOT/scripts/create_api_client.sh"
    source "$PROJECT_ROOT/scripts/create_sync_lock_manager.sh"
    source "$PROJECT_ROOT/scripts/create_model_config_manager.sh"
    source "$PROJECT_ROOT/scripts/create_model_sync_integration.sh"
    
    # Only mock AWS CLI to avoid actual S3 calls
    cat > /tmp/aws_real_mock << 'EOF'
#!/bin/bash
echo "AWS_REAL_MOCK: $*" >> /tmp/aws_real_mock.log
# Simulate successful AWS operations
exit 0
EOF
    chmod +x /tmp/aws_real_mock
    
    # Backup original PATH and aws command
    ORIGINAL_PATH="$PATH"
    export PATH="/tmp:$PATH"
    ln -sf /tmp/aws_real_mock /tmp/aws
    echo "" > /tmp/aws_real_mock.log
    
    # Create test data to sync
    echo "test user data" > "$NETWORK_VOLUME/ComfyUI/user_test_file.txt"
    echo '{"version": "1.0", "models": []}' > "$NETWORK_VOLUME/ComfyUI/models_config.json"
    mkdir -p "$NETWORK_VOLUME/ComfyUI/user/default/workflows"
    echo '{"workflow": "test_workflow"}' > "$NETWORK_VOLUME/ComfyUI/user/default/workflows/test.json"
    mkdir -p "$NETWORK_VOLUME/ComfyUI/input" "$NETWORK_VOLUME/ComfyUI/output"
    echo "input_data" > "$NETWORK_VOLUME/ComfyUI/input/test_input.png"
    echo "output_data" > "$NETWORK_VOLUME/ComfyUI/output/test_output.png"
    
    # Test pod metadata sync (uses sync_to_s3_with_progress)
    if [ -x "$NETWORK_VOLUME/scripts/sync_pod_metadata.sh" ]; then
        echo "Testing sync_pod_metadata.sh..."
        if "$NETWORK_VOLUME/scripts/sync_pod_metadata.sh" 2>/dev/null; then
            echo "✅ Pod metadata sync executed successfully"
            
            # Check if AWS commands were called through our function
            if grep -q "s3.*models_config.json" /tmp/aws_real_mock.log || 
               grep -q "s3.*workflows" /tmp/aws_real_mock.log; then
                echo "✅ AWS S3 commands were called for metadata sync"
            else
                echo "⚠️ Expected AWS S3 commands not found in mock log"
            fi
        else
            echo "❌ Pod metadata sync script failed"
            end_test 1
            return 1
        fi
    else
        echo "❌ sync_pod_metadata.sh not found or not executable"
        end_test 1
        return 1
    fi
    
    # Test assets sync (uses sync_directory_with_progress)
    if [ -x "$NETWORK_VOLUME/scripts/sync_comfyui_assets.sh" ]; then
        echo "Testing sync_comfyui_assets.sh..."
        if "$NETWORK_VOLUME/scripts/sync_comfyui_assets.sh" 2>/dev/null; then
            echo "✅ ComfyUI assets sync executed successfully"
            
            # Check if AWS commands were called for assets
            if grep -q "s3.*input\|s3.*output" /tmp/aws_real_mock.log; then
                echo "✅ AWS S3 commands were called for assets sync"
            else
                echo "⚠️ Expected AWS S3 commands for assets not found"
            fi
        else
            echo "❌ ComfyUI assets sync script failed"
            end_test 1
            return 1
        fi
    else
        echo "❌ sync_comfyui_assets.sh not found or not executable"
        end_test 1
        return 1
    fi
    
    # Verify that sync_to_s3_with_progress function is being used
    if grep -q "sync_to_s3_with_progress" "$NETWORK_VOLUME/scripts/sync_pod_metadata.sh"; then
        echo "✅ sync_pod_metadata.sh uses sync_to_s3_with_progress"
    else
        echo "⚠️ sync_pod_metadata.sh doesn't use sync_to_s3_with_progress"
    fi
    
    # Restore original PATH
    export PATH="$ORIGINAL_PATH"
    rm -f /tmp/aws_real_mock /tmp/aws /tmp/aws_real_mock.log
    
    end_test 0
    return 0
}

# Main integration test execution
main() {
    echo "============================================================"
    echo "                   SYNC INTEGRATION TESTS                   "
    echo "============================================================"
    
    # Setup test environment
    setup_test_env
    
    # Run tests
    test_sync_scripts_generation
    test_sync_to_s3_with_progress_function
    test_sync_workflow_with_real_scripts
    
    # Print summary
    print_test_summary
    
    # Cleanup
    cleanup_test_env
    rm -f /tmp/aws_real_mock /tmp/aws /tmp/aws_real_mock.log
    
    if [ $TESTS_FAILED -eq 0 ]; then
        echo "🎉 ALL SYNC INTEGRATION TESTS PASSED!"
        exit 0
    else
        echo "❌ SOME SYNC INTEGRATION TESTS FAILED"
        exit 1
    fi
}

# Only run main if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
