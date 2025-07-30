#!/bin/bash
#
# Simplified and Robust AMI Preparation Script for Multi-Tenant ComfyUI
# Version 4 - With package-by-package installation for debugging
#

# Exit immediately if a command exits with a non-zero status.
# Print each command before executing it.
set -ex

# --- 1. INITIAL SETUP ---
echo "🏗️ Preparing EC2 instance for AMI creation..."

# Get Docker image from command line parameter
DOCKER_IMAGE="$1"
if [ -z "$DOCKER_IMAGE" ]; then
    echo "❌ ERROR: Docker image must be provided as first parameter"
    echo "Usage: $0 <docker-image-uri>"
    exit 1
fi

echo "📝 Using Docker image: $DOCKER_IMAGE"
echo "🔍 Docker image parameter received: '$1'"

# Set up unified logging
LOG_FILE="/var/log/ami-preparation.log"
exec &> >(tee -a "$LOG_FILE")

echo "=== AMI Preparation Started - $(date) ==="

# Checkpoint function for progress tracking
checkpoint() {
    echo "✅ CHECKPOINT: $1 completed at $(date)"
    echo "$1" > /tmp/ami_progress.txt
}
checkpoint "AMI_PREP_STARTED"


# --- 2. PACKAGE MANAGEMENT SETUP ---
echo "📦 Preparing package manager (apt)..."
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Aggressive APT lock handling - use timeout and force clear
echo "🔧 Clearing APT locks aggressively..."

# Force kill any apt/dpkg processes
echo "🔪 Force killing any existing apt/dpkg processes..."
timeout 10 pkill -9 -f apt-get || true
timeout 10 pkill -9 -f dpkg || true
timeout 10 pkill -9 -f unattended-upgrade || true
timeout 10 pkill -9 -f packagekit || true
sleep 3

# Remove lock files directly (will be recreated)
echo "🗑️ Removing lock files..."
rm -f /var/lib/dpkg/lock-frontend
rm -f /var/lib/apt/lists/lock 
rm -f /var/cache/apt/archives/lock
rm -f /var/lib/dpkg/lock
sleep 2

# Check if locks are clear with timeout
echo "🔍 Final APT lock check..."
timeout 30 bash -c '
for i in {1..15}; do
    if ! lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && \
       ! lsof /var/lib/apt/lists/lock >/dev/null 2>&1 && \
       ! lsof /var/cache/apt/archives/lock >/dev/null 2>&1; then
        echo "✅ APT locks are clear"
        exit 0
    fi
    echo "⏳ Checking APT locks... (attempt $i/15)"
    sleep 2
done
echo "⚠️ Some locks may still be present, but proceeding..."
' || echo "⚠️ Lock check timed out, proceeding anyway..."

# Configure apt for non-interactive use using robust echo commands
APT_CONFIG_FILE="/etc/apt/apt.conf.d/90-noninteractive"
echo 'APT::Get::Assume-Yes "true";' > "$APT_CONFIG_FILE"
echo 'APT::Get::AllowUnauthenticated "true";' >> "$APT_CONFIG_FILE"
echo 'DPkg::Options "--force-confdef";' >> "$APT_CONFIG_FILE"
echo 'DPkg::Options "--force-confold";' >> "$APT_CONFIG_FILE"
echo 'DPkg::Use-Pty "0";' >> "$APT_CONFIG_FILE"

# Update package lists with timeout
echo "🔄 Updating package lists..."
timeout 300 apt-get update || {
    echo "⚠️ Package update timed out or failed, trying once more..."
    timeout 300 apt-get update || echo "❌ Package update failed but continuing..."
}
checkpoint "PACKAGE_MANAGEMENT_READY"


# --- 3. INSTALL ALL DEPENDENCIES ---
echo "🧩 Installing all required packages with timeouts..."

# First, try to update package cache one more time
echo "🔄 Final package cache update..."
timeout 120 apt-get update || echo "⚠️ Final update failed, proceeding with installation..."

PACKAGES=(
    "ca-certificates"
    "curl"
    "wget"
    "gnupg"
    "lsb-release"
    "docker.io"
    "jq"
    "unzip"
    "htop"
    "tree"
    "vim"
    "git"
    "awscli"
)
for package in "${PACKAGES[@]}"; do
    echo ">>> Installing package: $package"
    apt-get install -y --no-install-recommends "$package"
done
checkpoint "BASE_PACKAGES_INSTALLED"


# Install CloudWatch Agent separately via its .deb package
echo "📦 Installing CloudWatch Agent..."
CW_AGENT_DEB="/tmp/amazon-cloudwatch-agent.deb"
wget -q -O "$CW_AGENT_DEB" https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i "$CW_AGENT_DEB" || apt-get install -f -y # If dpkg fails, apt-get -f will fix missing dependencies
rm -f "$CW_AGENT_DEB"
checkpoint "CLOUDWATCH_AGENT_INSTALLED"


# --- 4. CONFIGURE AND VERIFY DOCKER ---
echo "🐳 Configuring Docker..."

# Add ubuntu user to docker group if it exists
if id "ubuntu" &>/dev/null; then
    usermod -aG docker ubuntu
fi

# Enable and start Docker
systemctl enable docker.service
systemctl start docker.service

# Wait for Docker daemon to be responsive
timeout 60 bash -c 'while ! docker info >/dev/null 2>&1; do echo "⏳ Waiting for Docker daemon..."; sleep 2; done'

# Final verification
docker --version
docker info
checkpoint "DOCKER_READY"


