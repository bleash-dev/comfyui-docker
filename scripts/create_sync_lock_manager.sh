#!/bin/bash
# Create sync lock management script

echo "📝 Creating sync lock management script..."

# Create the centralized sync lock manager
cat > "$NETWORK_VOLUME/scripts/sync_lock_manager.sh" << 'EOF'
#!/bin/bash
# Centralized sync lock manager
# Provides lock functions for all sync operations to prevent concurrent syncing

# Lock files directory
SYNC_LOCKS_DIR="$NETWORK_VOLUME/.sync_locks"
SYNC_LOCK_TIMEOUT="${SYNC_LOCK_TIMEOUT:-600}" # 10 minutes timeout by default

# Ensure lock directory exists
mkdir -p "$SYNC_LOCKS_DIR"

# Function to acquire sync lock
acquire_sync_lock() {
    local sync_type="$1"
    local caller_pid="$$"
    local max_wait_time="${2:-$SYNC_LOCK_TIMEOUT}"
    local wait_interval=5
    local waited=0
    
    # Create sync-type specific lock file
    local sync_lock_file="$SYNC_LOCKS_DIR/${sync_type}.lock"
    
    echo "🔒 [$sync_type] Attempting to acquire sync lock for type '$sync_type'..."
    
    # Check if lock file exists and is still valid
    while [ -f "$sync_lock_file" ]; do
        local lock_info
        lock_info=$(cat "$sync_lock_file" 2>/dev/null || echo "")
        
        if [ -n "$lock_info" ]; then
            local lock_type lock_pid lock_timestamp
            IFS='|' read -r lock_type lock_pid lock_timestamp <<< "$lock_info"
            
            # Check if the process is still running
            if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
                local current_time
                current_time=$(date +%s)
                local lock_age=$((current_time - lock_timestamp))
                
                echo "⏳ [$sync_type] Sync lock held by another '$sync_type' process (PID: $lock_pid, age: ${lock_age}s)"
                
                # Check if lock has timed out
                if [ "$lock_age" -gt "$max_wait_time" ]; then
                    echo "⚠️ [$sync_type] Lock timeout exceeded (${lock_age}s > ${max_wait_time}s), force releasing..."
                    release_sync_lock_force "$sync_type" "$lock_pid"
                    break
                fi
                
                # Wait and check again
                if [ "$waited" -ge "$max_wait_time" ]; then
                    echo "❌ [$sync_type] Timeout waiting for sync lock after ${waited}s, aborting"
                    return 1
                fi
                
                echo "⏳ [$sync_type] Waiting for '$sync_type' sync to complete... (${waited}s/${max_wait_time}s)"
                sleep "$wait_interval"
                waited=$((waited + wait_interval))
            else
                echo "🧹 [$sync_type] Stale lock detected (PID $lock_pid not running), removing..."
                rm -f "$sync_lock_file"
                break
            fi
        else
            echo "🧹 [$sync_type] Empty lock file detected, removing..."
            rm -f "$sync_lock_file"
            break
        fi
    done
    
    # Acquire the lock
    local timestamp
    timestamp=$(date +%s)
    echo "$sync_type|$caller_pid|$timestamp" > "$sync_lock_file"
    
    # Verify we got the lock
    if [ -f "$sync_lock_file" ]; then
        local verification
        verification=$(cat "$sync_lock_file" 2>/dev/null || echo "")
        if echo "$verification" | grep -q "^$sync_type|$caller_pid|$timestamp$"; then
            echo "✅ [$sync_type] Sync lock acquired successfully (PID: $caller_pid)"
            return 0
        else
            echo "❌ [$sync_type] Failed to verify lock acquisition"
            return 1
        fi
    else
        echo "❌ [$sync_type] Failed to create lock file"
        return 1
    fi
}

# Function to release sync lock
release_sync_lock() {
    local sync_type="$1"
    local caller_pid="$$"
    
    # Create sync-type specific lock file path
    local sync_lock_file="$SYNC_LOCKS_DIR/${sync_type}.lock"
    
    if [ ! -f "$sync_lock_file" ]; then
        echo "ℹ️ [$sync_type] No lock file to release"
        return 0
    fi
    
    local lock_info
    lock_info=$(cat "$sync_lock_file" 2>/dev/null || echo "")
    
    if [ -n "$lock_info" ]; then
        local lock_type lock_pid lock_timestamp
        IFS='|' read -r lock_type lock_pid lock_timestamp <<< "$lock_info"
        
        # Verify this process owns the lock
        if [ "$lock_pid" = "$caller_pid" ] && [ "$lock_type" = "$sync_type" ]; then
            rm -f "$sync_lock_file"
            echo "🔓 [$sync_type] Sync lock released successfully (PID: $caller_pid)"
            return 0
        else
            echo "⚠️ [$sync_type] Lock not owned by this process (owner: $lock_type|$lock_pid, caller: $sync_type|$caller_pid)"
            return 1
        fi
    else
        echo "🧹 [$sync_type] Empty lock file, removing..."
        rm -f "$sync_lock_file"
        return 0
    fi
}

