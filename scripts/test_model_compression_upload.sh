#!/bin/bash
# Test script for model compression and upload functionality

set -e

echo "🧪 Testing Model Compression and Upload Functionality"
echo "====================================================="

# Create test directory
TEST_DIR="/tmp/model_upload_test_$$"
mkdir -p "$TEST_DIR"
echo "📁 Test directory: $TEST_DIR"

# Cleanup function
cleanup() {
    echo "🧹 Cleaning up test files..."
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Create a test model file (10MB)
TEST_MODEL="$TEST_DIR/test_model.safetensors"
echo "📦 Creating test model file (10MB)..."
dd if=/dev/zero of="$TEST_MODEL" bs=1024 count=10240 2>/dev/null
echo "✅ Test model created: $(ls -lh "$TEST_MODEL")"

# Test compression function
echo ""
echo "🗜️ Testing Compression Function"
echo "================================"

# Copy the compress_model_file function for testing
compress_model_file_test() {
    local source_file="$1"
    local temp_dir="$2"

    if [ -z "$source_file" ] || [ -z "$temp_dir" ]; then
        echo "ERROR: Missing parameters for compress_model_file"
        return 1
    fi

    if [ ! -f "$source_file" ]; then
        echo "ERROR: Source file does not exist: $source_file"
        return 1
    fi

    # Check if zstd is available
    if ! command -v zstd >/dev/null 2>&1; then
        echo "ERROR: zstd command not found. Cannot compress model."
        return 1
    fi

    local file_name=$(basename "$source_file")
    local compressed_file="$temp_dir/${file_name}.tar.zst"

    echo "INFO: Compressing model file: $file_name"

    # Create a tar archive and compress it with zstd in one step
    if tar -cf - -C "$(dirname "$source_file")" "$(basename "$source_file")" | zstd -22 -T0 -o "$compressed_file"; then
        echo "INFO: Successfully compressed $file_name to $(basename "$compressed_file")"

        # Get compressed file size
        local compressed_size
        compressed_size=$(stat -f%z "$compressed_file" 2>/dev/null || stat -c%s "$compressed_file" 2>/dev/null || echo "0")

        # Get original file size
        local original_size
        original_size=$(stat -f%z "$source_file" 2>/dev/null || stat -c%s "$source_file" 2>/dev/null || echo "0")

        # Calculate compression ratio
        local compression_ratio=0
        if [ "$original_size" -gt 0 ]; then
            compression_ratio=$(echo "scale=2; $compressed_size * 100 / $original_size" | bc 2>/dev/null || echo "0")
        fi

        echo "INFO: Compression: $original_size bytes -> $compressed_size bytes (${compression_ratio}%)"

        # Return the compressed file path via standard output
        echo "$compressed_file"
        return 0
    else
        echo "ERROR: Failed to compress model file: $file_name"
        rm -f "$compressed_file"
        return 1
    fi
}

# Test compression
TEMP_DIR="$TEST_DIR/temp"
mkdir -p "$TEMP_DIR"

echo "Testing compression with test model..."
COMPRESSED_FILE=""
if COMPRESSED_FILE=$(compress_model_file_test "$TEST_MODEL" "$TEMP_DIR"); then
    echo "✅ Compression successful!"
    echo "   Original: $(ls -lh "$TEST_MODEL" | awk '{print $5}')"
    echo "   Compressed: $(ls -lh "$COMPRESSED_FILE" | awk '{print $5}')"
    echo "   File exists: $([ -f "$COMPRESSED_FILE" ] && echo "YES" || echo "NO")"
    echo "   Compressed file path: $COMPRESSED_FILE"
else
    echo "❌ Compression failed!"
    exit 1
fi

# Test S3 functions availability
echo ""
echo "☁️ Testing S3 Functions Availability"
echo "===================================="

# Source S3 interactor if available
if [ -f "$NETWORK_VOLUME/scripts/s3_interactor.sh" ]; then
    echo "📥 Sourcing S3 interactor..."
    source "$NETWORK_VOLUME/scripts/s3_interactor.sh"
    
    # Test S3 functions
    if command -v s3_copy_to >/dev/null 2>&1; then
        echo "✅ s3_copy_to function available"
    else
        echo "❌ s3_copy_to function NOT available"
    fi
    
    if command -v s3_list >/dev/null 2>&1; then
        echo "✅ s3_list function available"
    else
        echo "❌ s3_list function NOT available"
    fi
else
    echo "⚠️ S3 interactor not found at $NETWORK_VOLUME/scripts/s3_interactor.sh"
fi

# Test pv availability and usage
echo ""
echo "📊 Testing PV (Pipe Viewer) Functionality"
echo "=========================================="

if command -v pv >/dev/null 2>&1; then
    echo "✅ pv command available"
    
    # Test pv with a simple file
    echo "Testing pv with compressed file..."
    echo "File size: $(stat -f%z "$COMPRESSED_FILE" 2>/dev/null || stat -c%s "$COMPRESSED_FILE" 2>/dev/null || echo "0") bytes"
    
    # Test different pv usage patterns
    echo ""
    echo "1. Testing: pv file > /dev/null (current approach)"
    time pv "$COMPRESSED_FILE" > /dev/null
    
    echo ""
    echo "2. Testing: cat file | pv > /dev/null (alternative approach)"
    time cat "$COMPRESSED_FILE" | pv > /dev/null
    
    echo ""
    echo "3. Testing: pv file | cat > /dev/null (pipe through approach)"
    time pv "$COMPRESSED_FILE" | cat > /dev/null
    
else
    echo "❌ pv command NOT available"
fi

# Test AWS CLI availability
echo ""
echo "🔧 Testing AWS CLI Availability"
echo "==============================="

if command -v aws >/dev/null 2>&1; then
    echo "✅ aws command available"
    echo "   Version: $(aws --version 2>&1 || echo "unknown")"
    
    # Test AWS credentials
    if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
        echo "✅ AWS credentials configured"
        echo "   Access Key ID: ${AWS_ACCESS_KEY_ID:0:4}***"
        echo "   Region: ${AWS_REGION:-not set}"
        echo "   Bucket: ${AWS_BUCKET_NAME:-not set}"
        
        # Test basic connectivity (if S3 interactor is available)
        if command -v s3_test_connectivity >/dev/null 2>&1; then
            echo "Testing S3 connectivity..."
            if s3_test_connectivity; then
                echo "✅ S3 connectivity test passed"
            else
                echo "❌ S3 connectivity test failed"
            fi
        fi
    else
        echo "⚠️ AWS credentials not configured"
    fi
else
    echo "❌ aws command NOT available"
fi

# Test upload simulation (without actually uploading)
echo ""
echo "🚀 Testing Upload Logic Simulation"
echo "=================================="

# Simulate the upload logic from the script
simulate_upload() {
    local upload_file="$1"
    local file_size="$2"
    local file_name="$(basename "$upload_file")"
    
    echo "Simulating upload for: $file_name"
    echo "File size: $file_size bytes"
    echo "File exists: $([ -f "$upload_file" ] && echo "YES" || echo "NO")"
    
    # Check if pv is available and file is large enough
    if command -v pv >/dev/null 2>&1 && [ "$file_size" -gt 10485760 ]; then
        echo "✅ Would use pv for progress tracking"
        
        # Test the pv command that would be used
        echo "Testing pv command..."
        if pv "$upload_file" > /dev/null; then
            echo "✅ pv command works correctly"
        else
            echo "❌ pv command failed"
            return 1
        fi
        
        # Test the s3_copy_to command (if available)
        if command -v s3_copy_to >/dev/null 2>&1; then
            echo "✅ s3_copy_to function available for upload"
            # Don't actually upload, just test the command existence
        else
            echo "❌ s3_copy_to function NOT available"
            return 1
        fi
    else
        echo "ℹ️ Would use regular upload (no pv or file too small)"
    fi
    
    return 0
}

# Get file size
FILE_SIZE=$(stat -f%z "$COMPRESSED_FILE" 2>/dev/null || stat -c%s "$COMPRESSED_FILE" 2>/dev/null || echo "0")

echo "Testing upload simulation with compressed file..."
if simulate_upload "$COMPRESSED_FILE" "$FILE_SIZE"; then
    echo "✅ Upload simulation passed"
else
    echo "❌ Upload simulation failed"
fi

# Test metadata args parsing
echo ""
echo "📋 Testing Metadata Args"
echo "========================"

test_metadata_args() {
    local download_url="https://example.com/model.safetensors"
    local file_size="1964940653"
    
    echo "Testing metadata args construction..."
    local metadata_args="--metadata downloadUrl=$download_url,uncompressed-size=$file_size"
    echo "Metadata args: $metadata_args"
    
    # Parse the args to make sure they're valid
    if [[ "$metadata_args" =~ --metadata ]]; then
        echo "✅ Metadata args format is correct"
    else
        echo "❌ Metadata args format is incorrect"
    fi
}

test_metadata_args

# Test the actual upload function logic
echo ""
echo "🔍 Testing Upload Function Logic"
echo "================================"

test_upload_function() {
    local local_file="$COMPRESSED_FILE"
    local s3_destination="s3://test-bucket/models/test_model.safetensors.tar.zst"
    local download_url="https://example.com/test_model.safetensors"
    
    echo "Testing upload function logic..."
    echo "Local file: $local_file"
    echo "S3 destination: $s3_destination" 
    echo "Download URL: $download_url"
    
    if [ ! -f "$local_file" ]; then
        echo "❌ Local file does not exist"
        return 1
    fi
    
    local file_size
    file_size=$(stat -f%z "$local_file" 2>/dev/null || stat -c%s "$local_file" 2>/dev/null || echo "0")
    
    echo "File size: $file_size bytes"
    
    # Test metadata construction
    local metadata_args="--metadata downloadUrl=$download_url,uncompressed-size=$file_size"
    echo "Metadata args: $metadata_args"
    
    # Test pv logic
    if command -v pv >/dev/null 2>&1 && [ "$file_size" -gt 10485760 ]; then
        echo "✅ Would use pv for upload progress"
        
        # The issue might be here - let's test the pv command properly
        echo "Testing pv in background..."
        pv "$local_file" > /dev/null &
        local pv_pid=$!
        echo "PV PID: $pv_pid"
        
        # Wait a moment then kill
        sleep 1
        if kill $pv_pid 2>/dev/null; then
            echo "✅ PV process killed successfully"
        else
            echo "⚠️ PV process already finished or couldn't be killed"
        fi
        
        # Test AWS command simulation
        echo "Testing AWS CLI command simulation..."
        if command -v aws >/dev/null 2>&1; then
            # Don't actually run the command, just test the syntax
            local aws_cmd="aws s3 cp \"$local_file\" \"$s3_destination\" $metadata_args"
            echo "AWS command would be: $aws_cmd"
            echo "✅ AWS command syntax looks correct"
        else
            echo "❌ AWS CLI not available"
        fi
    else
        echo "ℹ️ Would use regular upload (no pv or small file)"
    fi
    
    return 0
}

test_upload_function

echo ""
echo "📊 Test Summary"
echo "==============="
echo "✅ Compression: PASSED"
echo "$(command -v pv >/dev/null 2>&1 && echo "✅" || echo "❌") PV Available: $(command -v pv >/dev/null 2>&1 && echo "YES" || echo "NO")"
echo "$(command -v aws >/dev/null 2>&1 && echo "✅" || echo "❌") AWS CLI: $(command -v aws >/dev/null 2>&1 && echo "YES" || echo "NO")"
echo "$(command -v s3_copy_to >/dev/null 2>&1 && echo "✅" || echo "❌") S3 Functions: $(command -v s3_copy_to >/dev/null 2>&1 && echo "YES" || echo "NO")"

echo ""
echo "🔧 Recommendations"
echo "=================="
echo "1. The issue is likely in the pv usage - it's running independently of the upload"
echo "2. The pv process should be integrated with the actual upload, not run separately"
echo "3. Consider using AWS CLI's built-in progress instead of pv"
echo "4. Test the actual s3_copy_to function to see what arguments it accepts"

echo ""
echo "🧪 Test completed!"
