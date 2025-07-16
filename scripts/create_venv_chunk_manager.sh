#!/bin/bash
# Create venv chunk manager script

echo "📝 Creating venv chunk manager script..."

# Set default script directory
export SCRIPT_DIR="${SCRIPT_DIR:-/scripts}"

# Create the venv chunk manager script
cat > "$NETWORK_VOLUME/scripts/venv_chunk_manager.sh" << 'EOF'
#!/bin/bash
# Virtual Environment Chunk Manager
# Handles chunked compression, upload, download, and extraction of Python venv site-packages
# Optimized for cloud storage sync with parallel processing and resumable transfers

set -euo pipefail

# Configuration
VENV_CHUNK_SIZE_MB="${VENV_CHUNK_SIZE_MB:-100}"
VENV_MAX_PARALLEL="${VENV_MAX_PARALLEL:-10}"
VENV_COMPRESSION_LEVEL="${VENV_COMPRESSION_LEVEL:-6}"
VENV_LOG_FILE="${VENV_LOG_FILE:-$NETWORK_VOLUME/.venv_chunk_manager.log}"

# Internal configuration
CHUNK_PREFIX="venv_chunk_"
CHECKSUM_FILE="venv_chunks.checksums"

# Logging functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$VENV_LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$VENV_LOG_FILE" >&2
}

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*" | tee -a "$VENV_LOG_FILE" >&2
}

