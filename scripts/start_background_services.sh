#!/bin/bash
# Start all background services (sync-only, no FUSE)

echo "🚀 Starting background services..."

# Start sync daemon for periodic data synchronization
nohup bash -c 'while true; do '$NETWORK_VOLUME'/scripts/sync_user_data.sh; sleep 300; done' > $NETWORK_VOLUME/.sync_daemon.log 2>&1 &

# Start signal handler for graceful shutdown
nohup $NETWORK_VOLUME/scripts/signal_handler.sh > $NETWORK_VOLUME/.signal_handler.log 2>&1 &

# Start log sync daemon
nohup bash -c 'while true; do '$NETWORK_VOLUME'/scripts/sync_logs.sh; sleep 180; done' > $NETWORK_VOLUME/.log_sync.log 2>&1 &

echo "✅ Background services started (sync-only mode)"
