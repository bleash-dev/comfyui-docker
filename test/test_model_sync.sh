#!/bin/bash
# Test script for model sync integration
# This script tests compression and upload functionality in a temporary directory

set -e

echo "🧪 Model Sync Integration Test Script"
echo "====================================="

# Create temporary test environment in /tmp
TEST_DIR=$(mktemp -d -t model_sync_test.XXXXXX)
echo "📁 Test directory: $TEST_DIR"

# Cleanup function
cleanup() {
    echo "🧹 Cleaning up test directory: $TEST_DIR"
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT INT TERM QUIT

# Set up test environment variables
export NETWORK_VOLUME="$TEST_DIR"
export AWS_BUCKET_NAME="${AWS_BUCKET_NAME:-test-bucket}"
export MODEL_SYNC_LOG="$TEST_DIR/model_sync_test.log"

# Create mock directories
mkdir -p "$TEST_DIR/scripts"
mkdir -p "$TEST_DIR/ComfyUI/models/checkpoints"

echo "🔧 Setting up test environment..."

# Create a simple test model file (10MB to trigger compression)
TEST_MODEL_FILE="$TEST_DIR/ComfyUI/models/checkpoints/test-model.safetensors"
echo "📄 Creating test model file: $TEST_MODEL_FILE"
dd if=/dev/zero of="$TEST_MODEL_FILE" bs=1024 count=10240 2>/dev/null
echo "✅ Created 10MB test model file"

# Create mock functions to replace dependencies
cat > "$TEST_DIR/scripts/mock_functions.sh" << 'EOF'
#!/bin/bash

# Mock extract_model_name_from_path function
extract_model_name_from_path() {
    basename "$1"
}

# Mock s3_copy_to function
s3_copy_to() {
    local source="$1"
    local destination="$2"
    shift 2
    local metadata_args="$*"
    
    echo "MOCK: s3_copy_to called with:"
    echo "  Source: $source"
    echo "  Destination: $destination" 
    echo "  Metadata: $metadata_args"
    
    # Check if source file exists
    if [ ! -f "$source" ]; then
        echo "ERROR: Source file does not exist: $source"
        return 1
    fi
    
    # Get file size
    local file_size
    file_size=$(stat -f%z "$source" 2>/dev/null || stat -c%s "$source" 2>/dev/null || echo "0")
    echo "  File size: $file_size bytes"
    
    # Simulate upload time based on file size (1 second per 100MB)
    local sleep_time=$((file_size / 104857600 + 1))
    if [ "$sleep_time" -gt 10 ]; then
        sleep_time=10  # Cap at 10 seconds for testing
    fi
    
    echo "  Simulating upload (${sleep_time}s)..."
    sleep "$sleep_time"
    
    echo "  ✅ Mock upload successful"
    return 0
}

# Mock notify_sync_progress function
notify_sync_progress() {
    local sync_type="$1"
    local status="$2"
    local percentage="$3"
    echo "MOCK: Progress notification: $sync_type $status $percentage%"
}

EOF

# Source mock functions
source "$TEST_DIR/scripts/mock_functions.sh"

# Create the compress_model_file function (extract from the main script)
cat > "$TEST_DIR/scripts/compress_functions.sh" << 'EOF'
#!/bin/bash

# Function to log model sync activities
log_model_sync() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] Model Sync Test: $message" | tee -a "$MODEL_SYNC_LOG" >&2
}

# Function to compress model file to .tar.zst format
compress_model_file() {
    local source_file="$1"
    local temp_dir="$2"

    if [ -z "$source_file" ] || [ -z "$temp_dir" ]; then
        log_model_sync "ERROR" "Missing parameters for compress_model_file"
        return 1
    fi

    if [ ! -f "$source_file" ]; then
        log_model_sync "ERROR" "Source file does not exist: $source_file"
        return 1
    fi

    # Check if zstd is available
    if ! command -v zstd >/dev/null 2>&1; then
        log_model_sync "ERROR" "zstd command not found. Cannot compress model."
        return 1
    fi

    local file_name=$(basename "$source_file")
    local compressed_file="$temp_dir/${file_name}.tar.zst"

    log_model_sync "INFO" "Compressing model file: $file_name"

    # Create a tar archive and compress it with zstd in one step
    # Use maximum compression level (22) for best compression ratio
    if tar -cf - -C "$(dirname "$source_file")" "$(basename "$source_file")" | zstd -22 -T0 -o "$compressed_file"; then
        log_model_sync "INFO" "Successfully compressed $file_name to $(basename "$compressed_file")"

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

        log_model_sync "INFO" "Compression: $original_size bytes -> $compressed_size bytes (${compression_ratio}%)"

        # Return the compressed file path via standard output
        echo "$compressed_file"
        return 0
    else
        log_model_sync "ERROR" "Failed to compress model file: $file_name"
        rm -f "$compressed_file"
        return 1
    fi
}

