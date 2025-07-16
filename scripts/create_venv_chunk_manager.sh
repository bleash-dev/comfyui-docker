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

# Source API client for progress notifications if available and not already sourced
if [ -f "$NETWORK_VOLUME/scripts/api_client.sh" ] && ! command -v notify_sync_progress >/dev/null 2>&1; then
    source "$NETWORK_VOLUME/scripts/api_client.sh" 2>/dev/null || true
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
    log_info "Creating archive for chunk with $(wc -l < "$chunk_list") files"

    # Create tar archive using a more robust approach
    local temp_relative_list
    temp_relative_list=$(mktemp)

    # Convert absolute paths to relative paths
    while IFS= read -r file; do
        if [ -e "$file" ]; then
            echo "${file#$base_dir/}"
        fi
    done < "$chunk_list" > "$temp_relative_list"

    if [ ! -s "$temp_relative_list" ]; then
        log_error "No valid files found for chunk: $chunk_list"
        rm -f "$temp_relative_list"
        return 1
    fi

    # Create the tar archive
    if tar -czf "$output_file" -C "$base_dir" --files-from="$temp_relative_list" 2>/dev/null; then
        rm -f "$temp_relative_list"
        log_info "Created chunk: $output_file ($(du -h "$output_file" | cut -f1))"
        return 0
    else
        log_error "Failed to create tar archive: $output_file"
        rm -f "$temp_relative_list"
        return 1
    fi
    
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