# Function to force release a lock (for timeout situations)
release_sync_lock_force() {
    local sync_type="$1"
    local target_pid="$2"
    
    # Create sync-type specific lock file path
    local sync_lock_file="$SYNC_LOCKS_DIR/${sync_type}.lock"
    
    echo "🚨 Force releasing '$sync_type' sync lock (target PID: $target_pid)"
    
    if [ -f "$sync_lock_file" ]; then
        local lock_info
        lock_info=$(cat "$sync_lock_file" 2>/dev/null || echo "")
        echo "📋 Lock info before force release: $lock_info"
        rm -f "$sync_lock_file"
        echo "✅ Lock file forcefully removed"
    fi
}

# Function to check lock status
check_sync_lock() {
    local sync_type="$1"  # Optional: check specific sync type
    local active_locks=0
    
    if [ -n "$sync_type" ]; then
        # Check specific sync type
        local sync_lock_file="$SYNC_LOCKS_DIR/${sync_type}.lock"
        
        if [ ! -f "$sync_lock_file" ]; then
            echo "🟢 No '$sync_type' sync lock active"
            return 1
        fi
        
        local lock_info
        lock_info=$(cat "$sync_lock_file" 2>/dev/null || echo "")
        
        if [ -n "$lock_info" ]; then
            local lock_type lock_pid lock_timestamp
            IFS='|' read -r lock_type lock_pid lock_timestamp <<< "$lock_info"
            
            if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
                local current_time
                current_time=$(date +%s)
                local lock_age=$((current_time - lock_timestamp))
                echo "🔒 Active '$sync_type' sync lock: (PID: $lock_pid, age: ${lock_age}s)"
                return 0
            else
                echo "🧹 Stale '$sync_type' lock detected, cleaning up..."
                rm -f "$sync_lock_file"
                return 1
            fi
        else
            echo "🧹 Empty '$sync_type' lock file detected, cleaning up..."
            rm -f "$sync_lock_file"
            return 1
        fi
    else
        # Check all sync types
        echo "🔍 Checking all sync locks..."
        
        if [ ! -d "$SYNC_LOCKS_DIR" ] || [ -z "$(ls -A "$SYNC_LOCKS_DIR" 2>/dev/null)" ]; then
            echo "🟢 No sync locks active"
            return 1
        fi
        
        for lock_file in "$SYNC_LOCKS_DIR"/*.lock; do
            if [ ! -f "$lock_file" ]; then
                continue
            fi
            
            local lock_name=$(basename "$lock_file" .lock)
            local lock_info
            lock_info=$(cat "$lock_file" 2>/dev/null || echo "")
            
            if [ -n "$lock_info" ]; then
                local lock_type lock_pid lock_timestamp
                IFS='|' read -r lock_type lock_pid lock_timestamp <<< "$lock_info"
                
                if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
                    local current_time
                    current_time=$(date +%s)
                    local lock_age=$((current_time - lock_timestamp))
                    echo "🔒 Active '$lock_type' sync lock: (PID: $lock_pid, age: ${lock_age}s)"
                    active_locks=$((active_locks + 1))
                else
                    echo "🧹 Stale '$lock_type' lock detected, cleaning up..."
                    rm -f "$lock_file"
                fi
            else
                echo "🧹 Empty '$lock_name' lock file detected, cleaning up..."
                rm -f "$lock_file"
            fi
        done
        
        if [ "$active_locks" -eq 0 ]; then
            echo "🟢 No active sync locks found"
            return 1
        else
            echo "📊 Total active sync locks: $active_locks"
            return 0
        fi
    fi
}

# Function to execute sync with automatic lock management
execute_with_sync_lock() {
    local sync_type="$1"
    local sync_command="$2"
    local max_wait_time="${3:-$SYNC_LOCK_TIMEOUT}"
    
    echo "🔄 [$sync_type] Starting sync with lock management..."
    
    # Try to acquire lock
    if acquire_sync_lock "$sync_type" "$max_wait_time"; then
        # Set up trap to release lock on exit
        trap "release_sync_lock '$sync_type'" EXIT INT TERM QUIT
        
        echo "▶️ [$sync_type] Executing sync command: $sync_command"
        
        # Execute the sync command
        if eval "$sync_command"; then
            echo "✅ [$sync_type] Sync completed successfully"
            local exit_code=0
        else
            echo "❌ [$sync_type] Sync failed"
            local exit_code=1
        fi
        
        # Release lock
        release_sync_lock "$sync_type"
        trap - EXIT INT TERM QUIT
        
        return $exit_code
    else
        echo "⚠️ [$sync_type] Could not acquire sync lock, skipping this sync cycle"
        return 1
    fi
}

# Allow script to be sourced or called directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Called directly, show usage
    echo "🔐 Sync Lock Manager"
    echo "==================="
    echo ""
    echo "This script provides centralized locking for sync operations."
    echo "Source this script in other sync scripts to use the functions:"
    echo ""
    echo "Functions available:"
    echo "  acquire_sync_lock <sync_type> [timeout]"
    echo "  release_sync_lock <sync_type>"
    echo "  check_sync_lock"
    echo "  execute_with_sync_lock <sync_type> <command> [timeout]"
    echo ""
    echo "Example usage in sync scripts:"
    echo "  source \"\$NETWORK_VOLUME/scripts/sync_lock_manager.sh\""
    echo "  execute_with_sync_lock \"user_data\" \"\$sync_command\""
    echo ""
    echo "Current lock status:"
    check_sync_lock
fi
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_lock_manager.sh"

echo "✅ Sync lock manager created at $NETWORK_VOLUME/scripts/sync_lock_manager.sh"
