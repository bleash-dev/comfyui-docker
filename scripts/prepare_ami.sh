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
    echo "⚠️ This is a critical error - AMI preparation cannot continue without scripts"
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

# --- 9. CONFIGURE CLOUDWATCH ---
echo "📡 Configuring CloudWatch..."
if [ -f "/scripts/setup_cloudwatch.sh" ]; then
    echo "🔧 Running CloudWatch setup script..."
    if bash /scripts/setup_cloudwatch.sh; then
        echo "✅ CloudWatch setup completed successfully"
        checkpoint "CLOUDWATCH_CONFIGURED"
    else
        echo "⚠️ CloudWatch setup encountered issues but continuing (non-fatal)"
        checkpoint "CLOUDWATCH_CONFIGURED_WITH_WARNINGS"
    fi
else
    echo "⚠️ CloudWatch setup script not found, skipping..."
    checkpoint "CLOUDWATCH_SKIPPED"
fi

# --- 10. CREATE SYSTEM SERVICES (Docker-Free) ---
echo "⚙️ Creating systemd services..."

# Create a systemd service for ComfyUI Tenant Manager (Direct Python execution)
cat > /etc/systemd/system/comfyui-multitenant.service << 'EOF'
[Unit]
Description=ComfyUI Multi-Tenant Manager
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
echo "--- ComfyUI System Status ---"
echo; echo "--- ComfyUI Service Status ---"
systemctl status comfyui-multitenant
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

# --- 11. FINAL VALIDATION ---
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

# Check required directories
for dir in "/workspace" "/var/log/comfyui" "/scripts"; do
    if [ -d "$dir" ]; then
        echo "✅ Directory $dir exists"
    else
        VALIDATION_ERRORS+=("Directory $dir is missing")
    fi
done

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

# --- 12. FINAL AMI CLEANUP ---
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