# Fix venv paths for cross-environment compatibility
fix_venv_paths() {
    local venv_path="$1"
    
    if [ ! -d "$venv_path" ]; then
        log_error "Venv path does not exist: $venv_path"
        return 1
    fi
    
    log_info "Fixing venv paths for cross-environment compatibility: $venv_path"
    
    # Find the current Python executable
    local current_python
    current_python=$(which python3 || which python || echo "/usr/bin/python3")
    
    # Ensure current_python exists and is executable
    if [ ! -x "$current_python" ]; then
        log_error "Cannot find a valid Python executable"
        return 1
    fi
    
    log_info "Using system Python: $current_python"
    
    # Get Python version info
    local python_version
    python_version=$("$current_python" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "unknown")
    log_info "System Python version: $python_version"
    
    # Fix pyvenv.cfg to point to current Python home
    if [ -f "$venv_path/pyvenv.cfg" ]; then
        log_info "Updating pyvenv.cfg"
        local python_home
        python_home=$(dirname "$(dirname "$current_python")")
        
        # Create a backup
        cp "$venv_path/pyvenv.cfg" "$venv_path/pyvenv.cfg.backup" 2>/dev/null || true
        
        # Update the home path in pyvenv.cfg
        if command -v sed >/dev/null 2>&1; then
            # Try different sed syntaxes for different systems
            sed -i.bak "s|^home = .*|home = $python_home/bin|g" "$venv_path/pyvenv.cfg" 2>/dev/null || \
            sed -i '' "s|^home = .*|home = $python_home/bin|g" "$venv_path/pyvenv.cfg" 2>/dev/null || {
                # Manual replacement if sed fails
                local temp_file
                temp_file=$(mktemp)
                awk -v new_home="$python_home/bin" '
                    /^home = / { print "home = " new_home; next }
                    { print }
                ' "$venv_path/pyvenv.cfg" > "$temp_file" && mv "$temp_file" "$venv_path/pyvenv.cfg"
            }
        else
            # Fallback without sed
            local temp_file
            temp_file=$(mktemp)
            awk -v new_home="$python_home/bin" '
                /^home = / { print "home = " new_home; next }
                { print }
            ' "$venv_path/pyvenv.cfg" > "$temp_file" && mv "$temp_file" "$venv_path/pyvenv.cfg"
        fi
        
        # Clean up backup files
        rm -f "$venv_path/pyvenv.cfg.bak" 2>/dev/null || true
        
        log_info "Updated pyvenv.cfg with Python home: $python_home/bin"
    else
        log_info "No pyvenv.cfg found, creating one"
        cat > "$venv_path/pyvenv.cfg" << EOF
home = $(dirname "$(dirname "$current_python")")/bin
include-system-site-packages = false
version = $python_version
EOF
    fi
    
    # Ensure bin directory exists
    mkdir -p "$venv_path/bin"
    
    # Fix shebang lines in bin/ scripts and ensure executability
    if [ -d "$venv_path/bin" ]; then
        log_info "Fixing shebang lines and permissions in venv executables"
        local venv_python="$venv_path/bin/python"
        
        for script in "$venv_path/bin"/*; do
            if [ -f "$script" ]; then
                # Make sure it's executable
                chmod +x "$script" 2>/dev/null || true
                
                # Check if it's a script with a shebang
                if head -1 "$script" 2>/dev/null | grep -q "^#!.*python"; then
                    # Replace the shebang to point to the venv's python
                    if command -v sed >/dev/null 2>&1; then
                        sed -i.bak "1s|^#!.*python.*|#!$venv_python|" "$script" 2>/dev/null || \
                        sed -i '' "1s|^#!.*python.*|#!$venv_python|" "$script" 2>/dev/null || {
                            # Manual replacement
                            local temp_file
                            temp_file=$(mktemp)
                            {
                                echo "#!$venv_python"
                                tail -n +2 "$script"
                            } > "$temp_file" && mv "$temp_file" "$script"
                            chmod +x "$script"
                        }
                        rm -f "$script.bak" 2>/dev/null || true
                    else
                        # Fallback without sed
                        local temp_file
                        temp_file=$(mktemp)
                        {
                            echo "#!$venv_python"
                            tail -n +2 "$script"
                        } > "$temp_file" && mv "$temp_file" "$script"
                        chmod +x "$script"
                    fi
                fi
            fi
        done
    fi
    
    # Recreate the python symlinks to ensure they point correctly
    if [ -f "$current_python" ]; then
        local venv_python_version
        venv_python_version=$(basename "$current_python")
        
        log_info "Creating Python symlinks for venv"
        
        # Remove old symlinks/files
        rm -f "$venv_path/bin/python" "$venv_path/bin/python3" 2>/dev/null || true
        
        # Create new symlinks
        ln -sf "$current_python" "$venv_path/bin/$venv_python_version" 2>/dev/null || {
            # If symlink fails, copy the executable
            cp "$current_python" "$venv_path/bin/$venv_python_version" 2>/dev/null || true
        }
        
        ln -sf "$venv_python_version" "$venv_path/bin/python3" 2>/dev/null || {
            ln -sf "$current_python" "$venv_path/bin/python3" 2>/dev/null || true
        }
        
        ln -sf "python3" "$venv_path/bin/python" 2>/dev/null || {
            ln -sf "$current_python" "$venv_path/bin/python" 2>/dev/null || true
        }
        
        # Ensure the symlinks are executable
        chmod +x "$venv_path/bin/python"* 2>/dev/null || true
        
        log_info "Updated venv Python symlinks to point to: $current_python"
        
        # Verify the symlinks work
        if [ -x "$venv_path/bin/python" ] && "$venv_path/bin/python" --version >/dev/null 2>&1; then
            log_info "Venv Python executable verified working"
        else
            log_error "Venv Python executable is not working after fix"
            return 1
        fi
    else
        log_error "System Python executable not found or not executable"
        return 1
    fi
    
    # Ensure site-packages directory has correct permissions
    if [ -d "$venv_path/lib" ]; then
        find "$venv_path/lib" -type d -exec chmod 755 {} \; 2>/dev/null || true
        find "$venv_path/lib" -type f -exec chmod 644 {} \; 2>/dev/null || true
    fi
    
    log_info "Venv path fixing completed successfully"
    return 0
}

# Main functions
chunk_venv() {
    local venv_path="$1"
    local output_dir="$2"
    
    if [ ! -d "$venv_path" ]; then
        log_error "Venv directory not found: $venv_path"
        return 1
    fi
    
    log_info "Starting chunked compression of entire venv: $venv_path"
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
    
    # Clean old chunks
    rm -f "$output_dir"/${CHUNK_PREFIX}*.tar.gz
    rm -f "$output_dir/$CHECKSUM_FILE"
    
    # Create chunks in parallel from entire venv
    if process_chunks_parallel "create" "$venv_path" "$output_dir" ""; then
        # Generate checksums
        generate_checksums "$output_dir" "$output_dir/$CHECKSUM_FILE"
        
        # Save source checksum
        echo "$source_checksum" > "$source_checksum_file"
        
        log_info "Successfully created chunked venv"
        
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

# Legacy function name for backward compatibility - now chunks entire venv
chunk_site_packages() {
    local venv_path="$1"
    local output_dir="$2"
    
    log_info "Note: chunk_site_packages now chunks entire venv for completeness"
    chunk_venv "$venv_path" "$output_dir"
}

restore_venv() {
    local chunk_dir="$1"
    local venv_path="$2"
    
    log_info "Starting chunked restoration of entire venv to: $venv_path"
    log_info "Source directory: $chunk_dir"
    
    # Verify chunks exist
    if ! ls "$chunk_dir"/${CHUNK_PREFIX}*.tar.gz >/dev/null 2>&1; then
        log_error "No chunk files found in: $chunk_dir"
        return 1
    fi
    
    # Count chunks for progress reporting
    local chunk_count
    chunk_count=$(ls "$chunk_dir"/${CHUNK_PREFIX}*.tar.gz 2>/dev/null | wc -l)
    log_info "Found $chunk_count chunk files to restore"
    
    # Verify checksums if available
    if [ -f "$chunk_dir/$CHECKSUM_FILE" ]; then
        log_info "Verifying chunk checksums before restoration..."
        if ! verify_checksums "$chunk_dir" "$chunk_dir/$CHECKSUM_FILE"; then
            log_error "Chunk verification failed"
            return 1
        fi
        log_info "All chunk checksums verified successfully"
    else
        log_info "No checksum file found, skipping verification"
    fi
    
    # Clean up existing venv if it exists and is corrupted
    if [ -d "$venv_path" ]; then
        log_info "Removing existing venv directory before restoration"
        rm -rf "$venv_path"
    fi
    
    # Create target directory
    mkdir -p "$venv_path"
    
    # Extract chunks in parallel to restore entire venv
    log_info "Extracting chunks in parallel..."
    if process_chunks_parallel "extract" "$chunk_dir" "$venv_path" ""; then
        log_info "Successfully extracted all chunks"
        
        # Log statistics
        log_info "Restored $chunk_count chunks to: $venv_path"
        
        # Check basic venv structure
        if [ ! -d "$venv_path/bin" ]; then
            log_error "Restored venv missing bin/ directory"
            return 1
        fi
        
        if [ ! -d "$venv_path/lib" ]; then
            log_error "Restored venv missing lib/ directory"
            return 1
        fi
        
        log_info "Basic venv structure verification passed"
        
        # Make sure executables are executable
        if [ -d "$venv_path/bin" ]; then
            log_info "Setting executable permissions on bin/ directory contents"
            chmod +x "$venv_path/bin"/* 2>/dev/null || true
        fi
        
        # Fix venv paths for cross-environment compatibility
        log_info "Applying cross-environment path fixes..."
        if fix_venv_paths "$venv_path"; then
            log_info "Venv path fixes applied successfully"
            
            # Final verification that the venv is functional
            if [ -f "$venv_path/bin/python" ] && "$venv_path/bin/python" --version >/dev/null 2>&1; then
                local python_version
                python_version=$("$venv_path/bin/python" --version 2>&1)
                log_info "Venv restoration completed successfully - Python: $python_version"
                
                # Verify pip is also working
                if "$venv_path/bin/python" -m pip --version >/dev/null 2>&1; then
                    local pip_version
                    pip_version=$("$venv_path/bin/python" -m pip --version 2>&1 | head -1)
                    log_info "Pip is also functional: $pip_version"
                else
                    log_info "Pip may need reinstallation, but Python is working"
                fi
                
                return 0
            else
                log_error "Venv Python executable is not functional after restoration and fixes"
                # List what we have for debugging
                if [ -d "$venv_path/bin" ]; then
                    log_error "bin/ directory contents:"
                    ls -la "$venv_path/bin" | head -10 | while read -r line; do
                        log_error "  $line"
                    done
                fi
                return 1
            fi
        else
            log_error "Failed to apply venv path fixes"
            return 1
        fi
    else
        log_error "Failed to restore chunks"
        return 1
    fi
}

# Legacy function name for backward compatibility - now restores entire venv
restore_site_packages() {
    local chunk_dir="$1"
    local venv_path="$2"
    
    log_info "Note: restore_site_packages now restores entire venv for completeness"
    restore_venv "$chunk_dir" "$venv_path"
}

# Upload chunks to cloud storage
upload_chunks() {
    local chunk_dir="$1"
    local s3_path="$2"
    local sync_type="${3:-venv_sync}"
    
    log_info "Uploading chunks to: $s3_path"
    
    # Count total chunks
    local total_chunks=0
    for chunk_file in "$chunk_dir"/${CHUNK_PREFIX}*.tar.gz; do
        if [ -f "$chunk_file" ]; then
            total_chunks=$((total_chunks + 1))
        fi
    done
    
    if [ "$total_chunks" -eq 0 ]; then
        log_error "No chunk files found in: $chunk_dir"
        return 1
    fi
    
    log_info "Uploading $total_chunks chunks..."
    
    # Notify start of upload if this is user_shared type
    if [ "$sync_type" = "user_shared" ]; then
        notify_sync_progress "user_shared" "PROGRESS" 0
    fi
    
    # Upload chunks in parallel
    local pids=()
    local max_jobs=$VENV_MAX_PARALLEL
    local job_count=0
    local completed_chunks=0
    
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
                        completed_chunks=$((completed_chunks + 1))
                        
                        # Update progress for user_shared uploads
                        if [ "$sync_type" = "user_shared" ]; then
                            local progress=$((completed_chunks * 80 / total_chunks))
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
    
    # Wait for all uploads and update progress
    if [ ${#pids[@]} -gt 0 ]; then
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                wait "$pid" || {
                    log_error "Upload job failed: $pid"
                    return 1
                }
                completed_chunks=$((completed_chunks + 1))
                
                # Update progress for user_shared uploads
                if [ "$sync_type" = "user_shared" ]; then
                    local progress=$((completed_chunks * 80 / total_chunks))
                    notify_sync_progress "user_shared" "PROGRESS" "$progress"
                fi
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
    
    # Notify completion for user_shared uploads
    if [ "$sync_type" = "user_shared" ]; then
        notify_sync_progress "user_shared" "DONE" 100
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
    local download_failures=0
    
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
            if aws s3 cp "$s3_path/$filename" "$target_file" --only-show-errors; then
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
        log_error "Failed to download $download_failures chunk files"
        return 1
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
            echo "  chunk <venv_path> <output_dir>     - Create chunks from entire venv"
            echo "  restore <chunk_dir> <venv_path>    - Restore chunks to entire venv"
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
