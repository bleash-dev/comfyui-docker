#!/bin/bash
# Start all background services

echo "🚀 Starting background services..."

# Start sync daemon
nohup bash -c 'while true; do /scripts/sync_user_data.sh; sleep 300; done' > /scripts/.sync_daemon.log 2>&1 &

# Start signal handler
nohup /scripts/signal_handler.sh > /scripts/.signal_handler.log 2>&1 &

# Start log sync
nohup bash -c 'while true; do /scripts/sync_logs.sh; sleep 180; done' > /scripts/.log_sync.log 2>&1 &

echo "✅ Background services started"
