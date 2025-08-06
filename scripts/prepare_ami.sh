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

# Set up unified logging with CloudWatch integration
LOG_FILE="/var/log/ami-preparation.log"
CLOUDWATCH_LOG_GROUP="/comfyui/ami-preparation"
CLOUDWATCH_LOG_STREAM="ami-build-$(date +%Y%m%d-%H%M%S)"

# Ensure log directory exists
mkdir -p /var/log

# Function to setup logging with CloudWatch
setup_logging() {
    echo "📝 Setting up comprehensive logging with CloudWatch integration..."
    
    # Create log file with proper permissions
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    
    # Setup logging to capture all output
    exec 1> >(tee -a "$LOG_FILE")
    exec 2> >(tee -a "$LOG_FILE" >&2)
    
    echo "=== AMI Preparation Started (Docker-Free) - $(date) ===" | tee -a "$LOG_FILE"
    echo "📍 Log file: $LOG_FILE" | tee -a "$LOG_FILE"
    echo "☁️ CloudWatch Log Group: $CLOUDWATCH_LOG_GROUP" | tee -a "$LOG_FILE"
    echo "📊 CloudWatch Log Stream: $CLOUDWATCH_LOG_STREAM" | tee -a "$LOG_FILE"
}

# Initialize logging
setup_logging

# Checkpoint function for progress tracking
checkpoint() {
    local checkpoint_name="$1"
    local timestamp=$(date)
    
    echo "✅ CHECKPOINT: $checkpoint_name completed at $timestamp" | tee -a "$LOG_FILE"
    
    # Append to checkpoint history instead of overwriting
    echo "$checkpoint_name" >> /tmp/ami_checkpoints.txt
    
    # Keep the current checkpoint for compatibility
    echo "$checkpoint_name" > /tmp/ami_progress.txt
    
    # Sync logs to CloudWatch immediately after each checkpoint
    sync_logs_to_cloudwatch || echo "⚠️ CloudWatch sync failed for checkpoint: $checkpoint_name" | tee -a "$LOG_FILE"
}

# Function to sync logs to CloudWatch
sync_logs_to_cloudwatch() {
    if command -v aws >/dev/null 2>&1; then
        echo "☁️ Syncing logs to CloudWatch..." | tee -a "$LOG_FILE"
        
        # Create log group if it doesn't exist
        aws logs create-log-group --log-group-name "$CLOUDWATCH_LOG_GROUP" 2>/dev/null || true
        
        # Create log stream if it doesn't exist
        aws logs create-log-stream --log-group-name "$CLOUDWATCH_LOG_GROUP" --log-stream-name "$CLOUDWATCH_LOG_STREAM" 2>/dev/null || true
        
        # Send recent log entries to CloudWatch
        if [ -f "$LOG_FILE" ]; then
            # Get the last 100 lines and send to CloudWatch
            tail -100 "$LOG_FILE" | while IFS= read -r line; do
                local timestamp=$(date +%s%3N)
                aws logs put-log-events \
                    --log-group-name "$CLOUDWATCH_LOG_GROUP" \
                    --log-stream-name "$CLOUDWATCH_LOG_STREAM" \
                    --log-events timestamp="$timestamp",message="$line" \
                    >/dev/null 2>&1 || true
            done
        fi
        
        echo "✅ Logs synced to CloudWatch" | tee -a "$LOG_FILE"
        return 0
    else
        echo "⚠️ AWS CLI not available for CloudWatch sync" | tee -a "$LOG_FILE"
        return 1
    fi
}
checkpoint "AMI_PREP_STARTED"

# --- 2. PACKAGE MANAGEMENT SETUP ---
echo "📦 Preparing package manager (apt)..." | tee -a "$LOG_FILE"
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Aggressive APT lock handling - use timeout and force clear
echo "🔧 Clearing APT locks aggressively..." | tee -a "$LOG_FILE"

# Force kill any apt/dpkg processes
echo "🔪 Force killing any existing apt/dpkg processes..." | tee -a "$LOG_FILE"
timeout 10 pkill -9 -f apt-get || true
timeout 10 pkill -9 -f dpkg || true
timeout 10 pkill -9 -f unattended-upgrade || true
timeout 10 pkill -9 -f packagekit || true
sleep 3

# Remove lock files directly (will be recreated)
echo "🗑️ Removing lock files..." | tee -a "$LOG_FILE"
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

