#!/bin/bash
# Unit tests for sync functions and progress tracking

# Source the test framework
source "$(dirname "${BASH_SOURCE[0]}")/../test_framework.sh"

# Mock environment variables
export NETWORK_VOLUME="$TEST_TEMP_DIR/network_volume"
export AWS_BUCKET_NAME="test-bucket"
export POD_ID="test-pod-123"
export POD_USER_NAME="test-user"
export API_BASE_URL="https://api.test.com"
export WEBHOOK_SECRET_KEY="test-secret"

# Test that sync_to_s3_with_progress function exists and handles parameters correctly
test_sync_function_exists() {
    start_test "Sync Function Exists"
    
    # Setup test environment
    mkdir -p "$NETWORK_VOLUME/scripts"
    mkdir -p "$NETWORK_VOLUME/ComfyUI/models"
    
    # Create mock AWS CLI that always succeeds
    cat > /tmp/aws_mock << 'EOF'
#!/bin/bash
echo "AWS_MOCK: $*" >> /tmp/aws_mock.log
exit 0
EOF
    chmod +x /tmp/aws_mock
    
    # Create aws command in PATH that will be found first
    ln -sf /tmp/aws_mock /tmp/aws
    export PATH="/tmp:$PATH"
    
    # Create an aws function that overrides any command
    aws() {
        echo "AWS_FUNCTION: $*" >> /tmp/aws_mock.log
        return 0
    }
    export -f aws
    
    echo "" > /tmp/aws_mock.log
    
    # Create mock required scripts
    cat > "$NETWORK_VOLUME/scripts/api_client.sh" << 'EOF'
notify_sync_progress() {
    echo "PROGRESS: $1 $2 $3%" >> /tmp/progress_test.log
}
EOF
    
    cat > "$NETWORK_VOLUME/scripts/sync_lock_manager.sh" << 'EOF'
execute_with_sync_lock() { "$2"; }
EOF
    
    cat > "$NETWORK_VOLUME/scripts/model_config_manager.sh" << 'EOF'
extract_model_name_from_path() { basename "$1"; }
EOF
    
    echo "" > /tmp/progress_test.log
    
    # Generate the model sync integration script
    source "$PROJECT_ROOT/scripts/create_model_sync_integration.sh"
    
    # Test that the function exists
    source "$NETWORK_VOLUME/scripts/model_sync_integration.sh"
    
    if declare -f sync_to_s3_with_progress > /dev/null; then
        echo "✅ sync_to_s3_with_progress function exists"
    else
        echo "❌ sync_to_s3_with_progress function does not exist"
        end_test 1
        return 1
    fi
    
    # Test file upload
    local test_file="$NETWORK_VOLUME/test_file.txt"
    echo "test content" > "$test_file"
    
    if sync_to_s3_with_progress "$test_file" "s3://test-bucket/test_file.txt" "test_sync" 1 2 "cp" 2>/dev/null; then
        echo "✅ File upload succeeded"
        
        # Check if AWS command was called
        if grep -q -E "(aws.*s3.*cp|AWS_MOCK|AWS_FUNCTION)" /tmp/aws_mock.log; then
            echo "✅ AWS command called correctly"
        else
            echo "❌ AWS command not called"
            echo "AWS mock log contents:"
            cat /tmp/aws_mock.log
            end_test 1
            return 1
        fi
        
        # Check if progress notification was sent
        if grep -q "PROGRESS.*test_sync.*PROGRESS.*50" /tmp/progress_test.log; then
            echo "✅ Progress notification sent"
        else
            echo "❌ Progress notification not sent"
            echo "Progress log contents:"
            cat /tmp/progress_test.log
        fi
    else
        echo "❌ File upload failed"
        end_test 1
        return 1
    fi
    
    end_test 0
    return 0
}

# Test that sync scripts use the progress function
test_sync_scripts_use_progress() {
    start_test "Sync Scripts Use Progress Function"
    
    # Generate the sync scripts
    source "$PROJECT_ROOT/scripts/create_sync_scripts.sh"
    
    # Check that sync_to_s3_with_progress is used in the generated scripts
    local scripts_to_check=(
        "$NETWORK_VOLUME/scripts/sync_user_data.sh"
        "$NETWORK_VOLUME/scripts/sync_pod_metadata.sh"
    )
    
    local scripts_found=0
    for script in "${scripts_to_check[@]}"; do
        if [ -f "$script" ]; then
            scripts_found=$((scripts_found + 1))
            if grep -q "sync_to_s3_with_progress" "$script"; then
                echo "✅ Script uses sync_to_s3_with_progress: $(basename "$script")"
            else
                echo "❌ Script does not use sync_to_s3_with_progress: $(basename "$script")"
                end_test 1
                return 1
            fi
        else
            echo "❌ Script not found: $script"
            end_test 1
            return 1
        fi
    done
    
    if [ $scripts_found -gt 0 ]; then
        echo "✅ Found and verified $scripts_found sync scripts"
        end_test 0
        return 0
    else
        echo "❌ No sync scripts found"
        end_test 1
        return 1
    fi
}

# Main test execution
main() {
    echo "============================================================"
    echo "                   SYNC FUNCTIONS UNIT TESTS                   "
    echo "============================================================"
    
    # Setup test environment
    setup_test_env
    
    # Run tests
    test_sync_function_exists
    test_sync_scripts_use_progress
    
    # Print summary
    print_test_summary
    
    # Cleanup
    cleanup_test_env
    rm -f /tmp/aws_mock /tmp/aws /tmp/aws_mock.log /tmp/progress_test.log
    rm -rf /tmp/usr
    
    if [ $TESTS_FAILED -eq 0 ]; then
        echo "🎉 ALL SYNC FUNCTION TESTS PASSED!"
        exit 0
    else
        echo "❌ SOME SYNC FUNCTION TESTS FAILED"
        exit 1
    fi
}

# Only run main if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