# --- 5. CONFIGURE AND START CLOUDWATCH ---
echo "📡 Configuring CloudWatch..."
if [ -f "/scripts/setup_cloudwatch.sh" ]; then
    bash /scripts/setup_cloudwatch.sh
    checkpoint "CLOUDWATCH_CONFIGURED"
else
    echo "⚠️ CloudWatch setup script not found, skipping..."
    checkpoint "CLOUDWATCH_SKIPPED"
fi


# --- 6. PREPARE COMFYUI APPLICATION ---
echo "🎨 Preparing ComfyUI Application..."

# Create required directories
mkdir -p /var/log/comfyui /workspace /scripts
chmod 755 /var/log/comfyui /workspace /scripts

# Pull the ComfyUI Docker image
echo "📝 Pulling Docker image: $DOCKER_IMAGE"

# Verify Docker is working before attempting image operations
if ! docker version >/dev/null 2>&1; then
    echo "❌ CRITICAL: Docker daemon is not responding"
    docker version
    exit 1
fi

# Login to ECR if necessary (with better error handling)
if [[ "$DOCKER_IMAGE" == *"ecr"* ]]; then
    echo "🔐 Logging into ECR..."
    
    # Try ECR login with timeout and error handling
    if timeout 30 aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws; then
        echo "✅ Successfully logged into ECR"
    else
        echo "⚠️ ECR login failed - this may be okay if the image is public"
        echo "🔍 Checking if we can reach ECR without authentication..."
        
        # Test if we can reach ECR endpoint
        if curl -s --max-time 10 https://public.ecr.aws >/dev/null; then
            echo "✅ ECR endpoint is reachable"
        else
            echo "❌ Cannot reach ECR endpoint - check network connectivity"
            exit 1
        fi
    fi
fi

echo "⬇️ Pulling Docker image: $DOCKER_IMAGE"
echo "🔍 This may take several minutes for large images..."

# Pull with timeout and detailed error handling
if timeout 900 docker pull "$DOCKER_IMAGE"; then
    echo "✅ Docker image pulled successfully"
else
    PULL_EXIT_CODE=$?
    echo "❌ Failed to pull Docker image: $DOCKER_IMAGE"
    echo "💡 Exit code: $PULL_EXIT_CODE"
    
    # Provide debugging information
    echo "🔍 Docker daemon status:"
    docker version
    echo "🔍 Available Docker images:"
    docker images
    echo "🔍 Docker system info:"
    docker system df
    echo "🔍 Network connectivity test:"
    curl -I https://public.ecr.aws || echo "Cannot reach ECR"
    
    exit 1
fi

# Tag the image for local use
docker tag "$DOCKER_IMAGE" comfyui-multitenant:latest

# Verify the image was tagged correctly
echo "🔍 Verifying image was tagged correctly..."
if docker images | grep comfyui-multitenant; then
    echo "✅ Image tagged successfully"
else
    echo "❌ Failed to tag image"
    echo "🔍 Available images:"
    docker images
    exit 1
fi

checkpoint "DOCKER_IMAGE_PULLED"


# --- 7. CREATE AND ENABLE SYSTEM SERVICES ---
echo "⚙️ Creating systemd services..."

# Create a modern systemd service for ComfyUI
cat > /etc/systemd/system/comfyui-multitenant.service << 'EOF'
[Unit]
Description=ComfyUI Multi-Tenant Manager
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10s

# Clean up old container on start
ExecStartPre=-/usr/bin/docker stop comfyui-manager
ExecStartPre=-/usr/bin/docker rm comfyui-manager

# The main command to run the container
ExecStart=/usr/bin/docker run --rm \
    --name comfyui-manager \
    -p 80:80 \
    -p 8000-9000:8000-9000 \
    -v /var/log/comfyui:/var/log \
    -v /workspace:/workspace \
    --privileged \
    comfyui-multitenant:latest

# Command to gracefully stop the container
ExecStop=/usr/bin/docker stop comfyui-manager

[Install]
WantedBy=multi-user.target
EOF

# Create a monitoring script
cat > /usr/local/bin/comfyui-monitor << 'EOF'
#!/bin/bash
echo "--- ComfyUI System Status ---"
echo; echo "--- Docker Status ---"
systemctl is-active docker && docker ps || systemctl status docker
echo; echo "--- ComfyUI Service Status ---"
systemctl status comfyui-multitenant
echo; echo "--- System Resources ---"
df -h /; free -h
echo; echo "--- Recent ComfyUI Logs ---"
docker logs --tail 20 comfyui-manager
EOF
chmod +x /usr/local/bin/comfyui-monitor

# Create log rotation
cat > /etc/logrotate.d/comfyui << 'EOF'
/var/log/comfyui/*.log /workspace/*/*.log {
    daily
    missingok
    rotate 7
    compress
    notifempty
    create 0644 root root
}
EOF

# Enable the ComfyUI service
systemctl daemon-reload
systemctl enable comfyui-multitenant.service
checkpoint "SERVICES_CREATED"


# --- 8. FINAL AMI CLEANUP ---
echo "🧹 Finalizing and cleaning up for AMI creation..."

# Stop services that shouldn't be running in the AMI
systemctl stop comfyui-multitenant.service || true
systemctl stop docker.service || true

# Clean apt cache
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*

# Clear logs and shell history
find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
history -c
> ~/.bash_history

# Signal completion
echo "AMI_PREPARATION_COMPLETE" > /tmp/ami_ready.txt
checkpoint "AMI_PREPARATION_COMPLETE"

echo ""
echo "🚀🚀🚀 AMI preparation completed successfully! 🚀🚀🚀"
echo ""
echo "Ready to create AMI."
echo "Use 'comfyui-monitor' command on new instances to check status."