# --- 6.5. SETUP EPHEMERAL DISK MOUNTING ---
echo "💾 Setting up ephemeral disk mounting for /workspace..."

# Create ephemeral disk mounting script
cat > /usr/local/bin/mount-ephemeral-storage << 'EOF'
#!/bin/bash
# Ephemeral Storage Mounting Script for ComfyUI
# Automatically detects and mounts NVMe ephemeral storage to /workspace

set -e

MOUNT_POINT="/workspace"
LOG_FILE="/var/log/ephemeral-mount.log"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_message "Starting ephemeral storage setup..."

# Ensure mount point exists
if [ ! -d "$MOUNT_POINT" ]; then
    log_message "Creating mount point: $MOUNT_POINT"
    mkdir -p "$MOUNT_POINT"
fi

# Check if already mounted
if mount | grep -q "$MOUNT_POINT"; then
    EXISTING_MOUNT=$(mount | grep "$MOUNT_POINT" | awk '{print $1}')
    log_message "Mount point already in use by: $EXISTING_MOUNT"
    exit 0
fi

# Find ephemeral NVMe devices (exclude root device)
log_message "Detecting available NVMe ephemeral devices..."

# Get the root device to exclude it
ROOT_DEVICE=$(lsblk -no PKNAME $(findmnt -n -o SOURCE /))
log_message "Root device to exclude: $ROOT_DEVICE"

# Find available NVMe devices that are not the root device and not already mounted
AVAILABLE_NVME_DEVICES=$(lsblk -ndo NAME,TYPE,MOUNTPOINT | grep 'disk' | grep 'nvme' | grep -v "$ROOT_DEVICE" | awk '$3=="" {print $1}')

if [ -z "$AVAILABLE_NVME_DEVICES" ]; then
    log_message "No available ephemeral NVMe devices found"
    log_message "Available block devices:"
    lsblk | tee -a "$LOG_FILE"
    exit 0
fi

# Use the first available NVMe device
NVME_DEVICE=$(echo "$AVAILABLE_NVME_DEVICES" | head -n1)
DEVICE_PATH="/dev/$NVME_DEVICE"

log_message "Selected ephemeral device: $DEVICE_PATH"

# Get device info
DEVICE_SIZE=$(lsblk -ndo SIZE "$DEVICE_PATH" 2>/dev/null || echo "unknown")
log_message "Device size: $DEVICE_SIZE"

# Check if device needs formatting
if ! blkid "$DEVICE_PATH" >/dev/null 2>&1; then
    log_message "Device $DEVICE_PATH is not formatted, formatting with ext4..."
    mkfs.ext4 -F "$DEVICE_PATH" || {
        log_message "ERROR: Failed to format $DEVICE_PATH"
        exit 1
    }
    log_message "Formatting completed successfully"
else
    EXISTING_FS=$(blkid -o value -s TYPE "$DEVICE_PATH")
    log_message "Device $DEVICE_PATH already formatted with: $EXISTING_FS"
fi

# Mount the device
log_message "Mounting $DEVICE_PATH to $MOUNT_POINT..."
mount "$DEVICE_PATH" "$MOUNT_POINT" || {
    log_message "ERROR: Failed to mount $DEVICE_PATH to $MOUNT_POINT"
    exit 1
}

# Set proper permissions
chown root:root "$MOUNT_POINT"
chmod 755 "$MOUNT_POINT"

# Verify mount
if mount | grep -q "$MOUNT_POINT"; then
    MOUNTED_DEVICE=$(mount | grep "$MOUNT_POINT" | awk '{print $1}')
    MOUNT_SIZE=$(df -h "$MOUNT_POINT" | tail -1 | awk '{print $2}')
    log_message "SUCCESS: $MOUNTED_DEVICE mounted to $MOUNT_POINT (Size: $MOUNT_SIZE)"
    
    # Show mount details
    log_message "Mount details:"
    df -h "$MOUNT_POINT" | tee -a "$LOG_FILE"
else
    log_message "ERROR: Mount verification failed"
    exit 1
fi

log_message "Ephemeral storage setup completed successfully"
EOF

# Make the script executable
chmod +x /usr/local/bin/mount-ephemeral-storage

# Create systemd service for ephemeral mounting
cat > /etc/systemd/system/mount-ephemeral-storage.service << 'EOF'
[Unit]
Description=Mount Ephemeral Storage for ComfyUI
DefaultDependencies=false
After=local-fs-pre.target
Before=local-fs.target
Wants=local-fs-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mount-ephemeral-storage
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=local-fs.target
EOF

