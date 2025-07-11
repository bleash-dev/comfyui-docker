#!/bin/bash
# Create sync management utility script

echo "📝 Creating sync management utility script..."

# Create the sync management utility
cat > "$NETWORK_VOLUME/scripts/sync_manager.sh" << 'EOF'
#!/bin/bash
# Sync management utility script
# Provides commands to check, manage, and troubleshoot sync operations

# Source the sync lock manager
source "$NETWORK_VOLUME/scripts/sync_lock_manager.sh"

show_help() {
    echo "🔧 Sync Management Utility"
    echo "=========================="
    echo ""
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  status                  - Show current sync lock status"
    echo "  unlock [sync_type]          - Force release sync lock (specific type or all)"
    echo "  test [sync_type]        - Test lock acquisition/release for a sync type"
    echo "  run [sync_type]         - Manually run a specific sync operation"
    echo "  run all                 - Run all sync operations sequentially"
    echo "  list                    - List all available sync scripts"
    echo "  logs [sync_type]        - Show recent logs for a sync type"
    echo "  help                    - Show this help message"
    echo ""
    echo "Sync Types:"
    echo "  user_data              - Pod-specific user data sync"
    echo "  user_shared            - User-shared data sync (across pods)"
    echo "  global_shared          - Global shared models and browser sessions"
    echo "  user_assets            - ComfyUI input/output assets"
    echo "  pod_metadata           - Model configuration and workflows"
    echo "  logs                   - System and application logs"
    echo ""
    echo "Examples:"
    echo "  $0 status                       # Check if any sync is running"
    echo "  $0 run user_data               # Manually trigger user data sync"
    echo "  $0 run all                     # Run all sync operations"
    echo "  $0 unlock                      # Force release all stuck sync locks
    $0 unlock user_data            # Force release user_data sync lock"
    echo "  $0 test user_shared            # Test lock mechanism"
    echo "  $0 logs global_shared          # Show global shared sync logs"
}