# Utility functions
cleanup_temp() {
    if [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
        log_info "Cleaning up temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}

# Set up signal handlers for cleanup
trap cleanup_temp EXIT INT TERM

# Check dependencies
check_dependencies() {
    local missing_deps=()
    
    for cmd in tar gzip split cat awk; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        return 1
    fi
}

# Calculate checksums for a directory
calculate_directory_checksum() {
    local dir="$1"
    
    if [ ! -d "$dir" ]; then
        echo ""
        return 1
    fi
    
    # Use find with sort to ensure consistent ordering
    find "$dir" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
}

# Generate chunk list from site-packages
generate_chunk_list() {
    local site_packages="$1"
    local chunk_size_bytes=$((VENV_CHUNK_SIZE_MB * 1024 * 1024))
    local current_chunk=1
    local current_size=0
    local chunk_file
    
    log_info "Generating chunk list for: $site_packages"
    
    # Create temporary directory for chunk lists
    local TEMP_DIR
    TEMP_DIR=$(mktemp -d)
    chunk_file="$TEMP_DIR/chunk_${current_chunk}.list"
    
    # Find all files and process them (avoid pipeline to preserve variables)
    local temp_file_list
    temp_file_list=$(mktemp)
    find "$site_packages" -type f > "$temp_file_list"
    
    while IFS= read -r file; do
        if [ ! -e "$file" ]; then
            continue
        fi
        
        file_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
        
        # If adding this file would exceed chunk size, start a new chunk
        if [ $((current_size + file_size)) -gt $chunk_size_bytes ] && [ $current_size -gt 0 ]; then
            current_chunk=$((current_chunk + 1))
            chunk_file="$TEMP_DIR/chunk_${current_chunk}.list"
            current_size=0
        fi
        
        echo "$file" >> "$chunk_file"
        current_size=$((current_size + file_size))
    done < "$temp_file_list"
    
    # Clean up temp file
    rm -f "$temp_file_list"
    
    # Output the temporary directory path
    echo "$TEMP_DIR"
}

# Create compressed chunk from file list
create_chunk() {
    local chunk_list="$1"
    local output_file="$2"
    local base_dir="$3"
    
    if [ ! -f "$chunk_list" ] || [ ! -s "$chunk_list" ]; then
        log_error "Chunk list file not found or empty: $chunk_list"
        return 1
    fi
    
    log_info "Creating chunk: $output_file"
    
    # Create tar archive with compression
    tar -czf "$output_file" -C "$base_dir" --files-from=<(
        # Convert absolute paths to relative paths
        while IFS= read -r file; do
            echo "${file#$base_dir/}"
        done < "$chunk_list"
    ) 2>/dev/null || {
        log_error "Failed to create chunk: $output_file"
        return 1
    }
    
    log_info "Created chunk: $output_file ($(du -h "$output_file" | cut -f1))"
}

# Extract chunk to destination
extract_chunk() {
    local chunk_file="$1"
    local dest_dir="$2"
    
    if [ ! -f "$chunk_file" ]; then
        log_error "Chunk file not found: $chunk_file"
        return 1
    fi
    
    log_info "Extracting chunk: $chunk_file to $dest_dir"
    
    mkdir -p "$dest_dir"
    
    if tar -xzf "$chunk_file" -C "$dest_dir" 2>/dev/null; then
        log_info "Successfully extracted: $chunk_file"
        return 0
    else
        log_error "Failed to extract chunk: $chunk_file"
        return 1
    fi
}

# Parallel chunk processing
process_chunks_parallel() {
    local action="$1"
    local source_dir="$2"
    local dest_dir="$3"
    local chunk_dir="$4"
    
    local pids=()
    local max_jobs=$VENV_MAX_PARALLEL
    local job_count=0
    
    case "$action" in
        "create")
            local chunk_lists_dir
            chunk_lists_dir=$(generate_chunk_list "$source_dir")
            local generate_result=$?
            
            if [ $generate_result -ne 0 ] || [ -z "$chunk_lists_dir" ] || [ ! -d "$chunk_lists_dir" ]; then
                log_error "Failed to generate chunk lists: result=$generate_result, dir=$chunk_lists_dir"
                return 1
            fi
            
            # Count available chunk lists
            local available_chunks
            available_chunks=$(ls "$chunk_lists_dir"/chunk_*.list 2>/dev/null | wc -l)
            
            if [ "$available_chunks" -eq 0 ]; then
                log_error "No chunk list files found in $chunk_lists_dir"
                return 1
            fi
            
            for chunk_list in "$chunk_lists_dir"/chunk_*.list; do
                if [ ! -f "$chunk_list" ]; then
                    continue
                fi
                
                local chunk_num
                chunk_num=$(basename "$chunk_list" .list | sed 's/chunk_//')
                local chunk_file="$dest_dir/${CHUNK_PREFIX}${chunk_num}.tar.gz"
                
                # Wait if we've reached max parallel jobs
                while [ $job_count -ge $max_jobs ]; do
                    if [ ${#pids[@]} -gt 0 ]; then
                        for i in "${!pids[@]}"; do
                            if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                                wait "${pids[$i]}" 2>/dev/null || true
                                unset 'pids[i]'
                                job_count=$((job_count - 1))
                            fi
                        done
                    fi
                    sleep 0.1
                done
                
                # Start chunk creation in background
                create_chunk "$chunk_list" "$chunk_file" "$source_dir" &
                pids+=($!)
                job_count=$((job_count + 1))
            done
            ;;
            
        "extract")
            for chunk_file in "$source_dir"/${CHUNK_PREFIX}*.tar.gz; do
                if [ ! -f "$chunk_file" ]; then
                    continue
                fi
                
                # Wait if we've reached max parallel jobs
                while [ $job_count -ge $max_jobs ]; do
                    if [ ${#pids[@]} -gt 0 ]; then
                        for i in "${!pids[@]}"; do
                            if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                                wait "${pids[$i]}" 2>/dev/null || true
                                unset 'pids[i]'
                                job_count=$((job_count - 1))
                            fi
                        done
                    fi
                    sleep 0.1
                done
                
                # Start extraction in background
                extract_chunk "$chunk_file" "$dest_dir" &
                pids+=($!)
                job_count=$((job_count + 1))
            done
            ;;
    esac
    
    # Wait for all background jobs to complete
    if [ ${#pids[@]} -gt 0 ]; then
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                wait "$pid" || {
                    log_error "Background job failed: $pid"
                    return 1
                }
            fi
        done
    fi
    
    log_info "All parallel $action operations completed"
}

# Generate checksums for chunks
generate_checksums() {
    local chunk_dir="$1"
    local checksum_file="$2"
    
    log_info "Generating checksums for chunks in: $chunk_dir"
    
    > "$checksum_file"  # Clear file
    
    for chunk_file in "$chunk_dir"/${CHUNK_PREFIX}*.tar.gz; do
        if [ -f "$chunk_file" ]; then
            local checksum
            checksum=$(sha256sum "$chunk_file" | cut -d' ' -f1)
            echo "$checksum $(basename "$chunk_file")" >> "$checksum_file"
        fi
    done
    
    log_info "Generated checksums: $checksum_file"
}

# Verify chunks against checksums
verify_checksums() {
    local chunk_dir="$1"
    local checksum_file="$2"
    
    if [ ! -f "$checksum_file" ]; then
        log_error "Checksum file not found: $checksum_file"
        return 1
    fi
    
    log_info "Verifying chunks against checksums"
    
    local failed_count=0
    
    while IFS= read -r line; do
        local expected_checksum
        local chunk_name
        expected_checksum=$(echo "$line" | cut -d' ' -f1)
        chunk_name=$(echo "$line" | cut -d' ' -f2-)
        
        local chunk_file="$chunk_dir/$chunk_name"
        
        if [ ! -f "$chunk_file" ]; then
            log_error "Missing chunk: $chunk_file"
            failed_count=$((failed_count + 1))
            continue
        fi
        
        local actual_checksum
        actual_checksum=$(sha256sum "$chunk_file" | cut -d' ' -f1)
        
        if [ "$expected_checksum" != "$actual_checksum" ]; then
            log_error "Checksum mismatch for $chunk_file"
            log_error "Expected: $expected_checksum"
            log_error "Actual: $actual_checksum"
            failed_count=$((failed_count + 1))
        fi
    done < "$checksum_file"
    
    if [ $failed_count -eq 0 ]; then
        log_info "All chunk checksums verified successfully"
        return 0
    else
        log_error "Checksum verification failed for $failed_count chunks"
        return 1
    fi
}

# Main functions
chunk_site_packages() {
    local venv_path="$1"
    local output_dir="$2"
    
    # Try to find the site-packages directory in different possible locations
    local site_packages=""
    local possible_paths=(
        "$venv_path/lib/python${PYTHON_VERSION}/site-packages"
        "$venv_path/comfyui/lib/python${PYTHON_VERSION}/site-packages"
        "$venv_path/*/lib/python${PYTHON_VERSION}/site-packages"
    )
    
    for path in "${possible_paths[@]}"; do
        # Handle glob expansion for the wildcard path
        if [[ "$path" == *"*"* ]]; then
            for expanded_path in $path; do
                if [ -d "$expanded_path" ]; then
                    site_packages="$expanded_path"
                    break 2
                fi
            done
        elif [ -d "$path" ]; then
            site_packages="$path"
            break
        fi
    done
    
    if [ -z "$site_packages" ] || [ ! -d "$site_packages" ]; then
        log_error "Site-packages directory not found in venv: $venv_path"
        log_error "Tried paths: ${possible_paths[*]}"
        log_error "Available directories in venv:"
        find "$venv_path" -type d -name "*python*" -o -name "*site-packages*" 2>/dev/null | head -10 || true
        return 1
    fi
    
    log_info "Found site-packages at: $site_packages"
    log_info "Starting chunked compression of: $site_packages"
    log_info "Output directory: $output_dir"
    log_info "Chunk size: ${VENV_CHUNK_SIZE_MB}MB, Parallel jobs: $VENV_MAX_PARALLEL"
    
    mkdir -p "$output_dir"
    
    # Calculate source checksum for change detection
    local source_checksum
    source_checksum=$(calculate_directory_checksum "$site_packages")
    
    # Check if we have existing chunks with same source checksum
    local source_checksum_file="$output_dir/source.checksum"
    if [ -f "$source_checksum_file" ]; then
        local existing_checksum
        existing_checksum=$(cat "$source_checksum_file")
        if [ "$source_checksum" = "$existing_checksum" ]; then
            log_info "Source unchanged, skipping chunk creation"
            return 0
        fi
    fi
    
    # Clean old chunks
    rm -f "$output_dir"/${CHUNK_PREFIX}*.tar.gz
    rm -f "$output_dir/$CHECKSUM_FILE"
    
    # Create chunks in parallel
    if process_chunks_parallel "create" "$site_packages" "$output_dir" ""; then
        # Generate checksums
        generate_checksums "$output_dir" "$output_dir/$CHECKSUM_FILE"
        
        # Save source checksum
        echo "$source_checksum" > "$source_checksum_file"
        
        log_info "Successfully created chunked site-packages"
        
        # Log statistics
        local chunk_count
        chunk_count=$(ls "$output_dir"/${CHUNK_PREFIX}*.tar.gz 2>/dev/null | wc -l)
        local total_size
        total_size=$(du -sh "$output_dir" | cut -f1)
        log_info "Created $chunk_count chunks, total size: $total_size"
        
        return 0
    else
        log_error "Failed to create chunks"
        return 1
    fi
}

restore_site_packages() {
    local chunk_dir="$1"
    local venv_path="$2"
    
    # Try to find the site-packages directory in different possible locations
    local site_packages=""
    local possible_paths=(
        "$venv_path/lib/python${PYTHON_VERSION}/site-packages"
        "$venv_path/comfyui/lib/python${PYTHON_VERSION}/site-packages"
        "$venv_path/*/lib/python${PYTHON_VERSION}/site-packages"
    )
    
    for path in "${possible_paths[@]}"; do
        # Handle glob expansion for the wildcard path
        if [[ "$path" == *"*"* ]]; then
            for expanded_path in $path; do
                if [ -d "$(dirname "$expanded_path")" ]; then
                    site_packages="$expanded_path"
                    break 2
                fi
            done
        elif [ -d "$(dirname "$path")" ]; then
            site_packages="$path"
            break
        fi
    done
    
    # If we still don't have a valid path, create the most likely one
    if [ -z "$site_packages" ]; then
        # Check if comfyui subdirectory exists
        if [ -d "$venv_path/comfyui" ]; then
            site_packages="$venv_path/comfyui/lib/python${PYTHON_VERSION}/site-packages"
        else
            site_packages="$venv_path/lib/python${PYTHON_VERSION}/site-packages"
        fi
    fi
    
    log_info "Target site-packages: $site_packages"
    log_info "Starting chunked restoration to: $site_packages"
    log_info "Source directory: $chunk_dir"
    
    # Verify chunks exist
    if ! ls "$chunk_dir"/${CHUNK_PREFIX}*.tar.gz >/dev/null 2>&1; then
        log_error "No chunk files found in: $chunk_dir"
        return 1
    fi
    
    # Verify checksums if available
    if [ -f "$chunk_dir/$CHECKSUM_FILE" ]; then
        if ! verify_checksums "$chunk_dir" "$chunk_dir/$CHECKSUM_FILE"; then
            log_error "Chunk verification failed"
            return 1
        fi
    else
        log_info "No checksum file found, skipping verification"
    fi
    
    # Create target directory
    mkdir -p "$site_packages"
    
    # Extract chunks in parallel
    if process_chunks_parallel "extract" "$chunk_dir" "$site_packages" ""; then
        log_info "Successfully restored chunked site-packages"
        
        # Log statistics
        local chunk_count
        chunk_count=$(ls "$chunk_dir"/${CHUNK_PREFIX}*.tar.gz 2>/dev/null | wc -l)
        log_info "Restored $chunk_count chunks to: $site_packages"
        
        return 0
    else
        log_error "Failed to restore chunks"
        return 1
    fi
}

# Upload chunks to cloud storage
upload_chunks() {
    local chunk_dir="$1"
    local s3_path="$2"
    
    log_info "Uploading chunks to: $s3_path"
    
    # Upload chunks in parallel
    local pids=()
    local max_jobs=$VENV_MAX_PARALLEL
    local job_count=0
    
    # Upload chunk files
    for chunk_file in "$chunk_dir"/${CHUNK_PREFIX}*.tar.gz; do
        if [ ! -f "$chunk_file" ]; then
            continue
        fi
        
        # Wait if we've reached max parallel jobs
        while [ $job_count -ge $max_jobs ]; do
            if [ ${#pids[@]} -gt 0 ]; then
                for i in "${!pids[@]}"; do
                    if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                        wait "${pids[$i]}" 2>/dev/null || true
                        unset 'pids[i]'
                        job_count=$((job_count - 1))
                    fi
                done
            fi
            sleep 0.1
        done
        
        # Start upload in background
        (
            local filename
            filename=$(basename "$chunk_file")
            if aws s3 cp "$chunk_file" "$s3_path/$filename" --only-show-errors; then
                log_info "Uploaded: $filename"
            else
                log_error "Failed to upload: $filename"
                exit 1
            fi
        ) &
        pids+=($!)
        job_count=$((job_count + 1))
    done
    
    # Wait for all uploads
    if [ ${#pids[@]} -gt 0 ]; then
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                wait "$pid" || {
                    log_error "Upload job failed: $pid"
                    return 1
                }
            fi
        done
    fi
    
    # Upload checksum file
    if [ -f "$chunk_dir/$CHECKSUM_FILE" ]; then
        if aws s3 cp "$chunk_dir/$CHECKSUM_FILE" "$s3_path/$CHECKSUM_FILE" --only-show-errors; then
            log_info "Uploaded checksum file"
        else
            log_error "Failed to upload checksum file"
            return 1
        fi
    fi
    
    # Upload source checksum
    if [ -f "$chunk_dir/source.checksum" ]; then
        if aws s3 cp "$chunk_dir/source.checksum" "$s3_path/source.checksum" --only-show-errors; then
            log_info "Uploaded source checksum"
        else
            log_error "Failed to upload source checksum"
            return 1
        fi
    fi
    
    log_info "Successfully uploaded all chunks"
}

# Download chunks from cloud storage
download_chunks() {
    local s3_path="$1"
    local chunk_dir="$2"
    
    log_info "Downloading chunks from: $s3_path"
    
    mkdir -p "$chunk_dir"
    
    # List and download chunk files
    local chunk_files
    chunk_files=$(aws s3 ls "$s3_path/" | grep "${CHUNK_PREFIX}.*\.tar\.gz$" | awk '{print $4}' || true)
    
    if [ -z "$chunk_files" ]; then
        log_error "No chunk files found at: $s3_path"
        return 1
    fi
    
    # Download in parallel
    local pids=()
    local max_jobs=$VENV_MAX_PARALLEL
    local job_count=0
    
    # Use a temporary file to avoid pipeline issues
    local temp_file_list
    temp_file_list=$(mktemp)
    echo "$chunk_files" > "$temp_file_list"
    
    while IFS= read -r filename; do
        if [ -z "$filename" ]; then
            continue
        fi
        
        # Wait if we've reached max parallel jobs
        while [ $job_count -ge $max_jobs ]; do
            if [ ${#pids[@]} -gt 0 ]; then
                for i in "${!pids[@]}"; do
                    if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                        wait "${pids[$i]}" 2>/dev/null || true
                        unset 'pids[i]'
                        job_count=$((job_count - 1))
                    fi
                done
            fi
            sleep 0.1
        done
        
        # Start download in background
        (
            if aws s3 cp "$s3_path/$filename" "$chunk_dir/$filename" --only-show-errors; then
                log_info "Downloaded: $filename"
            else
                log_error "Failed to download: $filename"
                exit 1
            fi
        ) &
        pids+=($!)
        job_count=$((job_count + 1))
    done < "$temp_file_list"
    
    # Clean up temp file
    rm -f "$temp_file_list"
    
    # Wait for all downloads
    if [ ${#pids[@]} -gt 0 ]; then
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                wait "$pid" || {
                    log_error "Download job failed: $pid"
                    return 1
                }
            fi
        done
    fi
    
    # Download checksum file
    if aws s3 cp "$s3_path/$CHECKSUM_FILE" "$chunk_dir/$CHECKSUM_FILE" --only-show-errors 2>/dev/null; then
        log_info "Downloaded checksum file"
    else
        log_info "No checksum file found (optional)"
    fi
    
    # Download source checksum
    if aws s3 cp "$s3_path/source.checksum" "$chunk_dir/source.checksum" --only-show-errors 2>/dev/null; then
        log_info "Downloaded source checksum"
    else
        log_info "No source checksum found (optional)"
    fi
    
    log_info "Successfully downloaded all chunks"
}

# High-level wrapper functions for common operations
chunk_and_upload_venv() {
    local venv_path="$1"
    local s3_path="$2"
    local sync_type="${3:-venv_sync}"
    
    log_info "Starting chunked venv upload: $venv_path -> $s3_path"
    
    # Create temporary directory for chunks
    local temp_chunks_dir
    temp_chunks_dir=$(mktemp -d)
    
    # Chunk the venv
    if chunk_site_packages "$venv_path" "$temp_chunks_dir"; then
        log_info "Venv chunking successful, uploading to S3..."
        
        # Upload chunks
        if upload_chunks "$temp_chunks_dir" "$s3_path"; then
            log_info "Successfully uploaded chunked venv"
            # Clean up temporary chunks
            rm -rf "$temp_chunks_dir"
            return 0
        else
            log_error "Failed to upload chunks"
            rm -rf "$temp_chunks_dir"
            return 1
        fi
    else
        log_error "Failed to chunk venv"
        rm -rf "$temp_chunks_dir"
        return 1
    fi
}

download_and_reassemble_venv() {
    local s3_path="$1"
    local venv_path="$2"
    
    log_info "Starting chunked venv download: $s3_path -> $venv_path"
    
    # Create temporary directory for chunks
    local temp_chunks_dir
    temp_chunks_dir=$(mktemp -d)
    
    # Download chunks
    if download_chunks "$s3_path" "$temp_chunks_dir"; then
        log_info "Chunks downloaded successfully, reassembling venv..."
        
        # Restore the venv from chunks
        if restore_site_packages "$temp_chunks_dir" "$venv_path"; then
            log_info "Successfully reassembled venv from chunks"
            # Clean up temporary chunks
            rm -rf "$temp_chunks_dir"
            return 0
        else
            log_error "Failed to reassemble venv from chunks"
            rm -rf "$temp_chunks_dir"
            return 1
        fi
    else
        log_error "Failed to download chunks"
        rm -rf "$temp_chunks_dir"
        return 1
    fi
}

# Main command interface
main() {
    local command="$1"
    shift
    
    if ! check_dependencies; then
        log_error "Dependency check failed"
        exit 1
    fi
    
    case "$command" in
        "chunk")
            if [ $# -ne 2 ]; then
                log_error "Usage: $0 chunk <venv_path> <output_dir>"
                exit 1
            fi
            chunk_site_packages "$1" "$2"
            ;;
            
        "restore")
            if [ $# -ne 2 ]; then
                log_error "Usage: $0 restore <chunk_dir> <venv_path>"
                exit 1
            fi
            restore_site_packages "$1" "$2"
            ;;
            
        "upload")
            if [ $# -ne 2 ]; then
                log_error "Usage: $0 upload <chunk_dir> <s3_path>"
                exit 1
            fi
            upload_chunks "$1" "$2"
            ;;
            
        "download")
            if [ $# -ne 2 ]; then
                log_error "Usage: $0 download <s3_path> <chunk_dir>"
                exit 1
            fi
            download_chunks "$1" "$2"
            ;;
            
        "verify")
            if [ $# -ne 2 ]; then
                log_error "Usage: $0 verify <chunk_dir> <checksum_file>"
                exit 1
            fi
            verify_checksums "$1" "$2"
            ;;
            
        *)
            echo "Usage: $0 {chunk|restore|upload|download|verify} [args...]"
            echo ""
            echo "Commands:"
            echo "  chunk <venv_path> <output_dir>     - Create chunks from venv site-packages"
            echo "  restore <chunk_dir> <venv_path>    - Restore chunks to venv site-packages"
            echo "  upload <chunk_dir> <s3_path>       - Upload chunks to S3"
            echo "  download <s3_path> <chunk_dir>     - Download chunks from S3"
            echo "  verify <chunk_dir> <checksum_file> - Verify chunk integrity"
            echo ""
            echo "Environment variables:"
            echo "  VENV_CHUNK_SIZE_MB     - Chunk size in MB (default: 100)"
            echo "  VENV_MAX_PARALLEL      - Max parallel operations (default: 4)"
            echo "  VENV_COMPRESSION_LEVEL - Compression level 1-9 (default: 6)"
            echo "  VENV_LOG_FILE          - Log file path (default: /network_volume/.venv_chunk_manager.log)"
            exit 1
            ;;
    esac
}

# Run main function if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
EOF

chmod +x "$NETWORK_VOLUME/scripts/venv_chunk_manager.sh"

echo "✅ Venv chunk manager script created at $NETWORK_VOLUME/scripts/venv_chunk_manager.sh"