# Function to upload file to S3 with progress tracking (for model uploads)
upload_file_with_progress() {
    local local_file="$1"
    local s3_destination="$2"
    local sync_type="$3"
    local current_file_index="$4"
    local total_files="$5"
    local download_url="$6"  # Optional download URL for metadata (required for model uploads)
    
    if [ -z "$local_file" ] || [ -z "$s3_destination" ] || [ -z "$sync_type" ]; then
        log_model_sync "ERROR" "Missing required parameters for S3 upload"
        return 1
    fi
    
    if [ ! -f "$local_file" ]; then
        log_model_sync "ERROR" "File does not exist: $local_file"
        return 1
    fi
    
    local file_size
    file_size=$(stat -f%z "$local_file" 2>/dev/null || stat -c%s "$local_file" 2>/dev/null || echo "0")
    local file_name=$(extract_model_name_from_path "$local_file")
    
    log_model_sync "INFO" "Uploading $file_name to S3 (${file_size} bytes)"
    
    # Prepare metadata with download URL (required) and original file size
    local metadata_args="--metadata downloadUrl=$download_url,uncompressed-size=$file_size"
    log_model_sync "INFO" "Including download URL and uncompressed size in metadata: $download_url, size: $file_size"
    
    # Create temporary directory for compression
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" EXIT INT TERM QUIT
    
    # Compress the model file
    local upload_file="$local_file"
    local compressed_s3_destination="${s3_destination}.tar.zst"
    
    # Check if compression should be used (for files larger than 10MB)
    if [ "$file_size" -gt 10485760 ]; then
        log_model_sync "INFO" "File is larger than 10MB, applying compression: $file_name"
        
        local compressed_file_result
        compressed_file_result=$(compress_model_file "$local_file" "$temp_dir")
        
        if [ $? -eq 0 ] && [ -n "$compressed_file_result" ]; then
            log_model_sync "INFO" "Compression result: $compressed_file_result"
            
            # Verify the compressed file exists
            if [ ! -f "$compressed_file_result" ]; then
                log_model_sync "ERROR" "Compressed file was not created properly: $compressed_file_result"
                log_model_sync "WARN" "Falling back to uncompressed file: $file_name"
                upload_file="$local_file"
                s3_destination="${s3_destination%.tar.zst}"  # Remove .tar.zst suffix
                metadata_args="--metadata downloadUrl=$download_url"
            else
                upload_file="$compressed_file_result"
                s3_destination="$compressed_s3_destination"
                
                # Get compressed file size for progress tracking
                file_size=$(stat -f%z "$upload_file" 2>/dev/null || stat -c%s "$upload_file" 2>/dev/null || echo "0")
                log_model_sync "INFO" "Using compressed file for upload: $(basename "$upload_file") (${file_size} bytes)"
            fi
        else
            log_model_sync "WARN" "Compression failed, uploading uncompressed file: $file_name"
            # Remove compressed-specific metadata if compression failed
            metadata_args="--metadata downloadUrl=$download_url"
        fi
    else
        log_model_sync "INFO" "File is smaller than 10MB, uploading uncompressed: $file_name"
        # Remove compressed-specific metadata for small files
        metadata_args="--metadata downloadUrl=$download_url"
    fi
    
    log_model_sync "INFO" "Final upload parameters:"
    log_model_sync "INFO" "  Upload file: $upload_file"
    log_model_sync "INFO" "  S3 destination: $s3_destination"
    log_model_sync "INFO" "  File size: $file_size bytes"
    log_model_sync "INFO" "  Metadata: $metadata_args"
    
    # Perform the actual upload
    if s3_copy_to "$upload_file" "$s3_destination" $metadata_args; then
        log_model_sync "INFO" "Successfully uploaded: $file_name"
        return 0
    else
        log_model_sync "ERROR" "Failed to upload: $file_name"
        return 1
    fi
}

