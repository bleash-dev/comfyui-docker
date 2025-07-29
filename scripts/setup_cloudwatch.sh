#!/bin/bash
# CloudWatch setup for multi-tenant ComfyUI logging

echo "🔧 Setting up CloudWatch logging configuration..."

# Install CloudWatch agent
if ! command -v /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl &> /dev/null; then
    echo "📦 Installing CloudWatch agent..."
    
    # Download and install CloudWatch agent
    wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
    dpkg -i -E amazon-cloudwatch-agent.deb
    rm -f amazon-cloudwatch-agent.deb
    
    echo "✅ CloudWatch agent installed"
else
    echo "✅ CloudWatch agent already installed"
fi

# Create CloudWatch agent configuration
echo "📝 Creating CloudWatch agent configuration..."
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'EOF'
{
    "agent": {
        "metrics_collection_interval": 60,
        "run_as_user": "root"
    },
    "logs": {
        "logs_collected": {
            "files": {
                "collect_list": [
                    {
                        "file_path": "/var/log/ami-preparation.log",
                        "log_group_name": "/aws/ec2/comfyui/ami-preparation",
                        "log_stream_name": "{instance_id}-ami-prep",
                        "timestamp_format": "%Y-%m-%d %H:%M:%S"
                    },
                    {
                        "file_path": "/var/log/user-data.log",
                        "log_group_name": "/aws/ec2/comfyui/user-data",
                        "log_stream_name": "{instance_id}-user-data",
                        "timestamp_format": "%Y-%m-%d %H:%M:%S"
                    },
                    {
                        "file_path": "/var/log/tenant_manager.log",
                        "log_group_name": "/aws/ec2/comfyui/tenant-manager",
                        "log_stream_name": "{instance_id}-tenant-manager",
                        "timestamp_format": "%Y-%m-%d %H:%M:%S"
                    },
                    {
                        "file_path": "/var/log/docker.log",
                        "log_group_name": "/aws/ec2/comfyui/docker",
                        "log_stream_name": "{instance_id}-docker",
                        "timestamp_format": "%Y-%m-%d %H:%M:%S"
                    }
                ]
            }
        }
    },
    "metrics": {
        "namespace": "ComfyUI/MultiTenant",
        "metrics_collected": {
            "cpu": {
                "measurement": [
                    "cpu_usage_idle",
                    "cpu_usage_iowait",
                    "cpu_usage_user",
                    "cpu_usage_system"
                ],
                "metrics_collection_interval": 60,
                "totalcpu": false
            },
            "disk": {
                "measurement": [
                    "used_percent"
                ],
                "metrics_collection_interval": 60,
                "resources": [
                    "*"
                ]
            },
            "diskio": {
                "measurement": [
                    "io_time",
                    "read_bytes",
                    "write_bytes",
                    "reads",
                    "writes"
                ],
                "metrics_collection_interval": 60,
                "resources": [
                    "*"
                ]
            },
            "mem": {
                "measurement": [
                    "mem_used_percent"
                ],
                "metrics_collection_interval": 60
            },
            "netstat": {
                "measurement": [
                    "tcp_established",
                    "tcp_time_wait"
                ],
                "metrics_collection_interval": 60
            },
            "swap": {
                "measurement": [
                    "swap_used_percent"
                ],
                "metrics_collection_interval": 60
            }
        }
    }
}
EOF

echo "✅ CloudWatch agent configuration created"

# Create systemd service for CloudWatch agent
echo "📝 Creating CloudWatch agent systemd service..."
cat > /etc/systemd/system/amazon-cloudwatch-agent.service << 'EOF'
[Unit]
Description=Amazon CloudWatch Agent
After=network.target

[Service]
Type=simple
ExecStart=/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent -c /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
systemctl daemon-reload
systemctl enable amazon-cloudwatch-agent
echo "✅ CloudWatch agent service configured"

