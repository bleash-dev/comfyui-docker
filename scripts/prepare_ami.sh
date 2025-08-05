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

# --- 7. SETUP APPLICATION DIRECTORIES ---
echo "📁 Setting up application directories..."

# Create required directories
mkdir -p /var/log/comfyui /workspace /scripts /opt/venv
chmod 755 /var/log/comfyui /workspace /scripts /opt/venv

# Set environment variables for ComfyUI
echo 'export DEBIAN_FRONTEND=noninteractive' >> /etc/environment
echo 'export PYTHONUNBUFFERED=1' >> /etc/environment
echo 'export PYTHON_VERSION=3.10' >> /etc/environment
echo 'export XPU_TARGET=NVIDIA_GPU' >> /etc/environment


checkpoint "DIRECTORIES_CREATED"

# --- 8. DOWNLOAD AND SETUP SCRIPTS ---
echo "📋 Downloading and setting up scripts..."

# Determine environment and S3 path based on available information
ENVIRONMENT="${ENVIRONMENT:-dev}"  # Default to dev if not set
AWS_REGION="${AWS_REGION:-us-east-1}"  # Use environment variable or default
S3_PREFIX="${S3_PREFIX:-s3://viral-comm-api-ec2-deployments-dev/comfyui-ami/${ENVIRONMENT}}"

echo "🌍 Environment: $ENVIRONMENT"
echo "🌎 AWS Region: $AWS_REGION"
echo "📦 S3 Path: $S3_PREFIX"

# Create scripts directory
mkdir -p /scripts
cd /scripts

# Download all scripts from S3
echo "📥 Downloading all scripts from S3..."
echo "🔍 Testing AWS CLI access first..."
if ! aws sts get-caller-identity --region "${AWS_REGION}" >/dev/null 2>&1; then
    echo "❌ AWS CLI access test failed"
    echo "🔍 Checking AWS credentials and permissions..."
    echo "Current user: $(whoami)"
    echo "AWS CLI version: $(aws --version 2>&1 || echo 'AWS CLI not found')"
    echo "Environment variables:"
    env | grep -E "AWS|EC2" || echo "No AWS environment variables found"
    exit 1
fi

echo "✅ AWS CLI access confirmed"
echo "🔄 Syncing scripts from S3..."

if aws s3 sync "${S3_PREFIX}/" . --region "${AWS_REGION}"; then
    echo "✅ Downloaded all scripts from S3"
    echo "📋 Downloaded files:"
    ls -la
else
    echo "❌ Failed to download scripts from S3"
    echo "🔍 S3 access details:"
    echo "  S3 Path: ${S3_PREFIX}"
    echo "  AWS Region: ${AWS_REGION}"
    echo "  Current directory: $(pwd)"
    echo "🔍 Checking what we have locally..."
    ls -la . || echo "No files found"
    echo "🔍 Attempting to list S3 bucket contents..."
    aws s3 ls "${S3_PREFIX}/" --region "${AWS_REGION}" || echo "Cannot list S3 contents"
    echo "⚠️ This is a critical error - AMI preparation cannot continue without scripts"
    exit 1
fi

# Verify essential files are present and not empty
echo "🔍 Verifying essential files are present and valid..."
REQUIRED_FILES=("tenant_manager.py")
MISSING_FILES=()
EMPTY_FILES=()

for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        MISSING_FILES+=("$file")
    elif [ ! -s "$file" ]; then
        EMPTY_FILES+=("$file")
    fi
done

if [ ${#MISSING_FILES[@]} -gt 0 ]; then
    echo "❌ Missing required files: ${MISSING_FILES[*]}"
    echo "🔍 Available files:"
    ls -la
    exit 1
fi

if [ ${#EMPTY_FILES[@]} -gt 0 ]; then
    echo "❌ Empty required files: ${EMPTY_FILES[*]}"
    echo "🔍 File sizes:"
    ls -la "${EMPTY_FILES[@]}"
    exit 1
fi

echo "✅ All essential files are present and valid"

# Install tenant manager
echo "📦 Installing tenant manager..."
cp tenant_manager.py /usr/local/bin/tenant_manager.py
chmod +x /usr/local/bin/tenant_manager.py

# Verify tenant manager installation
if [ -f "/usr/local/bin/tenant_manager.py" ] && [ -s "/usr/local/bin/tenant_manager.py" ]; then
    echo "✅ Tenant manager installed successfully"
    echo "📊 Tenant manager file info:"
    ls -la /usr/local/bin/tenant_manager.py
    
    # Test that the tenant manager can be imported
    echo "🧪 Testing tenant manager import..."
    if python3 -c "import sys; sys.path.append('/usr/local/bin'); import tenant_manager; print('Import successful')" 2>/dev/null; then
        echo "✅ Tenant manager import test passed"
    else
        echo "⚠️ Tenant manager import test failed, but continuing..."
    fi
else
    echo "❌ Tenant manager installation failed"
    echo "🔍 Checking installation..."
    ls -la /usr/local/bin/tenant_manager.py 2>/dev/null || echo "File not found"
    exit 1
fi

# Make all scripts executable
echo "🔧 Making all scripts executable..."
find /scripts -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
find /scripts -name "*.py" -exec chmod +x {} \; 2>/dev/null || true

# Verify permissions
echo "📋 Script permissions:"
ls -la /scripts/*.sh /scripts/*.py 2>/dev/null || echo "No shell/python scripts found"

echo "✅ Scripts setup completed"

checkpoint "SCRIPTS_SETUP"

# --- 9. CONFIGURE CLOUDWATCH ---
echo "📡 Configuring CloudWatch..."
if [ -f "/scripts/setup_cloudwatch.sh" ]; then
    echo "🔧 Running CloudWatch setup script..."
    bash /scripts/setup_cloudwatch.sh
    checkpoint "CLOUDWATCH_CONFIGURED"
else
    echo "⚠️ CloudWatch setup script not found, skipping..."
    checkpoint "CLOUDWATCH_SKIPPED"
fi

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
echo "AMI_SETUP_COMPLETE" > /tmp/ami_ready.txt
checkpoint "AMI_SETUP_COMPLETE"

echo ""
echo "🚀🚀🚀 AMI preparation completed successfully! 🚀🚀🚀"
echo ""
echo "Ready to create AMI."
echo "Use 'comfyui-monitor' command on new instances to check status."