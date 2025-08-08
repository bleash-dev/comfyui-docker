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
VENV_OTHER_ZIP="venv_other_folders.zip"

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

# Source API client for progress notifications if available and not already sourced
if [ -f "$NETWORK_VOLUME/scripts/api_client.sh" ] && ! command -v notify_sync_progress >/dev/null 2>&1; then
    source "$NETWORK_VOLUME/scripts/api_client.sh" 2>/dev/null || true
fi

# Source S3 interactor for cloud storage operations
if [ -f "$NETWORK_VOLUME/scripts/s3_interactor.sh" ]; then
    source "$NETWORK_VOLUME/scripts/s3_interactor.sh" 2>/dev/null || true
fi

# Fallback notification function if API client is not available
if ! command -v notify_sync_progress >/dev/null 2>&1; then
    notify_sync_progress() {
        local sync_type="$1"
        local status="$2"
        local percentage="$3"
        log_info "Progress notification: $sync_type $status $percentage%"
    }
fi

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
    
    for cmd in tar gzip split cat awk zip unzip; do
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

# Generate chunk list from lib directory only with improved bin packing
generate_chunk_list() {
    local venv_path="$1"
    local chunk_size_bytes=$((VENV_CHUNK_SIZE_MB * 1024 * 1024))
    local current_chunk=1
    local current_size=0
    local chunk_file
    
    # Look for lib directories in venv (lib and lib64)
    local lib_dirs=()
    if [ -d "$venv_path/lib" ]; then
        lib_dirs+=("$venv_path/lib")
    fi
    if [ -d "$venv_path/lib64" ]; then
        lib_dirs+=("$venv_path/lib64")
    fi
    
    if [ ${#lib_dirs[@]} -eq 0 ]; then
        log_error "No lib or lib64 directories found in venv: $venv_path"
        return 1
    fi
    
    log_info "Generating chunk list for lib directories: ${lib_dirs[*]}"
    
    # Create temporary directory for chunk lists
    local TEMP_DIR
    TEMP_DIR=$(mktemp -d)
    chunk_file="$TEMP_DIR/chunk_${current_chunk}.list"
    
    # Find all files in lib directories and sort by size (largest first for better packing)
    local temp_file_list temp_file_sizes
    temp_file_list=$(mktemp)
    temp_file_sizes=$(mktemp)
    
    # Find files in all lib directories and get their sizes
    for lib_dir in "${lib_dirs[@]}"; do
        find "$lib_dir" -type f -exec stat -c"%s %n" {} \; 2>/dev/null
        find "$lib_dir" -type f -exec stat -f"%z %N" {} \; 2>/dev/null
    done > "$temp_file_sizes"
    
    # Sort files by size (largest first) for better bin packing
    sort -rn "$temp_file_sizes" > "$temp_file_list"
    
    local large_files_warned=false
    
    while IFS=' ' read -r file_size file_path; do
        if [ ! -e "$file_path" ]; then
            continue
        fi
        
        # Warn about extremely large files (more than 2x chunk size)
        if [ "$file_size" -gt $((chunk_size_bytes * 2)) ] && [ "$large_files_warned" = false ]; then
            log_info "Warning: Found files larger than 2x chunk size ($(($file_size / 1024 / 1024))MB). Consider increasing VENV_CHUNK_SIZE_MB."
            large_files_warned=true
        fi
        
        # If this file alone exceeds chunk size, put it in its own chunk
        if [ "$file_size" -gt "$chunk_size_bytes" ]; then
            # If current chunk has files, close it first
            if [ "$current_size" -gt 0 ]; then
                current_chunk=$((current_chunk + 1))
                chunk_file="$TEMP_DIR/chunk_${current_chunk}.list"
                current_size=0
            fi
            
            # Add the large file to its own chunk
            echo "$file_path" >> "$chunk_file"
            log_info "Large file ($(($file_size / 1024 / 1024))MB) assigned to chunk $current_chunk: $(basename "$file_path")"
            
            # Start next chunk
            current_chunk=$((current_chunk + 1))
            chunk_file="$TEMP_DIR/chunk_${current_chunk}.list"
            current_size=0
            continue
        fi
        
        # If adding this file would exceed chunk size, start a new chunk
        if [ $((current_size + file_size)) -gt $chunk_size_bytes ] && [ $current_size -gt 0 ]; then
            current_chunk=$((current_chunk + 1))
            chunk_file="$TEMP_DIR/chunk_${current_chunk}.list"
            current_size=0
        fi
        
        echo "$file_path" >> "$chunk_file"
        current_size=$((current_size + file_size))
    done < "$temp_file_list"
    
    # Clean up temp files
    rm -f "$temp_file_list" "$temp_file_sizes"
    
    # Output the temporary directory path
    echo "$TEMP_DIR"
}

# Create zip archive of non-lib folders
create_other_folders_zip() {
    local venv_path="$1"
    local output_file="$2"
    
    if [ ! -d "$venv_path" ]; then
        log_error "Venv directory not found: $venv_path"
        return 1
    fi
    
    log_info "Creating zip of non-lib folders: $output_file"
    
    # Create a temporary list of all items to include (everything except lib)
    local temp_include_list
    temp_include_list=$(mktemp)
    
    # List all items in venv_path, exclude lib and lib64 directories
    for item in "$venv_path"/*; do
        if [ -e "$item" ]; then
            local basename_item
            basename_item=$(basename "$item")
            if [ "$basename_item" != "lib" ] && [ "$basename_item" != "lib64" ]; then
                echo "$basename_item" >> "$temp_include_list"
                log_info "Including in zip: $basename_item"
            else
                log_info "Excluding from zip: $basename_item (will be chunked separately)"
            fi
        fi
    done
    
    # Check if we have anything to zip
    if [ ! -s "$temp_include_list" ]; then
        log_info "No non-lib folders found to zip"
        rm -f "$temp_include_list"
        # Create empty zip file for consistency
        echo | zip -q "$output_file" -
        return 0
    fi
    
    # Create zip archive of all non-lib items
    if command -v zip >/dev/null 2>&1; then
        # Convert output_file to absolute path before changing directory
        local abs_output_file
        if [[ "$output_file" = /* ]]; then
            abs_output_file="$output_file"
        else
            abs_output_file="$(pwd)/$output_file"
        fi
        
        cd "$venv_path" || return 1
        # Use -@ option to read file list from stdin, which is safer
        zip -r "$abs_output_file" -@ < "$temp_include_list" >/dev/null 2>&1
        local zip_result=$?
        cd - >/dev/null
        
        if [ $zip_result -eq 0 ]; then
            log_info "Successfully created other folders zip: $abs_output_file ($(du -h "$abs_output_file" | cut -f1))"
        else
            log_error "Failed to create zip archive"
            rm -f "$temp_include_list"
            return 1
        fi
    else
        log_error "zip command not found"
        rm -f "$temp_include_list"
        return 1
    fi
    
    rm -f "$temp_include_list"
    return 0
}

# Extract other folders zip
extract_other_folders_zip() {
    local zip_file="$1"
    local dest_dir="$2"
    
    if [ ! -f "$zip_file" ]; then
        log_error "Zip file not found: $zip_file"
        return 1
    fi
    
    # Check if zip file is empty (just contains empty entry)
    if [ ! -s "$zip_file" ]; then
        log_info "Empty zip file, no other folders to extract"
        return 0
    fi
    
    log_info "Extracting other folders zip: $zip_file to $dest_dir"
    
    mkdir -p "$dest_dir"
    
    # Extract zip file
    if command -v unzip >/dev/null 2>&1; then
        if unzip -q "$zip_file" -d "$dest_dir" 2>/dev/null; then
            log_info "Successfully extracted other folders zip"
            
            # Restore executable permissions for bin directory files
            if [ -d "$dest_dir/bin" ]; then
                log_info "Restoring executable permissions for bin directory"
                chmod +x "$dest_dir/bin"/* 2>/dev/null || true
            fi
            
            return 0
        else
            # Check if it's an empty zip (common case)
            local zip_entries
            zip_entries=$(unzip -l "$zip_file" 2>/dev/null | wc -l)
            if [ "$zip_entries" -le 3 ]; then  # Header + footer only
                log_info "Empty zip file, no other folders to extract"
                return 0
            else
                log_error "Failed to extract zip archive"
                return 1
            fi
        fi
    else
        log_error "unzip command not found"
        return 1
    fi
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
    
    # Check if chunk file is empty (common S3 download issue)
    if [ ! -s "$chunk_file" ]; then
        log_error "Chunk file is empty (possible download failure): $chunk_file"
        return 1
    fi
    
    # Check if chunk file is a valid gzip file
    if ! gzip -t "$chunk_file" 2>/dev/null; then
        log_error "Chunk file is not a valid gzip archive: $chunk_file"
        local file_size=$(stat -c%s "$chunk_file" 2>/dev/null || stat -f%z "$chunk_file" 2>/dev/null || echo "unknown")
        log_error "File size: $file_size bytes"
        # Show first few bytes for debugging
        if command -v hexdump >/dev/null 2>&1; then
            log_error "First 32 bytes: $(hexdump -C "$chunk_file" | head -2 || echo "unable to read")"
        fi
        return 1
    fi
    
    log_info "Extracting chunk: $chunk_file to $dest_dir"
    
    mkdir -p "$dest_dir"
    
    # Capture tar output for better error reporting
    local tar_output
    local tar_exit_code
    tar_output=$(tar -xzf "$chunk_file" -C "$dest_dir" 2>&1)
    tar_exit_code=$?
    
    if [ $tar_exit_code -eq 0 ]; then
        log_info "Successfully extracted: $chunk_file"
        return 0
    else
        log_error "Failed to extract chunk: $chunk_file (exit code: $tar_exit_code)"
        if [ -n "$tar_output" ]; then
            log_error "Tar error output: $tar_output"
        fi
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
            
            # Process lib directory chunks
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
            
            # Create zip of other folders
            local other_zip_file="$dest_dir/$VENV_OTHER_ZIP"
            create_other_folders_zip "$source_dir" "$other_zip_file" &
            pids+=($!)
            job_count=$((job_count + 1))
            ;;
            
        "extract")
            # Extract lib directory chunks
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
            
            # Extract other folders zip if it exists
            local other_zip_file="$source_dir/$VENV_OTHER_ZIP"
            if [ -f "$other_zip_file" ]; then
                # Wait for a slot
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
                
                extract_other_folders_zip "$other_zip_file" "$dest_dir" &
                pids+=($!)
                job_count=$((job_count + 1))
            fi
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

# Generate checksums for chunks and other folders zip
generate_checksums() {
    local chunk_dir="$1"
    local checksum_file="$2"
    
    log_info "Generating checksums for chunks and other folders in: $chunk_dir"
    
    > "$checksum_file"  # Clear file
    
    # Checksum chunk files
    for chunk_file in "$chunk_dir"/${CHUNK_PREFIX}*.tar.gz; do
        if [ -f "$chunk_file" ]; then
            local checksum
            checksum=$(sha256sum "$chunk_file" | cut -d' ' -f1)
            echo "$checksum $(basename "$chunk_file")" >> "$checksum_file"
        fi
    done
    
    # Checksum other folders zip
    local other_zip="$chunk_dir/$VENV_OTHER_ZIP"
    if [ -f "$other_zip" ]; then
        local checksum
        checksum=$(sha256sum "$other_zip" | cut -d' ' -f1)
        echo "$checksum $(basename "$other_zip")" >> "$checksum_file"
    fi
    
    log_info "Generated checksums: $checksum_file"
}

# Verify chunks and other folders zip against checksums
verify_checksums() {
    local chunk_dir="$1"
    local checksum_file="$2"
    
    if [ ! -f "$checksum_file" ]; then
        log_error "Checksum file not found: $checksum_file"
        return 1
    fi
    
    log_info "Verifying chunks and other folders against checksums"
    
    local failed_count=0
    
    while IFS= read -r line; do
        local expected_checksum
        local file_name
        expected_checksum=$(echo "$line" | cut -d' ' -f1)
        file_name=$(echo "$line" | cut -d' ' -f2-)
        
        local file_path="$chunk_dir/$file_name"
        
        if [ ! -f "$file_path" ]; then
            log_error "Missing file: $file_path"
            failed_count=$((failed_count + 1))
            continue
        fi
        
        local actual_checksum
        actual_checksum=$(sha256sum "$file_path" | cut -d' ' -f1)
        
        if [ "$expected_checksum" != "$actual_checksum" ]; then
            log_error "Checksum mismatch for $file_path"
            log_error "Expected: $expected_checksum"
            log_error "Actual: $actual_checksum"
            failed_count=$((failed_count + 1))
        fi
    done < "$checksum_file"
    
    if [ $failed_count -eq 0 ]; then
        log_info "All checksums verified successfully"
        return 0
    else
        log_error "Checksum verification failed for $failed_count files"
        return 1
    fi
}



# Main functions
chunk_venv() {
    local venv_path="$1"
    local output_dir="$2"
    
    if [ ! -d "$venv_path" ]; then
        log_error "Venv directory not found: $venv_path"
        return 1
    fi
    
    log_info "Starting chunked compression of venv lib directory and zipping other folders: $venv_path"
    log_info "Output directory: $output_dir"
    log_info "Chunk size: ${VENV_CHUNK_SIZE_MB}MB, Parallel jobs: $VENV_MAX_PARALLEL"
    
    mkdir -p "$output_dir"
    
    # Calculate source checksum for change detection (entire venv)
    local source_checksum
    source_checksum=$(calculate_directory_checksum "$venv_path")
    
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
    
    # Clean old chunks and zip files
    rm -f "$output_dir"/${CHUNK_PREFIX}*.tar.gz
    rm -f "$output_dir/$CHECKSUM_FILE"
    rm -f "$output_dir/$VENV_OTHER_ZIP"
    
    # Create chunks from lib directory and zip other folders in parallel
    if process_chunks_parallel "create" "$venv_path" "$output_dir" ""; then
        # Generate checksums for both chunks and other zip
        generate_checksums "$output_dir" "$output_dir/$CHECKSUM_FILE"
        
        # Save source checksum
        echo "$source_checksum" > "$source_checksum_file"
        
        log_info "Successfully created chunked venv (lib directory) and other folders zip"
        
        # Log statistics
        local chunk_count
        chunk_count=$(ls "$output_dir"/${CHUNK_PREFIX}*.tar.gz 2>/dev/null | wc -l)
        local total_size
        total_size=$(du -sh "$output_dir" | cut -f1)
        local other_zip_size=""
        if [ -f "$output_dir/$VENV_OTHER_ZIP" ]; then
            other_zip_size=" (Other folders zip: $(du -h "$output_dir/$VENV_OTHER_ZIP" | cut -f1))"
        fi
        log_info "Created $chunk_count lib chunks, total size: $total_size$other_zip_size"
        
        return 0
    else
        log_error "Failed to create chunks and zip"
        return 1
    fi
}

# Legacy function name for backward compatibility - now chunks lib directory and zips other folders
chunk_site_packages() {
    local venv_path="$1"
    local output_dir="$2"
    
    log_info "Note: chunk_site_packages now chunks lib directory and zips other folders"
    chunk_venv "$venv_path" "$output_dir"
}

restore_venv() {
    local chunk_dir="$1"
    local venv_path="$2"
    
    log_info "Starting restoration of venv from lib chunks and other folders zip to: $venv_path"
    log_info "Source directory: $chunk_dir"
    
    # Verify chunks exist
    if ! ls "$chunk_dir"/${CHUNK_PREFIX}*.tar.gz >/dev/null 2>&1; then
        log_error "No chunk files found in: $chunk_dir"
        return 1
    fi
    
    #  Verify checksums if available
    # if [ -f "$chunk_dir/$CHECKSUM_FILE" ]; then
    #     if ! verify_checksums "$chunk_dir" "$chunk_dir/$CHECKSUM_FILE"; then
    #         log_error "Chunk verification failed"
    #         return 1
    #     fi
    # else
    #     log_info "No checksum file found, skipping verification"
    # fi
    
    # Create target directory
    mkdir -p "$venv_path"
    
    # Extract chunks (lib directory) and other folders zip in parallel
    if process_chunks_parallel "extract" "$chunk_dir" "$venv_path" ""; then
        log_info "Successfully restored venv from chunks and other folders zip"
        
        # Log statistics
        local chunk_count
        chunk_count=$(ls "$chunk_dir"/${CHUNK_PREFIX}*.tar.gz 2>/dev/null | wc -l)
        local other_zip_info=""
        if [ -f "$chunk_dir/$VENV_OTHER_ZIP" ]; then
            other_zip_info=" and other folders zip"
        fi
        log_info "Restored $chunk_count lib chunks$other_zip_info to: $venv_path"
        
        # Make sure executables are executable
        if [ -d "$venv_path/bin" ]; then
            chmod +x "$venv_path/bin"/* 2>/dev/null || true
        fi
        
        return 0
    else
        log_error "Failed to restore chunks and other folders"
        return 1
    fi
}

# Legacy function name for backward compatibility - now restores lib directory and other folders
restore_site_packages() {
    local chunk_dir="$1"
    local venv_path="$2"
    
    log_info "Note: restore_site_packages now restores lib directory and other folders"
    restore_venv "$chunk_dir" "$venv_path"
}

# Upload chunks and other folders zip to cloud storage
upload_chunks() {
    local chunk_dir="$1"
    local s3_path="$2"
    local sync_type="${3:-venv_sync}"
    
    log_info "Uploading chunks and other folders zip to: $s3_path"
    
    # Count total chunks
    local total_chunks=0
    for chunk_file in "$chunk_dir"/${CHUNK_PREFIX}*.tar.gz; do
        if [ -f "$chunk_file" ]; then
            total_chunks=$((total_chunks + 1))
        fi
    done
    
    # Count other folders zip if exists
    local has_other_zip=0
    if [ -f "$chunk_dir/$VENV_OTHER_ZIP" ]; then
        has_other_zip=1
    fi
    
    local total_files=$((total_chunks + has_other_zip))
    
    if [ "$total_files" -eq 0 ]; then
        log_error "No chunk files or other folders zip found in: $chunk_dir"
        return 1
    fi
    
    log_info "Uploading $total_chunks chunks and $has_other_zip other folders zip..."
    
    # Notify start of upload if this is user_shared type
    if [ "$sync_type" = "user_shared" ]; then
        notify_sync_progress "user_shared" "PROGRESS" 0
    fi
    
    # Upload chunks and other zip in parallel
    local pids=()
    local max_jobs=$VENV_MAX_PARALLEL
    local job_count=0
    local completed_files=0
    
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
                        completed_files=$((completed_files + 1))
                        
                        # Update progress for user_shared uploads
                        if [ "$sync_type" = "user_shared" ]; then
                            local progress=$((completed_files * 80 / total_files))
                            notify_sync_progress "user_shared" "PROGRESS" "$progress"
                        fi
                    fi
                done
            fi
            sleep 0.1
        done
        
        # Start upload in background
        (
            local filename
            filename=$(basename "$chunk_file")
            if s3_copy_to "$chunk_file" "$s3_path/$filename" "--only-show-errors"; then
                log_info "Uploaded: $filename"
            else
                log_error "Failed to upload: $filename"
                exit 1
            fi
        ) &
        pids+=($!)
        job_count=$((job_count + 1))
    done
    
    # Upload other folders zip if it exists
    if [ -f "$chunk_dir/$VENV_OTHER_ZIP" ]; then
        # Wait if we've reached max parallel jobs
        while [ $job_count -ge $max_jobs ]; do
            if [ ${#pids[@]} -gt 0 ]; then
                for i in "${!pids[@]}"; do
                    if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                        wait "${pids[$i]}" 2>/dev/null || true
                        unset 'pids[i]'
                        job_count=$((job_count - 1))
                        completed_files=$((completed_files + 1))
                        
                        # Update progress for user_shared uploads
                        if [ "$sync_type" = "user_shared" ]; then
                            local progress=$((completed_files * 80 / total_files))
                            notify_sync_progress "user_shared" "PROGRESS" "$progress"
                        fi
                    fi
                done
            fi
            sleep 0.1
        done
        
        # Start upload in background
        (
            if s3_copy_to "$chunk_dir/$VENV_OTHER_ZIP" "$s3_path/$VENV_OTHER_ZIP" "--only-show-errors"; then
                log_info "Uploaded: $VENV_OTHER_ZIP"
            else
                log_error "Failed to upload: $VENV_OTHER_ZIP"
                exit 1
            fi
        ) &
        pids+=($!)
        job_count=$((job_count + 1))
    fi
    
    # Wait for all uploads and update progress
    if [ ${#pids[@]} -gt 0 ]; then
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                wait "$pid" || {
                    log_error "Upload job failed: $pid"
                    return 1
                }
                completed_files=$((completed_files + 1))
                
                # Update progress for user_shared uploads
                if [ "$sync_type" = "user_shared" ]; then
                    local progress=$((completed_files * 80 / total_files))
                    notify_sync_progress "user_shared" "PROGRESS" "$progress"
                fi
            fi
        done
    fi
    
    # Upload checksum file
    if [ -f "$chunk_dir/$CHECKSUM_FILE" ]; then
        if s3_copy_to "$chunk_dir/$CHECKSUM_FILE" "$s3_path/$CHECKSUM_FILE" "--only-show-errors"; then
            log_info "Uploaded checksum file"
        else
            log_error "Failed to upload checksum file"
            return 1
        fi
    fi
    
    # Upload source checksum
    if [ -f "$chunk_dir/source.checksum" ]; then
        if s3_copy_to "$chunk_dir/source.checksum" "$s3_path/source.checksum" "--only-show-errors"; then
            log_info "Uploaded source checksum"
        else
            log_error "Failed to upload source checksum"
            return 1
        fi
    fi
    
    # Notify completion for user_shared uploads
    if [ "$sync_type" = "user_shared" ]; then
        notify_sync_progress "user_shared" "DONE" 100
    fi
    
    log_info "Successfully uploaded all chunks and other folders zip"
}

# Download chunks and other folders zip from cloud storage
download_chunks() {
    local s3_path="$1"
    local chunk_dir="$2"
    
    log_info "Downloading chunks and other folders zip from: $s3_path"
    
    mkdir -p "$chunk_dir"
    
    # List and download chunk files
    local chunk_files
    chunk_files=$(s3_list "$s3_path/" | grep "${CHUNK_PREFIX}.*\.tar\.gz$" | awk '{print $4}' || true)
    
    if [ -z "$chunk_files" ]; then
        log_error "No chunk files found at: $s3_path"
        return 1
    fi
    
    # Download in parallel
    local pids=()
    local max_jobs=$VENV_MAX_PARALLEL
    local job_count=0
    local download_failures=0
    
    # Use a temporary file to avoid pipeline issues
    local temp_file_list
    temp_file_list=$(mktemp)
    echo "$chunk_files" > "$temp_file_list"
    
    # Download chunk files
    while IFS= read -r filename; do
        if [ -z "$filename" ]; then
            continue
        fi
        
        # Wait if we've reached max parallel jobs
        while [ $job_count -ge $max_jobs ]; do
            if [ ${#pids[@]} -gt 0 ]; then
                for i in "${!pids[@]}"; do
                    if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                        wait "${pids[$i]}" 2>/dev/null || download_failures=$((download_failures + 1))
                        unset 'pids[i]'
                        job_count=$((job_count - 1))
                    fi
                done
            fi
            sleep 0.1
        done
        
        # Start download in background
        (
            local target_file="$chunk_dir/$filename"
            if s3_copy_from "$s3_path/$filename" "$target_file" "--only-show-errors"; then
                # Verify downloaded file is not empty and is valid
                if [ ! -s "$target_file" ]; then
                    log_error "Downloaded chunk is empty: $filename"
                    exit 1
                elif ! gzip -t "$target_file" 2>/dev/null; then
                    log_error "Downloaded chunk is not valid gzip: $filename"
                    local file_size=$(stat -c%s "$target_file" 2>/dev/null || stat -f%z "$target_file" 2>/dev/null || echo "unknown")
                    log_error "File size: $file_size bytes"
                    exit 1
                else
                    log_info "Downloaded: $filename"
                fi
            else
                log_error "Failed to download: $filename"
                exit 1
            fi
        ) &
        pids+=($!)
        job_count=$((job_count + 1))
    done < "$temp_file_list"
    
    # Download other folders zip if available
    (
        # Wait for a slot
        while [ $job_count -ge $max_jobs ]; do
            if [ ${#pids[@]} -gt 0 ]; then
                for i in "${!pids[@]}"; do
                    if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                        wait "${pids[$i]}" 2>/dev/null || download_failures=$((download_failures + 1))
                        unset 'pids[i]'
                        job_count=$((job_count - 1))
                    fi
                done
            fi
            sleep 0.1
        done
        
        local target_zip="$chunk_dir/$VENV_OTHER_ZIP"
        if s3_copy_from "$s3_path/$VENV_OTHER_ZIP" "$target_zip" "--only-show-errors" 2>/dev/null; then
            log_info "Downloaded: $VENV_OTHER_ZIP"
        else
            log_info "No other folders zip found (optional)"
        fi
    ) &
    pids+=($!)
    job_count=$((job_count + 1))
    
    # Clean up temp file
    rm -f "$temp_file_list"
    
    # Wait for all downloads
    if [ ${#pids[@]} -gt 0 ]; then
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                wait "$pid" || download_failures=$((download_failures + 1))
            fi
        done
    fi
    
    # Check if we had any download failures
    if [ $download_failures -gt 0 ]; then
        log_error "Failed to download $download_failures files"
        return 1
    fi
    
    # Download checksum file
    if s3_copy_from "$s3_path/$CHECKSUM_FILE" "$chunk_dir/$CHECKSUM_FILE" "--only-show-errors" 2>/dev/null; then
        log_info "Downloaded checksum file"
    else
        log_info "No checksum file found (optional)"
    fi
    
    # Download source checksum
    if s3_copy_from "$s3_path/source.checksum" "$chunk_dir/source.checksum" "--only-show-errors" 2>/dev/null; then
        log_info "Downloaded source checksum"
    else
        log_info "No source checksum found (optional)"
    fi
    
    log_info "Successfully downloaded all chunks and other folders zip"
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
    if chunk_venv "$venv_path" "$temp_chunks_dir"; then
        log_info "Venv chunking successful, uploading to S3..."
        
        # Upload chunks
        if upload_chunks "$temp_chunks_dir" "$s3_path" "$sync_type"; then
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
        if restore_venv "$temp_chunks_dir" "$venv_path"; then
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
            chunk_venv "$1" "$2"
            ;;
            
        "restore")
            if [ $# -ne 2 ]; then
                log_error "Usage: $0 restore <chunk_dir> <venv_path>"
                exit 1
            fi
            restore_venv "$1" "$2"
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
            echo "  chunk <venv_path> <output_dir>     - Create chunks from lib directory and zip other folders"
            echo "  restore <chunk_dir> <venv_path>    - Restore chunks and other folders zip to venv"
            echo "  upload <chunk_dir> <s3_path>       - Upload chunks and other folders zip to S3"
            echo "  download <s3_path> <chunk_dir>     - Download chunks and other folders zip from S3"
            echo "  verify <chunk_dir> <checksum_file> - Verify chunk and zip file integrity"
            echo ""
            echo "Environment variables:"
            echo "  VENV_CHUNK_SIZE_MB     - Chunk size in MB (default: 100)"
            echo "  VENV_MAX_PARALLEL      - Max parallel operations (default: 4)"
            echo "  VENV_COMPRESSION_LEVEL - Compression level 1-9 (default: 6)"
            echo "  VENV_LOG_FILE          - Log file path (default: /network_volume/.venv_chunk_manager.log)"
            echo ""
            echo "Strategy:"
            echo "  - The lib directory is chunked into multiple compressed archives"
            echo "  - All other folders (bin, include, etc.) are zipped into a single archive"
            echo "  - This optimizes for the fact that lib contains most of the data"
            exit 1
            ;;
    esac
}

# Run main function if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi