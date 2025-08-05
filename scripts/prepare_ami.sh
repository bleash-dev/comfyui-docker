#!/bin/bash
#
# AMI Preparation Script for Multi-Tenant ComfyUI (Docker-Free)
# Installs everything directly on the AMI instance
#

# Exit immediately if a command exits with a non-zero status.
# Print each command before executing it.
set -ex

# --- 1. INITIAL SETUP ---
echo "🏗️ Preparing EC2 instance for ComfyUI AMI creation (Docker-Free)..."

# Docker image parameter is now optional (we're not using Docker)
DOCKER_IMAGE="$1"
if [ -n "$DOCKER_IMAGE" ]; then
    echo "📝 Note: Docker image parameter provided but not used in Docker-free setup: $DOCKER_IMAGE"
fi

# Set up unified logging
LOG_FILE="/var/log/ami-preparation.log"
exec &> >(tee -a "$LOG_FILE")

echo "=== AMI Preparation Started (Docker-Free) - $(date) ==="

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

# Configure apt for non-interactive use
APT_CONFIG_FILE="/etc/apt/apt.conf.d/90-noninteractive"
echo 'APT::Get::Assume-Yes "true";' > "$APT_CONFIG_FILE"
echo 'APT::Get::AllowUnauthenticated "true";' >> "$APT_CONFIG_FILE"
echo 'DPkg::Options "--force-confdef";' >> "$APT_CONFIG_FILE"
echo 'DPkg::Options "--force-confold";' >> "$APT_CONFIG_FILE"
echo 'DPkg::Use-Pty "0";' >> "$APT_CONFIG_FILE"

# --- 3. INSTALL SYSTEM DEPENDENCIES (from Dockerfile) ---
echo "📦 Installing system dependencies..."

# Update package list
apt-get update

# Install all system packages from Dockerfile
apt-get install -y --no-install-recommends \
    git \
    python3.10 \
    python3.10-venv \
    python3-pip \
    wget \
    nano \
    curl \
    zstd \
    openssh-server \
    xxd \
    libgl1-mesa-glx \
    libglib2.0-0 \
    libxrandr-dev \
    libxinerama-dev \
    xvfb \
    pv \
    libxcursor-dev \
    libnss3 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libatspi2.0-0 \
    libxcomposite1 \
    libxdamage1 \
    libxi-dev \
    libgl1-mesa-dev \
    libglu1-mesa-dev \
    ffmpeg \
    libsm6 \
    libxext6 \
    tree \
    zip \
    unzip \
    ca-certificates \
    inotify-tools \
    jq \
    bc \
    vim \
    htop \
    lsof \
    net-tools