# Create CloudWatch log groups
echo "🔧 Creating CloudWatch log groups..."
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "us-east-1")

# List of log groups to create
LOG_GROUPS=(
    "/aws/ec2/comfyui/ami-preparation"
    "/aws/ec2/comfyui/user-data"
    "/aws/ec2/comfyui/tenant-manager"
    "/aws/ec2/comfyui/docker"
)

for LOG_GROUP in "${LOG_GROUPS[@]}"; do
    echo "📝 Creating log group: $LOG_GROUP"
    aws logs create-log-group \
        --log-group-name "$LOG_GROUP" \
        --region "$REGION" 2>/dev/null || {
        echo "⚠️ Log group $LOG_GROUP may already exist"
    }
    
    # Set retention policy (30 days for AMI prep, 7 days for others)
    if [[ "$LOG_GROUP" == *"ami-preparation"* ]]; then
        RETENTION_DAYS=30
    else
        RETENTION_DAYS=7
    fi
    
    aws logs put-retention-policy \
        --log-group-name "$LOG_GROUP" \
        --retention-in-days "$RETENTION_DAYS" \
        --region "$REGION" 2>/dev/null || {
        echo "⚠️ Could not set retention policy for $LOG_GROUP"
    }
done

echo "✅ CloudWatch log groups created"

# Start the CloudWatch agent immediately
echo "🚀 Starting CloudWatch agent..."
systemctl start amazon-cloudwatch-agent || {
    echo "⚠️ CloudWatch agent failed to start, will retry later"
}

# Create log groups creation script
echo "📝 Creating log groups setup script..."
cat > /scripts/setup_cloudwatch_log_groups.sh << 'EOF'
#!/bin/bash
# Create CloudWatch log groups

echo "🔧 Setting up CloudWatch log groups..."

# Get instance region
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)

# Create log groups
LOG_GROUPS=(
    "/aws/ec2/comfyui/tenant-manager"
    "/aws/ec2/comfyui/tenant-startup"
    "/aws/ec2/comfyui/tenant-runtime"
    "/aws/ec2/comfyui/tenant-user-scripts"
)

for log_group in "${LOG_GROUPS[@]}"; do
    echo "Creating log group: $log_group"
    aws logs create-log-group --log-group-name "$log_group" --region "$REGION" 2>/dev/null || echo "Log group $log_group already exists"
    
    # Set retention policy (30 days)
    aws logs put-retention-policy --log-group-name "$log_group" --retention-in-days 30 --region "$REGION" 2>/dev/null || echo "Could not set retention for $log_group"
done

echo "✅ CloudWatch log groups setup completed"
EOF

chmod +x /scripts/setup_cloudwatch_log_groups.sh

# Create dynamic CloudWatch configuration update script for per-pod logging
echo "📝 Creating dynamic CloudWatch pod configuration script..."
cat > /scripts/setup_pod_cloudwatch.sh << 'EOF'
#!/bin/bash
# Setup CloudWatch logging for a specific pod

if [ -z "$1" ]; then
    echo "Usage: $0 <POD_ID>"
    exit 1
fi

POD_ID="$1"
WORKSPACE_DIR="/workspace/$POD_ID"
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

echo "🔧 Setting up CloudWatch logging for pod: $POD_ID"

# Create pod-specific log configuration
cat > "/tmp/cloudwatch-pod-$POD_ID.json" << EOFCONFIG
{
    "logs": {
        "logs_collected": {
            "files": {
                "collect_list": [
                    {
                        "file_path": "$WORKSPACE_DIR/logs/startup.log",
                        "log_group_name": "/aws/ec2/comfyui/tenant-startup",
                        "log_stream_name": "$INSTANCE_ID-$POD_ID-startup",
                        "timestamp_format": "%Y-%m-%d %H:%M:%S"
                    },
                    {
                        "file_path": "$WORKSPACE_DIR/logs/comfyui.log",
                        "log_group_name": "/aws/ec2/comfyui/tenant-runtime",
                        "log_stream_name": "$INSTANCE_ID-$POD_ID-runtime",
                        "timestamp_format": "%Y-%m-%d %H:%M:%S"
                    },
                    {
                        "file_path": "$WORKSPACE_DIR/logs/user-script.log",
                        "log_group_name": "/aws/ec2/comfyui/tenant-user-scripts",
                        "log_stream_name": "$INSTANCE_ID-$POD_ID-user-scripts",
                        "timestamp_format": "%Y-%m-%d %H:%M:%S"
                    }
                ]
            }
        }
    }
}
EOFCONFIG