# Enable the service
systemctl daemon-reload
systemctl enable mount-ephemeral-storage.service

echo "✅ Ephemeral disk mounting setup completed"
echo "   🔧 Mount script: /usr/local/bin/mount-ephemeral-storage"
echo "   ⚙️ Systemd service: mount-ephemeral-storage.service"
echo "   📍 Mount point: /workspace"

# Test the mounting script during AMI creation
echo "🧪 Testing ephemeral storage mounting during AMI creation..."
/usr/local/bin/mount-ephemeral-storage || {
    echo "⚠️ Ephemeral storage mounting failed during AMI creation"
    echo "   This is expected on instances without ephemeral storage"
    echo "   The service will work on instances with NVMe ephemeral storage"
}

checkpoint "EPHEMERAL_STORAGE_SETUP"

# --- 7. INSTALL BASE COMFYUI ENVIRONMENT ---
echo "🎨 Installing base ComfyUI environment for shared use..."

# Set up environment variables for ComfyUI installation
export NETWORK_VOLUME="/base"
export PYTORCH_VERSION="2.4.0"
export GIT_BRANCH="${GIT_BRANCH:-main}"

# Create base directories
echo "📁 Creating base directories..."
mkdir -p /base/venv
mkdir -p /base
chmod 755 /base /base/venv

# Run the setup_components script to install ComfyUI and dependencies
echo "🔧 Running setup_components.sh to install ComfyUI base environment..." | tee -a "$LOG_FILE"
if [ -f "/scripts/setup_components.sh" ]; then
    # Make sure the script is executable
    chmod +x /scripts/setup_components.sh
    
    echo "📋 Starting setup_components.sh execution with full logging..." | tee -a "$LOG_FILE"
    echo "=== SETUP_COMPONENTS.SH OUTPUT START ===" | tee -a "$LOG_FILE"
    
    # Run the setup script with all output captured to our log file
    if bash /scripts/setup_components.sh 2>&1 | tee -a "$LOG_FILE"; then
        echo "=== SETUP_COMPONENTS.SH OUTPUT END ===" | tee -a "$LOG_FILE"
        echo "✅ Base ComfyUI environment installed successfully" | tee -a "$LOG_FILE"
        echo "   📍 Virtual environment: /base/venv/comfyui" | tee -a "$LOG_FILE"
        echo "   📍 ComfyUI installation: /base/ComfyUI" | tee -a "$LOG_FILE"
        echo "   🎯 Ready for tenant copying at runtime" | tee -a "$LOG_FILE"
        
        # Verify installation was successful
        echo "🔍 Verifying ComfyUI base installation..." | tee -a "$LOG_FILE"
        if [ -d "/base/venv/comfyui" ] && [ -f "/base/venv/comfyui/bin/python" ]; then
            echo "✅ Base virtual environment created successfully" | tee -a "$LOG_FILE"
            echo "   📦 Python executable: /base/venv/comfyui/bin/python" | tee -a "$LOG_FILE"
        else
            echo "❌ Base virtual environment validation failed" | tee -a "$LOG_FILE"
            echo "   🔍 Checking /base directory contents:" | tee -a "$LOG_FILE"
            ls -la /base/ 2>&1 | tee -a "$LOG_FILE" || echo "Cannot list /base directory" | tee -a "$LOG_FILE"
            exit 1
        fi
        
        if [ -d "/base/ComfyUI" ] && [ -f "/base/ComfyUI/main.py" ]; then
            echo "✅ Base ComfyUI installation validated successfully" | tee -a "$LOG_FILE"
            echo "   🎨 ComfyUI main.py: /base/ComfyUI/main.py" | tee -a "$LOG_FILE"
            
            # Show installation size
            COMFYUI_SIZE=$(du -sh /base/ComfyUI 2>/dev/null | cut -f1 || echo "unknown")
            VENV_SIZE=$(du -sh /base/venv/comfyui 2>/dev/null | cut -f1 || echo "unknown")
            echo "   � ComfyUI installation size: $COMFYUI_SIZE" | tee -a "$LOG_FILE"
            echo "   📊 Virtual environment size: $VENV_SIZE" | tee -a "$LOG_FILE"
        else
            echo "❌ Base ComfyUI installation validation failed" | tee -a "$LOG_FILE"
            echo "   🔍 Checking /base/ComfyUI directory:" | tee -a "$LOG_FILE"
            ls -la /base/ComfyUI/ 2>&1 | tee -a "$LOG_FILE" || echo "Cannot list /base/ComfyUI directory" | tee -a "$LOG_FILE"
            exit 1
        fi
        
    else
        echo "=== SETUP_COMPONENTS.SH OUTPUT END (FAILED) ===" | tee -a "$LOG_FILE"
        echo "❌ setup_components.sh failed during AMI creation" | tee -a "$LOG_FILE"
        echo "🔍 Exit code: $?" | tee -a "$LOG_FILE"
        exit 1
    fi
    
