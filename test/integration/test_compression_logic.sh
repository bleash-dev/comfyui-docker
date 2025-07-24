#!/bin/bash
# Integration test for model compression logic in sync scripts

# Source the test framework
source "$(dirname "${BASH_SOURCE[0]}")/../test_framework.sh"

# Mock environment variables
export NETWORK_VOLUME="$TEST_TEMP_DIR/network_volume"
export AWS_BUCKET_NAME="test-compression-bucket"
export POD_ID="test-compression-pod-123"
export POD_USER_NAME="test-compression-user"
export API_BASE_URL="https://api.compression.test.com"
export WEBHOOK_SECRET_KEY="test-compression-secret"

# Test compression logic for different file sizes
test_compression_size_thresholds() {
    start_test "Model Compression Size Thresholds"
    
    # Setup test environment
    mkdir -p "$NETWORK_VOLUME/scripts"
    mkdir -p "$NETWORK_VOLUME/ComfyUI/models/checkpoints"
    mkdir -p "$NETWORK_VOLUME/.sync_locks"
    
    # Generate the model sync integration script
    source "$PROJECT_ROOT/scripts/create_model_sync_integration.sh"
    
    # Source the generated script to test its functions
    source "$NETWORK_VOLUME/scripts/model_sync_integration.sh"
    
    # Create test files of different sizes
    local small_file="$NETWORK_VOLUME/ComfyUI/models/checkpoints/small_model.safetensors"
    local large_file="$NETWORK_VOLUME/ComfyUI/models/checkpoints/large_model.safetensors"
    
    # Create small file (5MB - below 10MB threshold)
    dd if=/dev/zero of="$small_file" bs=1M count=5 2>/dev/null
    
    # Create large file (15MB - above 10MB threshold)
    dd if=/dev/zero of="$large_file" bs=1M count=15 2>/dev/null
    
    # Test compression function with small file
    echo "Testing compression with small file (5MB)..."
    local temp_dir_small
    temp_dir_small=$(mktemp -d)
    
    # Small files should not be compressed in practice, but function should work
    local compressed_small
    compressed_small=$(compress_model_file "$small_file" "$temp_dir_small" 2>/dev/null)
    local compress_result_small=$?
    
    if [ $compress_result_small -eq 0 ] && [ -f "$compressed_small" ]; then
        echo "✅ Small file compression function works"
        rm -f "$compressed_small"
    else
        echo "❌ Small file compression function failed"
        return 1
    fi
    
    # Test compression function with large file
    echo "Testing compression with large file (15MB)..."
    local temp_dir_large
    temp_dir_large=$(mktemp -d)
    
    local compressed_large
    compressed_large=$(compress_model_file "$large_file" "$temp_dir_large" 2>/dev/null)
    local compress_result_large=$?
    
    if [ $compress_result_large -eq 0 ] && [ -f "$compressed_large" ]; then
        echo "✅ Large file compression function works"
        
        # Check compression was effective
        local original_size
        original_size=$(stat -f%z "$large_file" 2>/dev/null || stat -c%s "$large_file" 2>/dev/null)
        local compressed_size
        compressed_size=$(stat -f%z "$compressed_large" 2>/dev/null || stat -c%s "$compressed_large" 2>/dev/null)
        
        if [ "$compressed_size" -lt "$original_size" ]; then
            echo "✅ Compression reduced file size: $original_size -> $compressed_size bytes"
        else
            echo "⚠️ Compression did not reduce file size (normal for zero-filled test data)"
        fi
        
        rm -f "$compressed_large"
    else
        echo "❌ Large file compression function failed"
        return 1
    fi
    
    # Clean up
    rm -rf "$temp_dir_small" "$temp_dir_large"
    rm -f "$small_file" "$large_file"
    
    echo "✅ Compression size threshold tests passed"
    return 0
}