EOF

# Source the compression functions
source "$TEST_DIR/scripts/compress_functions.sh"

echo ""
echo "🚀 Starting tests..."
echo ""

# Test 1: Compression test
echo "📦 Test 1: Testing compression function..."
test_temp_dir=$(mktemp -d)
compressed_result=$(compress_model_file "$TEST_MODEL_FILE" "$test_temp_dir")
compression_exit_code=$?

echo "  Compression exit code: $compression_exit_code"
echo "  Compressed file result: $compressed_result"

if [ "$compression_exit_code" -eq 0 ] && [ -n "$compressed_result" ]; then
    if [ -f "$compressed_result" ]; then
        original_size=$(stat -f%z "$TEST_MODEL_FILE" 2>/dev/null || stat -c%s "$TEST_MODEL_FILE" 2>/dev/null || echo "0")
        compressed_size=$(stat -f%z "$compressed_result" 2>/dev/null || stat -c%s "$compressed_result" 2>/dev/null || echo "0")
        echo "  ✅ Compression successful!"
        echo "     Original: $original_size bytes"
        echo "     Compressed: $compressed_size bytes"
        echo "     Compressed file: $compressed_result"
    else
        echo "  ❌ Compression function returned success but file doesn't exist: $compressed_result"
    fi
else
    echo "  ❌ Compression failed!"
fi

rm -rf "$test_temp_dir"

echo ""
echo "📤 Test 2: Testing upload function..."

# Test the upload function with a mock download URL
test_download_url="https://example.com/test-model.safetensors"
upload_file_with_progress "$TEST_MODEL_FILE" "s3://$AWS_BUCKET_NAME/test/test-model.safetensors" "global_shared" "1" "1" "$test_download_url"
upload_exit_code=$?

if [ "$upload_exit_code" -eq 0 ]; then
    echo "  ✅ Upload test successful!"
else
    echo "  ❌ Upload test failed with exit code: $upload_exit_code"
fi

echo ""
echo "📊 Test 3: Checking if zstd is available..."
if command -v zstd >/dev/null 2>&1; then
    echo "  ✅ zstd is available"
    zstd --version
else
    echo "  ❌ zstd is NOT available - this could be the issue!"
    echo "     Install zstd with: brew install zstd (on macOS) or apt-get install zstd (on Ubuntu)"
fi

echo ""
echo "📊 Test 4: Checking if bc is available..."
if command -v bc >/dev/null 2>&1; then
    echo "  ✅ bc is available"
else
    echo "  ❌ bc is NOT available - this could affect compression ratio calculation"
    echo "     Install bc with: brew install bc (on macOS) or apt-get install bc (on Ubuntu)"
fi

echo ""
echo "📊 Test 5: Testing pv availability..."
if command -v pv >/dev/null 2>&1; then
    echo "  ✅ pv is available"
    pv --version 2>/dev/null || echo "     (version info not available)"
else
    echo "  ⚠️ pv is NOT available - progress tracking will use fallback method"
    echo "     Install pv with: brew install pv (on macOS) or apt-get install pv (on Ubuntu)"
fi

echo ""
echo "📋 Test Results Summary:"
echo "======================="
if [ -f "$MODEL_SYNC_LOG" ]; then
    echo "📄 Log file contents:"
    echo "-------------------"
    cat "$MODEL_SYNC_LOG"
else
    echo "⚠️ No log file was created"
fi

echo ""
echo "🔍 Debugging Information:"
echo "========================"
echo "Test directory: $TEST_DIR"
echo "Test model file: $TEST_MODEL_FILE"
echo "Test model file exists: $([ -f "$TEST_MODEL_FILE" ] && echo "YES" || echo "NO")"
if [ -f "$TEST_MODEL_FILE" ]; then
    echo "Test model file size: $(stat -f%z "$TEST_MODEL_FILE" 2>/dev/null || stat -c%s "$TEST_MODEL_FILE" 2>/dev/null || echo "0") bytes"
fi

echo ""
echo "✅ Test script completed!"
