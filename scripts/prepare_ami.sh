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

# Kill any lingering apt processes to prevent locks
pkill -f apt-get || true
pkill -f dpkg || true
sleep 3

# Wait for apt locks to be released
timeout 60 bash -c 'while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do echo "⏳ Waiting for dpkg lock..."; sleep 2; done'

# Configure apt for non-interactive use using robust echo commands
APT_CONFIG_FILE="/etc/apt/apt.conf.d/90-noninteractive"
echo 'APT::Get::Assume-Yes "true";' > "$APT_CONFIG_FILE"
echo 'APT::Get::AllowUnauthenticated "true";' >> "$APT_CONFIG_FILE"
echo 'DPkg::Options "--force-confdef";' >> "$APT_CONFIG_FILE"
echo 'DPkg::Options "--force-confold";' >> "$APT_CONFIG_FILE"
echo 'DPkg::Use-Pty "0";' >> "$APT_CONFIG_FILE"

# Update package lists
apt-get update -y
checkpoint "PACKAGE_MANAGEMENT_READY"


# --- 3. INSTALL ALL DEPENDENCIES ---
echo "🧩 Installing all required packages one by one for debugging..."

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
DOCKER_IMAGE="${COMFYUI_DOCKER_IMAGE:?ERROR: COMFYUI_DOCKER_IMAGE is not set}"
echo "📝 Using Docker image: $DOCKER_IMAGE"

# Login to ECR if necessary
if [[ "$DOCKER_IMAGE" == *"ecr"* ]]; then
    echo "🔐 Logging into ECR..."
    # Use || true to prevent script exit if login fails (e.g., for public images)
    aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws || true
fi

echo "⬇️ Pulling Docker image: $DOCKER_IMAGE"
docker pull "$DOCKER_IMAGE"
docker tag "$DOCKER_IMAGE" comfyui-multitenant:latest
docker images | grep comfyui-multitenant
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