# Clean up package cache
rm -rf /var/lib/apt/lists/*

checkpoint "SYSTEM_PACKAGES_INSTALLED"

# --- 3.5. INSTALL NVIDIA GPU DRIVERS AND CUDA RUNTIME ---
echo "🎮 Installing NVIDIA GPU drivers and CUDA runtime for optimal GPU utilization..."

# Add NVIDIA package repositories
echo "📦 Adding NVIDIA package repositories..."
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.0-1_all.deb
dpkg -i cuda-keyring_1.0-1_all.deb
rm cuda-keyring_1.0-1_all.deb

# Update package list with NVIDIA repos
apt-get update

# Install NVIDIA driver (will install the latest compatible version)
echo "🔧 Installing NVIDIA GPU drivers..."
apt-get install -y --no-install-recommends \
    nvidia-driver-535 \
    nvidia-dkms-535

# Install CUDA toolkit and runtime (11.8 to match original Docker setup)
echo "🔧 Installing CUDA 11.8 runtime and toolkit..."
apt-get install -y --no-install-recommends \
    cuda-runtime-11-8 \
    cuda-toolkit-11-8 \
    libcudnn8 \
    libcudnn8-dev

# Install additional NVIDIA container runtime libraries for compatibility
echo "🔧 Installing NVIDIA container runtime libraries..."
apt-get install -y --no-install-recommends \
    libnvidia-encode-535 \
    libnvidia-decode-535 \
    nvidia-utils-535

# Set up CUDA environment variables
echo "⚙️ Setting up CUDA environment variables..."
echo 'export CUDA_VERSION=11.8' >> /etc/environment
echo 'export CUDA_HOME=/usr/local/cuda-11.8' >> /etc/environment
echo 'export PATH=/usr/local/cuda-11.8/bin:$PATH' >> /etc/environment
echo 'export LD_LIBRARY_PATH=/usr/local/cuda-11.8/lib64:$LD_LIBRARY_PATH' >> /etc/environment
echo 'export NVIDIA_VISIBLE_DEVICES=all' >> /etc/environment
echo 'export NVIDIA_DRIVER_CAPABILITIES=compute,utility' >> /etc/environment

# Create symbolic links for CUDA
ln -sf /usr/local/cuda-11.8 /usr/local/cuda

# Clean up package cache
rm -rf /var/lib/apt/lists/*

echo "✅ NVIDIA GPU drivers and CUDA runtime installed"

# Verify GPU installation (non-blocking)
echo "🔍 Verifying GPU installation..."
if command -v nvidia-smi >/dev/null 2>&1; then
    echo "✅ nvidia-smi is available"
    # Don't run nvidia-smi on AMI build instance as it may not have GPU
    echo "ℹ️ GPU verification will be completed on GPU-enabled instances"
else
    echo "⚠️ nvidia-smi not found - GPU drivers may not be properly installed"
fi

if [ -d "/usr/local/cuda-11.8" ]; then
    echo "✅ CUDA 11.8 installation directory found"
else
    echo "⚠️ CUDA 11.8 installation directory not found"
fi

checkpoint "GPU_CUDA_INSTALLED"


# --- 4. INSTALL PYTHON PACKAGES ---
echo "� Installing Python packages..."

# Create symbolic links for python commands
ln -sf /usr/bin/python3.10 /usr/bin/python3
ln -sf /usr/bin/python3.10 /usr/bin/python

# Install Python packages for multi-tenant management
python3 -m pip install --no-cache-dir \
    psutil \
    boto3 \
    requests

checkpoint "PYTHON_PACKAGES_INSTALLED"

# --- 5. INSTALL AWS CLI v2 ---
echo "☁️ Installing AWS CLI v2..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf awscliv2.zip aws/

checkpoint "AWS_CLI_INSTALLED"

# --- 6. INSTALL CLOUDWATCH AGENT ---
echo "📡 Installing CloudWatch Agent..."
CW_AGENT_DEB="/tmp/amazon-cloudwatch-agent.deb"
wget -q -O "$CW_AGENT_DEB" \
    https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i "$CW_AGENT_DEB" || apt-get install -f -y
rm -f "$CW_AGENT_DEB"

checkpoint "CLOUDWATCH_AGENT_INSTALLED"

# --- 7. CONFIGURE CLOUDWATCH ---
echo "📡 Configuring CloudWatch..."
if [ -f "/scripts/setup_cloudwatch.sh" ]; then
    bash /scripts/setup_cloudwatch.sh
    checkpoint "CLOUDWATCH_CONFIGURED"
else
    echo "⚠️ CloudWatch setup script not found, skipping..."
    checkpoint "CLOUDWATCH_SKIPPED"
fi

# --- 8. SETUP APPLICATION DIRECTORIES ---
echo "📁 Setting up application directories..."

# Create required directories
mkdir -p /var/log/comfyui /workspace /scripts /opt/venv
chmod 755 /var/log/comfyui /workspace /scripts /opt/venv

# Set environment variables for ComfyUI
echo 'export DEBIAN_FRONTEND=noninteractive' >> /etc/environment
echo 'export PYTHONUNBUFFERED=1' >> /etc/environment
echo 'export PYTHON_VERSION=3.10' >> /etc/environment
echo 'export XPU_TARGET=NVIDIA_GPU' >> /etc/environment
echo 'export VENV_DIR=/opt/venv' >> /etc/environment
echo 'export COMFYUI_VENV=/opt/venv/comfyui' >> /etc/environment

checkpoint "DIRECTORIES_CREATED"

# --- 9. DOWNLOAD AND SETUP SCRIPTS ---
echo "📋 Downloading and setting up scripts..."

# Determine environment and S3 path based on available information
ENVIRONMENT="${ENVIRONMENT:-dev}"  # Default to dev if not set
S3_PREFIX="${S3_PREFIX:-s3://viral-comm-api-ec2-deployments-dev/comfy-docker/${ENVIRONMENT}}"

echo "🌍 Environment: $ENVIRONMENT"
echo "📦 S3 Path: $S3_PREFIX"

# Create scripts directory
mkdir -p /scripts /tmp/downloaded_scripts
cd /tmp/downloaded_scripts

# Download all required scripts from S3
echo "📥 Downloading scripts from S3..."
if aws s3 cp "${S3_PREFIX}/tenant_manager.py" tenant_manager.py --region us-east-1; then
    echo "✅ Downloaded tenant_manager.py"
else
    echo "⚠️ Failed to download tenant_manager.py from S3, checking if it exists locally..."
    if [ -f "/scripts/tenant_manager.py" ]; then
        cp /scripts/tenant_manager.py tenant_manager.py
        echo "✅ Using local tenant_manager.py"
    else
        echo "❌ tenant_manager.py not found in S3 or locally"
        exit 1
    fi
fi

# Download other scripts
for script in "setup_cloudwatch.sh" "create_s3_interactor.sh"; do
    if aws s3 cp "${S3_PREFIX}/${script}" "${script}" --region us-east-1; then
        echo "✅ Downloaded ${script}"
    else
        echo "⚠️ Failed to download ${script} from S3, checking locally..."
        if [ -f "/scripts/${script}" ]; then
            cp "/scripts/${script}" "${script}"
            echo "✅ Using local ${script}"
        else
            echo "⚠️ ${script} not found in S3 or locally, skipping..."
        fi
    fi
done

# Install tenant manager
if [ -f "tenant_manager.py" ]; then
    cp tenant_manager.py /usr/local/bin/tenant_manager.py
    chmod +x /usr/local/bin/tenant_manager.py
    echo "✅ Tenant manager installed"
else
    echo "❌ tenant_manager.py not available"
    exit 1
fi

# Copy all other scripts to /scripts directory
cp -f * /scripts/ 2>/dev/null || true
find /scripts -name "*.sh" -exec chmod +x {} \;
find /scripts -name "*.py" -exec chmod +x {} \;

echo "✅ Scripts setup completed"

checkpoint "SCRIPTS_SETUP"

# --- 10. CREATE SYSTEM SERVICES (Docker-Free) ---
echo "⚙️ Creating systemd services..."

# Create a systemd service for ComfyUI Tenant Manager (Direct Python execution)
cat > /etc/systemd/system/comfyui-multitenant.service << 'EOF'
[Unit]
Description=ComfyUI Multi-Tenant Manager (Direct)
After=network.target

[Service]
Type=simple
Restart=always
RestartSec=10s
User=root
WorkingDirectory=/workspace

# Environment variables
Environment=DEBIAN_FRONTEND=noninteractive
Environment=PYTHONUNBUFFERED=1
Environment=PYTHON_VERSION=3.10
Environment=XPU_TARGET=NVIDIA_GPU
Environment=VENV_DIR=/opt/venv
Environment=COMFYUI_VENV=/opt/venv/comfyui
Environment=CUDA_VERSION=11.8
Environment=CUDA_HOME=/usr/local/cuda-11.8
Environment=PATH=/usr/local/cuda-11.8/bin:/usr/local/bin:/usr/bin:/bin
Environment=LD_LIBRARY_PATH=/usr/local/cuda-11.8/lib64
Environment=NVIDIA_VISIBLE_DEVICES=all
Environment=NVIDIA_DRIVER_CAPABILITIES=compute,utility

# The main command to run the tenant manager directly
ExecStart=/usr/bin/python3 /usr/local/bin/tenant_manager.py

# Log to journal and file
StandardOutput=journal
StandardError=journal
SyslogIdentifier=comfyui-multitenant

[Install]
WantedBy=multi-user.target
EOF

# Create a monitoring script (updated for direct execution)
cat > /usr/local/bin/comfyui-monitor << 'EOF'
#!/bin/bash
echo "--- ComfyUI System Status (Direct) ---"
echo; echo "--- ComfyUI Service Status ---"
systemctl status comfyui-multitenant
echo; echo "--- GPU Status ---"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=index,name,driver_version,memory.total,memory.used,utilization.gpu,temperature.gpu --format=csv,noheader,nounits 2>/dev/null || echo "GPU not available or no NVIDIA driver loaded"
else
    echo "nvidia-smi not found"
fi
echo; echo "--- CUDA Version ---"
if [ -f /usr/local/cuda/version.txt ]; then
    cat /usr/local/cuda/version.txt
elif command -v nvcc >/dev/null 2>&1; then
    nvcc --version | grep "release"
else
    echo "CUDA not found"
fi
echo; echo "--- System Resources ---"
df -h /; free -h
echo; echo "--- Python Processes ---"
ps aux | grep -E "(python|tenant_manager)" | grep -v grep
echo; echo "--- Network Connections ---"
ss -tulpn | grep -E ":(80|8[0-9]{3})\s"
echo; echo "--- Recent ComfyUI Logs ---"
journalctl -u comfyui-multitenant --no-pager -n 20
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

# --- 11. FINAL AMI CLEANUP ---
echo "🧹 Finalizing and cleaning up for AMI creation..."

# Stop services that shouldn't be running in the AMI
systemctl stop comfyui-multitenant.service || true

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