# Use AWS CLI to send logs directly (alternative approach)
# This ensures pod-specific log streams are created
mkdir -p "$WORKSPACE_DIR/logs"

# Setup log streaming using AWS CLI for this specific pod
echo "📝 Creating log streams for pod $POD_ID..."

LOG_STREAMS=(
    "/aws/ec2/comfyui/tenant-startup:$INSTANCE_ID-$POD_ID-startup"
    "/aws/ec2/comfyui/tenant-runtime:$INSTANCE_ID-$POD_ID-runtime"
    "/aws/ec2/comfyui/tenant-user-scripts:$INSTANCE_ID-$POD_ID-user-scripts"
)

for stream_info in "${LOG_STREAMS[@]}"; do
    log_group=$(echo "$stream_info" | cut -d':' -f1)
    log_stream=$(echo "$stream_info" | cut -d':' -f2)
    
    echo "Creating log stream: $log_stream in group: $log_group"
    aws logs create-log-stream \
        --log-group-name "$log_group" \
        --log-stream-name "$log_stream" \
        --region "$REGION" 2>/dev/null || echo "Log stream $log_stream already exists"
done

echo "✅ CloudWatch logging configured for pod: $POD_ID"
echo "📍 Log streams created:"
echo "  - Startup: $INSTANCE_ID-$POD_ID-startup"
echo "  - Runtime: $INSTANCE_ID-$POD_ID-runtime"
echo "  - User Scripts: $INSTANCE_ID-$POD_ID-user-scripts"

# Cleanup temp config
rm -f "/tmp/cloudwatch-pod-$POD_ID.json"
EOF

chmod +x /scripts/setup_pod_cloudwatch.sh

# Create log streaming helper script for pods
echo "📝 Creating log streaming helper script..."
cat > /scripts/stream_pod_logs.sh << 'EOF'
#!/bin/bash
# Stream logs from a pod to CloudWatch

if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    echo "Usage: $0 <POD_ID> <LOG_TYPE> <LOG_FILE>"
    echo "LOG_TYPE: startup|runtime|user-scripts"
    exit 1
fi

POD_ID="$1"
LOG_TYPE="$2"
LOG_FILE="$3"

REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

LOG_GROUP="/aws/ec2/comfyui/tenant-$LOG_TYPE"
LOG_STREAM="$INSTANCE_ID-$POD_ID-$LOG_TYPE"

if [ -f "$LOG_FILE" ]; then
    echo "📤 Streaming $LOG_FILE to CloudWatch..."
    aws logs put-log-events \
        --log-group-name "$LOG_GROUP" \
        --log-stream-name "$LOG_STREAM" \
        --log-events timestamp=$(date +%s000),message="$(cat "$LOG_FILE")" \
        --region "$REGION"
else
    echo "⚠️ Log file not found: $LOG_FILE"
fi
EOF

chmod +x /scripts/stream_pod_logs.sh

echo "✅ CloudWatch logging setup completed"
echo "💡 Note: CloudWatch agent will start automatically when the system boots"
echo "💡 To manually start: systemctl start amazon-cloudwatch-agent"
echo "💡 Pod-specific logging: Use /scripts/setup_pod_cloudwatch.sh <POD_ID>"
echo "💡 Expected log structure: /workspace/<POD_ID>/logs/"