show_status() {
    echo "🔍 Current Sync Status"
    echo "====================="
    echo ""
    
    # Check all sync locks
    check_sync_lock
    
    echo ""
    echo "� Lock files location: $SYNC_LOCKS_DIR"
    
    # Show individual lock details if any exist
    if [ -d "$SYNC_LOCKS_DIR" ] && [ -n "$(ls -A "$SYNC_LOCKS_DIR" 2>/dev/null)" ]; then
        echo ""
        echo "🔒 Individual Lock Details:"
        echo "----------------------------"
        for lock_file in "$SYNC_LOCKS_DIR"/*.lock; do
            if [ -f "$lock_file" ]; then
                local sync_type=$(basename "$lock_file" .lock)
                echo "📋 $sync_type:"
                check_sync_lock "$sync_type" | sed 's/^/  /'
            fi
        done
    fi
    
    echo ""
    echo "📊 Recent Sync Activity (last 5 log entries):"
    echo "----------------------------------------------"
    
    # Check recent sync activity in daemon logs
    local log_files=(
        "$NETWORK_VOLUME/.sync_daemon.log"
        "$NETWORK_VOLUME/.sync_shared_daemon.log"
        "$NETWORK_VOLUME/.global_shared_sync_daemon.log"
        "$NETWORK_VOLUME/.comfyui_assets_sync_daemon.log"
        "$NETWORK_VOLUME/.pod_metadata_sync_daemon.log"
        "$NETWORK_VOLUME/.log_sync.log"
    )
    
    for log_file in "${log_files[@]}"; do
        if [ -f "$log_file" ]; then
            local daemon_name=$(basename "$log_file" .log)
            echo ""
            echo "📋 ${daemon_name}:"
            tail -n 3 "$log_file" 2>/dev/null | sed 's/^/  /' || echo "  No recent activity"
        fi
    done
}

force_unlock() {
    local sync_type="$1"
    
    echo "🚨 Force Unlocking Sync Lock"
    echo "============================"
    echo ""
    
    if [ -n "$sync_type" ]; then
        # Force unlock specific sync type
        local sync_lock_file="$SYNC_LOCKS_DIR/${sync_type}.lock"
        
        if [ ! -f "$sync_lock_file" ]; then
            echo "ℹ️ No '$sync_type' lock file found, nothing to unlock."
            return 0
        fi
        
        local lock_info
        lock_info=$(cat "$sync_lock_file" 2>/dev/null || echo "")
        
        if [ -n "$lock_info" ]; then
            echo "📋 Current '$sync_type' lock info: $lock_info"
            local lock_type lock_pid lock_timestamp
            IFS='|' read -r lock_type lock_pid lock_timestamp <<< "$lock_info"
            
            echo "⚠️ Forcefully removing '$sync_type' sync lock..."
            release_sync_lock_force "$sync_type" "$lock_pid"
            echo "✅ '$sync_type' lock forcefully released."
        else
            echo "🧹 Empty '$sync_type' lock file found, removing..."
            rm -f "$sync_lock_file"
            echo "✅ Empty '$sync_type' lock file removed."
        fi
    else
        # Force unlock all sync types
        if [ ! -d "$SYNC_LOCKS_DIR" ] || [ -z "$(ls -A "$SYNC_LOCKS_DIR" 2>/dev/null)" ]; then
            echo "ℹ️ No lock files found, nothing to unlock."
            return 0
        fi
        
        echo "⚠️ Forcefully removing ALL sync locks..."
        for lock_file in "$SYNC_LOCKS_DIR"/*.lock; do
            if [ -f "$lock_file" ]; then
                local sync_type=$(basename "$lock_file" .lock)
                local lock_info
                lock_info=$(cat "$lock_file" 2>/dev/null || echo "")
                echo "📋 Removing '$sync_type' lock: $lock_info"
                rm -f "$lock_file"
            fi
        done
        echo "✅ All lock files forcefully removed."
    fi
}

test_lock() {
    local sync_type="${1:-test_sync}"
    
    echo "🧪 Testing Lock Mechanism for '$sync_type'"
    echo "=========================================="
    echo ""
    
    echo "1️⃣ Attempting to acquire lock..."
    if acquire_sync_lock "$sync_type" 10; then
        echo "✅ Lock acquired successfully!"
        
        echo ""
        echo "2️⃣ Testing lock status check..."
        check_sync_lock
        
        echo ""
        echo "3️⃣ Sleeping for 3 seconds to simulate sync work..."
        sleep 3
        
        echo ""
        echo "4️⃣ Releasing lock..."
        if release_sync_lock "$sync_type"; then
            echo "✅ Lock released successfully!"
            echo ""
            echo "🎉 Lock mechanism test completed successfully!"
        else
            echo "❌ Failed to release lock!"
            return 1
        fi
    else
        echo "❌ Failed to acquire lock!"
        echo ""
        echo "🔍 Current lock status:"
        check_sync_lock
        return 1
    fi
}

run_sync() {
    local sync_type="$1"
    
    case "$sync_type" in
        "all")
            echo "🔄 Running ALL sync operations..."
            echo ""
            echo "1/6 Running user data sync..."
            "$NETWORK_VOLUME/scripts/sync_user_data.sh"
            echo ""
            echo "2/6 Running user shared data sync..."
            "$NETWORK_VOLUME/scripts/sync_user_shared_data.sh"
            echo ""
            echo "3/6 Running global shared models sync..."
            "$NETWORK_VOLUME/scripts/sync_global_shared_models.sh"
            echo ""
            echo "4/6 Running ComfyUI assets sync..."
            "$NETWORK_VOLUME/scripts/sync_comfyui_assets.sh"
            echo ""
            echo "5/6 Running pod metadata sync..."
            "$NETWORK_VOLUME/scripts/sync_pod_metadata.sh"
            echo ""
            echo "6/6 Running logs sync..."
            "$NETWORK_VOLUME/scripts/sync_logs.sh"
            echo ""
            echo "✅ All sync operations completed!"
            ;;
        "user_data")
            echo "🔄 Running user data sync..."
            "$NETWORK_VOLUME/scripts/sync_user_data.sh"
            ;;
        "user_shared")
            echo "🔄 Running user shared data sync..."
            "$NETWORK_VOLUME/scripts/sync_user_shared_data.sh"
            ;;
        "global_shared")
            echo "🔄 Running global shared models sync..."
            "$NETWORK_VOLUME/scripts/sync_global_shared_models.sh"
            ;;
        "user_assets")
            echo "🔄 Running ComfyUI assets sync..."
            "$NETWORK_VOLUME/scripts/sync_comfyui_assets.sh"
            ;;
        "pod_metadata")
            echo "🔄 Running pod metadata sync..."
            "$NETWORK_VOLUME/scripts/sync_pod_metadata.sh"
            ;;
        "logs")
            echo "🔄 Running logs sync..."
            "$NETWORK_VOLUME/scripts/sync_logs.sh"
            ;;
        *)
            echo "❌ Unknown sync type: $sync_type"
            echo "Available sync types: all, user_data, user_shared, global_shared, user_assets, pod_metadata, logs"
            return 1
            ;;
    esac
}

list_syncs() {
    echo "📋 Available Sync Scripts"
    echo "========================"
    echo ""
    
    local scripts_dir="$NETWORK_VOLUME/scripts"
    local sync_scripts=(
        "sync_user_data.sh:Pod-specific user data"
        "sync_user_shared_data.sh:User-shared data (across pods)"
        "sync_global_shared_models.sh:Global shared models and browser sessions"
        "sync_comfyui_assets.sh:ComfyUI input/output assets"
        "sync_pod_metadata.sh:Model configuration and workflows"
        "sync_logs.sh:System and application logs"
    )
    
    for script_info in "${sync_scripts[@]}"; do
        IFS=':' read -r script_name description <<< "$script_info"
        local script_path="$scripts_dir/$script_name"
        
        if [ -f "$script_path" ]; then
            local status="✅ Available"
            local perms=$(ls -l "$script_path" | cut -d' ' -f1)
        else
            local status="❌ Missing"
            local perms="N/A"
        fi
        
        printf "%-30s | %-8s | %s | %s\n" "$script_name" "$status" "$perms" "$description"
    done
}

show_logs() {
    local sync_type="$1"
    local lines="${2:-20}"
    
    echo "📄 Recent Logs for '$sync_type' (last $lines lines)"
    echo "=================================================="
    echo ""
    
    case "$sync_type" in
        "user_data")
            local log_file="$NETWORK_VOLUME/.sync_daemon.log"
            ;;
        "user_shared")
            local log_file="$NETWORK_VOLUME/.sync_shared_daemon.log"
            ;;
        "global_shared")
            local log_file="$NETWORK_VOLUME/.global_shared_sync_daemon.log"
            ;;
        "user_assets")
            local log_file="$NETWORK_VOLUME/.comfyui_assets_sync_daemon.log"
            ;;
        "pod_metadata")
            local log_file="$NETWORK_VOLUME/.pod_metadata_sync_daemon.log"
            ;;
        "logs")
            local log_file="$NETWORK_VOLUME/.log_sync.log"
            ;;
        *)
            echo "❌ Unknown sync type: $sync_type"
            echo "Available sync types: user_data, user_shared, global_shared, user_assets, pod_metadata, logs"
            return 1
            ;;
    esac
    
    if [ -f "$log_file" ]; then
        echo "📁 Log file: $log_file"
        echo ""
        tail -n "$lines" "$log_file"
    else
        echo "⚠️ Log file not found: $log_file"
        echo "This sync type may not have run yet or logging may not be enabled."
    fi
}

# Main command handling
main_command="${1:-help}"

case "$main_command" in
    "status")
        show_status
        ;;
    "unlock")
        force_unlock "$2"
        ;;
    "test")
        test_lock "$2"
        ;;
    "run")
        if [ -z "$2" ]; then
            echo "❌ Please specify a sync type to run."
            echo "Use '$0 list' to see available sync types."
            exit 1
        fi
        run_sync "$2"
        ;;
    "list")
        list_syncs
        ;;
    "logs")
        if [ -z "$2" ]; then
            echo "❌ Please specify a sync type to show logs for."
            echo "Use '$0 list' to see available sync types."
            exit 1
        fi
        show_logs "$2" "$3"
        ;;
    "help"|*)
        show_help
        ;;
esac
EOF

chmod +x "$NETWORK_VOLUME/scripts/sync_manager.sh"

# Create convenient shortcut
cat > "$NETWORK_VOLUME/sync" << 'EOF'
#!/bin/bash
# Convenient shortcut for sync management
bash "$NETWORK_VOLUME/scripts/sync_manager.sh" "$@"
EOF

chmod +x "$NETWORK_VOLUME/sync"

echo "✅ Sync management utility created:"
echo "   - Full script: $NETWORK_VOLUME/scripts/sync_manager.sh"
echo "   - Shortcut: $NETWORK_VOLUME/sync"
echo ""
echo "📚 Usage examples:"
echo "   $NETWORK_VOLUME/sync status      # Check current sync status"
echo "   $NETWORK_VOLUME/sync run user_data # Run user data sync"
echo "   $NETWORK_VOLUME/sync unlock      # Force unlock if stuck"