else
    echo "❌ setup_components.sh not found in /scripts/" | tee -a "$LOG_FILE"
    echo "Available scripts:" | tee -a "$LOG_FILE"
    ls -la /scripts/ 2>&1 | tee -a "$LOG_FILE" || echo "Scripts directory not accessible" | tee -a "$LOG_FILE"
    exit 1
fi

checkpoint "COMFYUI_BASE_INSTALLED"

# --- 8. SETUP APPLICATION DIRECTORIES ---
echo "📁 Setting up application directories..."

# Create required directories
mkdir -p /var/log/comfyui /workspace /scripts /opt/venv
chmod 755 /var/log/comfyui /workspace /scripts /opt/venv

# Set environment variables for ComfyUI
echo 'export DEBIAN_FRONTEND=noninteractive' >> /etc/environment
echo 'export PYTHONUNBUFFERED=1' >> /etc/environment
echo 'export PYTHON_VERSION=3.10' >> /etc/environment

checkpoint "DIRECTORIES_CREATED"

# --- 9. DOWNLOAD AND SETUP SCRIPTS ---
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
    
    # Count files downloaded
    FILE_COUNT=$(find . -type f | wc -l)
    echo "📊 Total files downloaded: $FILE_COUNT"
    
    # Verify we got the essential files
    if [ "$FILE_COUNT" -eq 0 ]; then
        echo "❌ No files were downloaded from S3"
        echo "🔍 Attempting to list S3 bucket contents..."
        aws s3 ls "${S3_PREFIX}/" --region "${AWS_REGION}" || echo "Cannot list S3 contents"
        exit 1
    fi
    
    # Check for specific required files
    CRITICAL_FILES=("tenant_manager.py")
    for file in "${CRITICAL_FILES[@]}"; do
        if [ ! -f "$file" ]; then
            echo "⚠️ Critical file $file not found after S3 sync"
            echo "🔍 Checking if it exists in S3..."
            aws s3 ls "${S3_PREFIX}/$file" --region "${AWS_REGION}" || echo "File not found in S3"
        else
            FILE_SIZE=$(stat -c%s "$file")
            echo "✅ Found $file (size: $FILE_SIZE bytes)"
        fi
    done
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
    "⚠️ This is a critical error - AMI preparation cannot continue without scripts"
    exit 1
fi

# Verify essential files are present and not empty
echo "🔍 Verifying essential files are present and valid..."
echo "📍 Current working directory: $(pwd)"
echo "📋 All files in current directory:"
ls -la . | head -20

REQUIRED_FILES=("tenant_manager.py")
MISSING_FILES=()
EMPTY_FILES=()
CORRUPTED_FILES=()

for file in "${REQUIRED_FILES[@]}"; do
    echo "🔍 Checking $file..."
    if [ ! -f "$file" ]; then
        MISSING_FILES+=("$file")
        echo "❌ File $file is missing"
    elif [ ! -s "$file" ]; then
        EMPTY_FILES+=("$file")
        echo "❌ File $file exists but is empty"
    else
        # Check if it's a valid Python file
        if [[ "$file" == *.py ]]; then
            if head -1 "$file" | grep -q "python"; then
                FILE_SIZE=$(stat -c%s "$file")
                echo "✅ File $file looks valid (size: $FILE_SIZE bytes)"
            else
                CORRUPTED_FILES+=("$file")
                echo "❌ File $file doesn't look like a valid Python file"
                echo "🔍 First line: $(head -1 "$file")"
            fi
        else
            echo "✅ File $file exists and is not empty"
        fi
    fi
done

