#!/bin/bash
#
# CloudWatch Setup Script
#
# This script configures and starts the CloudWatch agent.
# It ASSUMES the following are already installed:
#   - amazon-cloudwatch-agent package
#   - awscli package
# It also ASSUMES it's running on an EC2 instance with an IAM role.
#

# Exit immediately if a command fails
set -e

echo "🔧 [CW] Starting CloudWatch agent configuration."

# --- Prerequisite Checks (optional but highly recommended) ---
if ! command -v /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl &> /dev/null; then
    echo "❌ [CW] CRITICAL: CloudWatch agent command not found. Please install the agent first."
    exit 1
fi
if ! command -v aws &> /dev/null; then
    echo "❌ [CW] CRITICAL: AWS CLI not found. Please install it first."
    exit 1
fi
# --- End of Checks ---


# Define paths and get region
CONFIG_DIR="/opt/aws/amazon-cloudwatch-agent/etc"
CONFIG_FILE="$CONFIG_DIR/amazon-cloudwatch-agent.json"
SCRIPTS_DIR="/scripts" # Define a single location for helper scripts

# Get region with fallback
echo "🌍 [CW] Detecting AWS region..."
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "us-east-1")
echo "📍 [CW] Using region: $REGION"

# Ensure directories exist
mkdir -p "$CONFIG_DIR"
mkdir -p "$SCRIPTS_DIR"

echo "📝 [CW] Creating agent configuration at $CONFIG_FILE"
cat > "$CONFIG_FILE" << 'EOF'
{
    "agent": {
        "run_as_user": "root"
    },
    "logs": {
        "logs_collected": {
            "files": {
                "collect_list": [
                    {
                        "file_path": "/var/log/ami-preparation.log",
                        "log_group_name": "/aws/ec2/comfyui/ami-preparation",
                        "log_stream_name": "{instance_id}-ami-prep"
                    },
                    {
                        "file_path": "/var/log/cloud-init-output.log",
                        "log_group_name": "/aws/ec2/comfyui/user-data",
                        "log_stream_name": "{instance_id}-user-data"
                    },
                    {
                        "file_path": "/var/log/tenant_manager.log",
                        "log_group_name": "/aws/ec2/comfyui/system",
                        "log_stream_name": "{instance_id}-system"
                    },
                    {
                        "file_path": "/var/log/comfyui/*.log",
                        "log_group_name": "/aws/ec2/comfyui/tenant-manager",
                        "log_stream_name": "{instance_id}-tenant-manager"
                    }
                ]
            }
        }
    }
}
EOF
echo "✅ [CW] Agent configuration created."

echo "🔧 [CW] Creating required log groups..."
LOG_GROUPS=(
    "/aws/ec2/comfyui/ami-preparation"
    "/aws/ec2/comfyui/user-data"
    "/aws/ec2/comfyui/system"
    "/aws/ec2/comfyui/tenant-manager"
    # Add pod-specific groups here too so they are ready
    "/aws/ec2/comfyui/tenant-startup"
    "/aws/ec2/comfyui/tenant-runtime"
    "/aws/ec2/comfyui/tenant-user-scripts"
)

for group in "${LOG_GROUPS[@]}"; do
    echo "   - Ensuring log group '$group' exists..."
    # Check if log group already exists first to avoid error noise
    # This prevents AWS CLI from showing "ResourceAlreadyExistsException" errors
    if aws logs describe-log-groups --log-group-name-prefix "$group" --region "$REGION" --query "logGroups[?logGroupName=='$group']" --output text 2>/dev/null | grep -q "$group"; then
        echo "     ✓ Log group '$group' already exists"
    else
        # Create the log group only if it doesn't exist
        if aws logs create-log-group --log-group-name "$group" --region "$REGION" 2>/dev/null; then
            echo "     ✓ Created log group '$group'"
        else
            echo "     ⚠️  Failed to create log group '$group' (may already exist or insufficient permissions)"
        fi
    fi
done
echo "✅ [CW] Log groups are ready."

echo "🚀 [CW] Applying configuration and starting agent..."
# This command validates the config, applies it, and starts/restarts the service.
if /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:"$CONFIG_FILE" -s; then
    echo "✅ [CW] CloudWatch agent is configured and running."
    
    # Verify the agent is actually running
    if systemctl is-active --quiet amazon-cloudwatch-agent; then
        echo "✅ [CW] CloudWatch agent service is active"
    else
        echo "⚠️ [CW] CloudWatch agent service may not be fully active yet"
    fi
else
    echo "❌ [CW] Failed to configure CloudWatch agent"
    exit 1
fi


# ---- Create the helper script for dynamic pod logging ----
# This script will be called later by your application logic.
echo "📝 [CW] Creating pod log setup helper at $SCRIPTS_DIR/setup_pod_cloudwatch.sh"
cat > "$SCRIPTS_DIR/setup_pod_cloudwatch.sh" << 'EOF'
#!/bin/bash
set -e
if [ -z "$1" ]; then echo "Usage: $0 <POD_ID>"; exit 1; fi
POD_ID="$1"
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

echo "  -> Appending config for pod $POD_ID"
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a append-config -m ec2 -s \
    -c 'text:{
        "logs": {
            "logs_collected": {
                "files": {
                    "collect_list": [
                        {"file_path": "/workspace/'"$POD_ID"'/logs/startup.log", "log_group_name": "/aws/ec2/comfyui/tenant-startup", "log_stream_name": "'"$INSTANCE_ID"'-'"$POD_ID"'-startup"},
                        {"file_path": "/workspace/'"$POD_ID"'/logs/runtime.log", "log_group_name": "/aws/ec2/comfyui/tenant-runtime", "log_stream_name": "'"$INSTANCE_ID"'-'"$POD_ID"'-runtime"},
                        {"file_path": "/workspace/'"$POD_ID"'/logs/user-scripts.log", "log_group_name": "/aws/ec2/comfyui/tenant-user-scripts", "log_stream_name": "'"$INSTANCE_ID"'-'"$POD_ID"'-user-scripts"}
                    ]
                }
            }
        }
    }'
echo "  -> CloudWatch config updated for pod $POD_ID"
EOF
chmod +x "$SCRIPTS_DIR/setup_pod_cloudwatch.sh"
echo "✅ [CW] Helper script created."

echo "✅ [CW] Full setup complete."