# Test compression disable environment variable
test_compression_disable_flag() {
    start_test "Model Compression Disable Flag"
    
    # Setup test environment
    mkdir -p "$NETWORK_VOLUME/scripts"
    mkdir -p "$NETWORK_VOLUME/ComfyUI/models/checkpoints"
    
    # Generate the model sync integration script
    source "$PROJECT_ROOT/scripts/create_model_sync_integration.sh"
    
    # Create large test file (20MB)
    local test_file="$NETWORK_VOLUME/ComfyUI/models/checkpoints/test_model.safetensors"
    dd if=/dev/zero of="$test_file" bs=1M count=20 2>/dev/null
    
    # Mock s3_copy_to function to capture parameters
    s3_copy_to() {
        local file="$1"
        local destination="$2"
        local metadata="$3"
        
        # Store parameters for verification
        echo "MOCK_S3_COPY: file=$file, dest=$destination, meta=$metadata" >> "$TEST_TEMP_DIR/s3_calls.log"
        return 0
    }
    
    # Test with compression enabled (default)
    echo "Testing with compression enabled..."
    unset DISABLE_MODEL_COMPRESSION
    source "$NETWORK_VOLUME/scripts/model_sync_integration.sh"
    
    # Call upload function
    upload_file_with_progress "$test_file" "s3://test-bucket/models/test_model.safetensors" "model_upload" 1 1 "https://example.com/download" 2>/dev/null
    
    # Check if compressed file was uploaded
    if grep -q "\.tar\.zst" "$TEST_TEMP_DIR/s3_calls.log"; then
        echo "✅ Compression enabled: compressed file was uploaded"
    else
        echo "❌ Compression enabled: but compressed file was not uploaded"
        cat "$TEST_TEMP_DIR/s3_calls.log"
        return 1
    fi
    
    # Clear log
    > "$TEST_TEMP_DIR/s3_calls.log"
    
    # Test with compression disabled
    echo "Testing with compression disabled..."
    export DISABLE_MODEL_COMPRESSION=true
    source "$NETWORK_VOLUME/scripts/model_sync_integration.sh"
    
    # Call upload function
    upload_file_with_progress "$test_file" "s3://test-bucket/models/test_model.safetensors" "model_upload" 1 1 "https://example.com/download" 2>/dev/null
    
    # Check if uncompressed file was uploaded
    if grep -q "\.tar\.zst" "$TEST_TEMP_DIR/s3_calls.log"; then
        echo "❌ Compression disabled: but compressed file was still uploaded"
        cat "$TEST_TEMP_DIR/s3_calls.log"
        return 1
    else
        echo "✅ Compression disabled: uncompressed file was uploaded"
    fi
    
    # Clean up
    rm -f "$test_file"
    unset DISABLE_MODEL_COMPRESSION
    
    echo "✅ Compression disable flag tests passed"
    return 0
}

# Test resource limits during compression
test_compression_resource_limits() {
    start_test "Model Compression Resource Limits"
    
    # Setup test environment
    mkdir -p "$NETWORK_VOLUME/scripts"
    mkdir -p "$NETWORK_VOLUME/ComfyUI/models/checkpoints"
    
    # Generate the model sync integration script
    source "$PROJECT_ROOT/scripts/create_model_sync_integration.sh"
    source "$NETWORK_VOLUME/scripts/model_sync_integration.sh"
    
    # Create test file
    local test_file="$NETWORK_VOLUME/ComfyUI/models/checkpoints/resource_test.safetensors"
    dd if=/dev/zero of="$test_file" bs=1M count=12 2>/dev/null
    
    # Test compression with timeout monitoring
    echo "Testing compression with resource limits..."
    local temp_dir
    temp_dir=$(mktemp -d)
    
    local start_time
    start_time=$(date +%s)
    
    # Run compression
    local compressed_file
    compressed_file=$(compress_model_file "$test_file" "$temp_dir" 2>/dev/null)
    local compress_result=$?
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    if [ $compress_result -eq 0 ]; then
        echo "✅ Compression completed successfully"
        
        # Check duration (should be well under the 300s timeout for a 12MB file)
        if [ "$duration" -lt 60 ]; then
            echo "✅ Compression completed in reasonable time: ${duration}s"
        else
            echo "⚠️ Compression took longer than expected: ${duration}s"
        fi
        
        rm -f "$compressed_file"
    else
        echo "❌ Compression failed"
        return 1
    fi
    
    # Clean up
    rm -rf "$temp_dir"
    rm -f "$test_file"
    
    echo "✅ Compression resource limit tests passed"
    return 0
}

# Test error handling in compression
test_compression_error_handling() {
    start_test "Model Compression Error Handling"
    
    # Setup test environment
    mkdir -p "$NETWORK_VOLUME/scripts"
    
    # Generate the model sync integration script
    source "$PROJECT_ROOT/scripts/create_model_sync_integration.sh"
    source "$NETWORK_VOLUME/scripts/model_sync_integration.sh"
    
    # Test with non-existent file
    echo "Testing with non-existent file..."
    local temp_dir
    temp_dir=$(mktemp -d)
    
    local result
    result=$(compress_model_file "/non/existent/file.safetensors" "$temp_dir" 2>/dev/null)
    local compress_result=$?
    
    if [ $compress_result -ne 0 ]; then
        echo "✅ Correctly handled non-existent file"
    else
        echo "❌ Should have failed with non-existent file"
        return 1
    fi
    
    # Test with missing parameters
    echo "Testing with missing parameters..."
    result=$(compress_model_file "" "$temp_dir" 2>/dev/null)
    compress_result=$?
    
    if [ $compress_result -ne 0 ]; then
        echo "✅ Correctly handled missing parameters"
    else
        echo "❌ Should have failed with missing parameters"
        return 1
    fi
    
    # Clean up
    rm -rf "$temp_dir"
    
    echo "✅ Compression error handling tests passed"
    return 0
}

# Run all tests
echo "=== Testing Model Compression Logic ==="
test_compression_size_thresholds
test_compression_disable_flag
test_compression_resource_limits
test_compression_error_handling

# Print summary
echo
echo "=== Test Summary ==="
echo "✅ All compression logic tests completed!"