if [ ${#MISSING_FILES[@]} -gt 0 ]; then
    echo "❌ Missing required files: ${MISSING_FILES[*]}"
    echo "🔍 Available files:"
    ls -la
    echo "🔍 Checking if files are in different location:"
    find /scripts -name "tenant_manager.py" -ls 2>/dev/null || echo "No tenant_manager.py found anywhere"
    exit 1
fi

if [ ${#EMPTY_FILES[@]} -gt 0 ]; then
    echo "❌ Empty required files: ${EMPTY_FILES[*]}"
    echo "🔍 File details:"
    for file in "${EMPTY_FILES[@]}"; do
        ls -la "$file" 2>/dev/null || echo "Cannot stat $file"
    done
    exit 1
fi

if [ ${#CORRUPTED_FILES[@]} -gt 0 ]; then
    echo "❌ Corrupted or invalid files: ${CORRUPTED_FILES[*]}"
    echo "🔍 File details:"
    for file in "${CORRUPTED_FILES[@]}"; do
        echo "=== Content of $file (first 10 lines) ==="
        head -10 "$file" 2>/dev/null || echo "Cannot read $file"
        echo "=== End of $file preview ==="
    done
    exit 1
fi

echo "✅ All essential files are present and valid"

# Add checkpoint after successful script validation
checkpoint "SCRIPTS_DOWNLOADED_AND_VALIDATED"

# Install tenant manager
echo "📦 Installing tenant manager..."
echo "🔍 Current working directory: $(pwd)"
echo "📋 Available files in current directory:"
ls -la . | head -10

# Check if tenant_manager.py exists before copying
if [ ! -f "tenant_manager.py" ]; then
    echo "❌ CRITICAL: tenant_manager.py not found in current directory"
    echo "🔍 Listing all Python files in /scripts:"
    find /scripts -name "*.py" -ls
    exit 1
fi

echo "✅ Found tenant_manager.py, copying to /usr/local/bin/"
cp tenant_manager.py /usr/local/bin/tenant_manager.py
chmod +x /usr/local/bin/tenant_manager.py

# Verify tenant manager installation with detailed checks
echo "🔍 Verifying tenant manager installation..."
if [ -f "/usr/local/bin/tenant_manager.py" ] && [ -s "/usr/local/bin/tenant_manager.py" ]; then
    echo "✅ Tenant manager file exists and is not empty"
    echo "📊 Tenant manager file info:"
    ls -la /usr/local/bin/tenant_manager.py
    
    # Check file size and content
    FILE_SIZE=$(stat -c%s "/usr/local/bin/tenant_manager.py")
    echo "📏 File size: $FILE_SIZE bytes"
    
    if [ "$FILE_SIZE" -lt 1000 ]; then
        echo "⚠️ Warning: File seems too small (less than 1KB)"
        echo "🔍 File content preview:"
        head -5 /usr/local/bin/tenant_manager.py
    fi
    
    # Test Python interpreter
    echo "🐍 Testing Python interpreter..."
    python3 --version || {
        echo "❌ Python3 not working"
        exit 1
    }
    
    # Test required Python modules
    echo "📦 Testing required Python modules..."
    python3 -c "import psutil; print('psutil version:', psutil.__version__)" || {
        echo "❌ psutil module not available"
        exit 1
    }
    
    python3 -c "import boto3; print('boto3 version:', boto3.__version__)" || {
        echo "❌ boto3 module not available"
        exit 1
    }
    
    python3 -c "import requests; print('requests version:', requests.__version__)" || {
        echo "❌ requests module not available"
        exit 1
    }
    
    # Test that the tenant manager can be imported
    echo "🧪 Testing tenant manager import..."
    if python3 -c "import sys; sys.path.append('/usr/local/bin'); import tenant_manager; print('✅ Tenant manager import successful')" 2>&1; then
        echo "✅ Tenant manager import test passed"
    else
        echo "❌ Tenant manager import test failed"
        echo "🔍 Attempting detailed import debugging..."
        python3 -c "
import sys
sys.path.append('/usr/local/bin')
try:
    import tenant_manager
    print('Import worked unexpectedly')
except Exception as e:
    print(f'Import error: {e}')
    print(f'Error type: {type(e).__name__}')
" 2>&1
        exit 1
    fi
else
    echo "❌ Tenant manager installation failed"
    echo "🔍 Checking installation details..."
    
    if [ ! -f "/usr/local/bin/tenant_manager.py" ]; then
        echo "❌ File does not exist: /usr/local/bin/tenant_manager.py"
    elif [ ! -s "/usr/local/bin/tenant_manager.py" ]; then
        echo "❌ File exists but is empty: /usr/local/bin/tenant_manager.py"
        ls -la /usr/local/bin/tenant_manager.py
    fi
    
    echo "🔍 Checking source file:"
    ls -la tenant_manager.py 2>/dev/null || echo "Source file not found"
    
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

# --- 10. CONFIGURE CLOUDWATCH ---
echo "📡 Configuring CloudWatch..." | tee -a "$LOG_FILE"
if [ -f "/scripts/setup_cloudwatch.sh" ]; then
    echo "🔧 Running CloudWatch setup script..." | tee -a "$LOG_FILE"
    echo "=== SETUP_CLOUDWATCH.SH OUTPUT START ===" | tee -a "$LOG_FILE"
    
    if bash /scripts/setup_cloudwatch.sh 2>&1 | tee -a "$LOG_FILE"; then
        echo "=== SETUP_CLOUDWATCH.SH OUTPUT END ===" | tee -a "$LOG_FILE"
        echo "✅ CloudWatch setup completed successfully" | tee -a "$LOG_FILE"
        checkpoint "CLOUDWATCH_CONFIGURED"
    else
        echo "=== SETUP_CLOUDWATCH.SH OUTPUT END (WITH WARNINGS) ===" | tee -a "$LOG_FILE"
        echo "⚠️ CloudWatch setup encountered issues but continuing (non-fatal)" | tee -a "$LOG_FILE"
        checkpoint "CLOUDWATCH_CONFIGURED_WITH_WARNINGS"
    fi
else
    echo "⚠️ CloudWatch setup script not found, skipping..." | tee -a "$LOG_FILE"
    checkpoint "CLOUDWATCH_SKIPPED"
fi

# --- 11. CREATE SYSTEM SERVICES (Docker-Free) ---
echo "⚙️ Creating systemd services..."

# Create a systemd service for ComfyUI Tenant Manager (Direct Python execution)
cat > /etc/systemd/system/comfyui-multitenant.service << 'EOF'
[Unit]
Description=ComfyUI Multi-Tenant Manager
After=network.target
Wants=network-online.target
After=network-online.target

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

# Allow binding to privileged ports
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# The main command to run the tenant manager directly
ExecStart=/usr/bin/python3 /usr/local/bin/tenant_manager.py

# Log to journal and file
StandardOutput=journal
StandardError=journal
SyslogIdentifier=comfyui-multitenant

# Give the service more time to start (port 80 binding might take time)
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF

# Create a monitoring script (updated for direct execution)
cat > /usr/local/bin/comfyui-monitor << 'EOF'
#!/bin/bash
echo "--- ComfyUI System Status ---"
echo; echo "--- ComfyUI Service Status ---"
systemctl status comfyui-multitenant
echo; echo "--- Ephemeral Storage Status ---"
if mount | grep -q "/workspace"; then
  echo "✅ /workspace is mounted:"
  df -h /workspace
  echo "Mount details:"
  mount | grep /workspace
else
  echo "❌ /workspace is not mounted"
  echo "Available NVMe devices:"
  lsblk | grep nvme || echo "No NVMe devices found"
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

# Start the service temporarily for validation testing
echo "🚀 Starting tenant manager service for validation testing..."
systemctl start comfyui-multitenant.service
sleep 5  # Give it a moment to start

checkpoint "SERVICES_CREATED"

# --- 12. FINAL VALIDATION ---
echo "🔍 Performing final validation before AMI completion..."

VALIDATION_ERRORS=()

# Check tenant manager installation
if [ -f "/usr/local/bin/tenant_manager.py" ] && [ -s "/usr/local/bin/tenant_manager.py" ]; then
    echo "✅ Tenant manager file exists"
    
    # Test import
    if python3 -c "import sys; sys.path.append('/usr/local/bin'); import tenant_manager" 2>/dev/null; then
        echo "✅ Tenant manager can be imported"
    else
        VALIDATION_ERRORS+=("Tenant manager cannot be imported")
    fi
else
    VALIDATION_ERRORS+=("Tenant manager file missing or empty")
fi

# Check Python and required packages
if command -v python3 >/dev/null 2>&1; then
    echo "✅ Python3 is available"
    
    # Check required packages
    for package in psutil boto3 requests; do
        if python3 -c "import $package" 2>/dev/null; then
            echo "✅ Python package $package is available"
        else
            VALIDATION_ERRORS+=("Python package $package is missing")
        fi
    done
else
    VALIDATION_ERRORS+=("Python3 is not available")
fi

# Check systemd service
if [ -f "/etc/systemd/system/comfyui-multitenant.service" ]; then
    echo "✅ Systemd service file exists"
else
    VALIDATION_ERRORS+=("Systemd service file is missing")
fi

# Check ephemeral storage service
if [ -f "/etc/systemd/system/mount-ephemeral-storage.service" ]; then
    echo "✅ Ephemeral storage service exists"
    
    # Check if service is enabled
    if systemctl is-enabled mount-ephemeral-storage.service >/dev/null 2>&1; then
        echo "✅ Ephemeral storage service is enabled"
    else
        VALIDATION_ERRORS+=("Ephemeral storage service is not enabled")
    fi
    
    # Check if mount script exists
    if [ -f "/usr/local/bin/mount-ephemeral-storage" ] && [ -x "/usr/local/bin/mount-ephemeral-storage" ]; then
        echo "✅ Ephemeral storage mount script exists and is executable"
    else
        VALIDATION_ERRORS+=("Ephemeral storage mount script missing or not executable")
    fi
else
    VALIDATION_ERRORS+=("Ephemeral storage service is missing")
fi

# Check required directories
for dir in "/workspace" "/var/log/comfyui" "/scripts" "/base" "/base/venv/comfyui" "/base/ComfyUI"; do
    if [ -d "$dir" ]; then
        echo "✅ Directory $dir exists"
    else
        VALIDATION_ERRORS+=("Directory $dir is missing")
    fi
done

# Test the health endpoint since service should be running
echo "🏥 Testing health endpoint..."
sleep 3  # Give service a moment to be fully ready

# Check service status first
SERVICE_STATUS=$(systemctl is-active comfyui-multitenant.service 2>/dev/null || echo 'unknown')
echo "Initial service status: $SERVICE_STATUS"

# If service is activating, give it more time and check logs
if [ "$SERVICE_STATUS" = "activating" ]; then
    echo "⏳ Service is still activating, waiting additional 10 seconds..."
    sleep 10
    SERVICE_STATUS=$(systemctl is-active comfyui-multitenant.service 2>/dev/null || echo 'unknown')
    echo "Service status after wait: $SERVICE_STATUS"
    
    # Check service logs to understand what's happening
    echo "🔍 Checking service logs for activation issues..."
    journalctl -u comfyui-multitenant.service --no-pager -n 10 --since "2 minutes ago" || echo "No recent service logs"
fi

# If still not active, check for errors
if [ "$SERVICE_STATUS" != "active" ]; then
    echo "⚠️ Service not active, checking for errors..."
    echo "Full service status:"
    systemctl status comfyui-multitenant.service --no-pager || echo "Cannot get service status"
    echo "Recent logs:"
    journalctl -u comfyui-multitenant.service --no-pager -n 20 || echo "Cannot get service logs"
fi

HEALTH_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/health 2>/dev/null || echo "CURL_FAILED")
echo "Health endpoint HTTP status: $HEALTH_RESPONSE"

if [ "$HEALTH_RESPONSE" = "200" ]; then
    echo "✅ Health endpoint test passed"
else
    VALIDATION_ERRORS+=("Health endpoint test failed (status: $HEALTH_RESPONSE)")
    echo "🔍 Service debugging:"
    echo "Service status: $(systemctl is-active comfyui-multitenant.service 2>/dev/null || echo 'unknown')"
    echo "Port 80 listening: $(netstat -tlnp | grep :80 2>/dev/null || echo 'not found')"
fi

# Report validation results
if [ ${#VALIDATION_ERRORS[@]} -gt 0 ]; then
    echo "❌ VALIDATION FAILED - Cannot proceed with AMI creation"
    echo "Validation errors found:"
    for error in "${VALIDATION_ERRORS[@]}"; do
        echo "  ❌ $error"
    done
    
    echo ""
    echo "🔍 System debugging information:"
    echo "Python version: $(python3 --version 2>&1 || echo 'Not available')"
    echo "Pip packages: $(python3 -m pip list 2>/dev/null | head -10 || echo 'Cannot list packages')"
    echo "Tenant manager file: $(ls -la /usr/local/bin/tenant_manager.py 2>/dev/null || echo 'Not found')"
    echo "Available Python modules:"
    python3 -c "import sys; print('Python path:', sys.path)" 2>/dev/null || echo "Cannot check Python path"
    
    exit 1
else
    echo "🎉 All validation checks passed!"
fi

checkpoint "VALIDATION_COMPLETE"

# --- 13. FINAL AMI CLEANUP ---
echo "🧹 Finalizing and cleaning up for AMI creation..." | tee -a "$LOG_FILE"

# NOTE: We do NOT stop the service here because the GitHub Actions workflow

# Clean apt cache
echo "🧹 Cleaning apt cache..." | tee -a "$LOG_FILE"
apt-get autoremove -y 2>&1 | tee -a "$LOG_FILE"
apt-get clean 2>&1 | tee -a "$LOG_FILE"
rm -rf /var/lib/apt/lists/* 2>&1 | tee -a "$LOG_FILE"

# Final log sync before cleanup
echo "☁️ Performing final log sync to CloudWatch before cleanup..." | tee -a "$LOG_FILE"
sync_logs_to_cloudwatch || echo "⚠️ Final CloudWatch sync failed" | tee -a "$LOG_FILE"

# Create a comprehensive AMI preparation summary
echo "📋 Creating AMI preparation summary..." | tee -a "$LOG_FILE"
cat > /var/log/ami-summary.log << EOF
=== ComfyUI AMI Preparation Summary ===
Completion Time: $(date)
AMI Build Type: Docker-Free Multi-Tenant
Architecture: Shared Base Environment

Installed Components:
- Base ComfyUI: /base/ComfyUI
- Shared Virtual Environment: /base/venv/comfyui
- Tenant Manager: /usr/local/bin/tenant_manager.py
- Ephemeral Storage Service: mount-ephemeral-storage.service
- Multi-Tenant Service: comfyui-multitenant.service

System Configuration:
- Python Version: $(python3 --version 2>/dev/null || echo 'Not available')
- AWS CLI Version: $(aws --version 2>/dev/null || echo 'Not available')
- CloudWatch Agent: $(systemctl is-active amazon-cloudwatch-agent 2>/dev/null || echo 'Not configured')

Services Status:
- ComfyUI Multi-Tenant: $(systemctl is-enabled comfyui-multitenant.service 2>/dev/null || echo 'Not enabled')
- Ephemeral Storage: $(systemctl is-enabled mount-ephemeral-storage.service 2>/dev/null || echo 'Not enabled')

Checkpoints Completed:
$(cat /tmp/ami_checkpoints.txt 2>/dev/null || echo 'No checkpoints recorded')

Log Files:
- Main Log: $LOG_FILE
- Summary Log: /var/log/ami-summary.log
- CloudWatch Group: $CLOUDWATCH_LOG_GROUP
- CloudWatch Stream: $CLOUDWATCH_LOG_STREAM

=== End Summary ===
EOF

# Copy the summary to our main log as well
echo "📋 AMI Preparation Summary:" | tee -a "$LOG_FILE"
cat /var/log/ami-summary.log | tee -a "$LOG_FILE"

# Sync the final summary to CloudWatch
sync_logs_to_cloudwatch || echo "⚠️ Failed to sync final summary to CloudWatch" | tee -a "$LOG_FILE"

# Clear logs and shell history (but preserve our AMI logs)
echo "🧹 Cleaning up temporary logs..." | tee -a "$LOG_FILE"
find /var/log -type f -name "*.log" ! -name "ami-*.log" -exec truncate -s 0 {} \; 2>&1 | tee -a "$LOG_FILE"
history -c
> ~/.bash_history

# Signal completion
echo "AMI_SETUP_COMPLETE" > /tmp/ami_ready.txt
checkpoint "AMI_SETUP_COMPLETE"

echo "" | tee -a "$LOG_FILE"
echo "🚀🚀🚀 AMI preparation completed successfully! 🚀🚀🚀" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Ready to create AMI." | tee -a "$LOG_FILE"
echo "🎯 Service is still running for verification by the deployment workflow." | tee -a "$LOG_FILE"
echo "Use 'comfyui-monitor' command on new instances to check status." | tee -a "$LOG_FILE"
echo "📋 Complete logs available in CloudWatch: $CLOUDWATCH_LOG_GROUP/$CLOUDWATCH_LOG_STREAM" | tee -a "$LOG_FILE"

# Final log sync
echo "☁️ Performing final log synchronization..." | tee -a "$LOG_FILE"
sync_logs_to_cloudwatch || echo "⚠️ Final sync failed - logs available locally at $LOG_FILE" | tee -a "$LOG_FILE"

echo "✅ AMI preparation script completed." | tee -a "$LOG_FILE"