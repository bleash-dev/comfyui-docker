#!/bin/bash
#
# AMI Preparation Script for Multi-Tenant ComfyUI (Docker-Free)
#
# Description:
# This script prepares an Amazon Linux 2023 instance to be used as a base AMI
# for a multi-tenant ComfyUI environment. It installs all necessary system
# dependencies, Python packages, AWS tools, and sets up a shared base ComfyUI
# installation. It also configures systemd services for automatic startup,
# ephemeral storage mounting, and script updates from S3.
#
# Prerequisites:
# - An Amazon Linux 2023 instance.
# - An IAM role attached with permissions for S3 (to download scripts) and
#   CloudWatch Logs (for agent configuration).
#
# Usage:
# Run this script as root on a fresh instance.
# sudo ./this_script.sh
#

set -euo pipefail # Fail on error, unset var, or pipe failure
# set -x # Uncomment for deep debugging

# --- 1. CONFIGURATION ---
# Centralized variables for easy modification.

# -- Logging --
LOG_FILE="/var/log/ami-preparation-$(date +%Y%m%d-%H%M%S).log"
CLOUDWATCH_LOG_GROUP="/comfyui/ami-preparation"

# -- Environment & S3 --
ENVIRONMENT="${ENVIRONMENT:-dev}"
AWS_REGION="${AWS_REGION:-us-east-1}"
S3_BUCKET_NAME="viral-comm-api-ec2-deployments-dev" # CHANGEME: Your S3 bucket name
S3_PREFIX="s3://${S3_BUCKET_NAME}/comfyui-ami/${ENVIRONMENT}"

# -- ComfyUI Base Installation --
BASE_DIR="/base"
VENV_DIR="${BASE_DIR}/venv/comfyui"
COMFYUI_DIR="${BASE_DIR}/ComfyUI"
PYTORCH_VERSION="2.4.0"
GIT_BRANCH="${GIT_BRANCH:-main}"

# -- System --
PYTHON_VERSION="3.11"
WORKSPACE_DIR="/workspace"

# --- 2. HELPER FUNCTIONS ---

# Unified logging function
log() {
    # Prepend timestamp and tee to both stdout and the log file.
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - $1" | tee -a "$LOG_FILE"
}

# Helper to run a function and log its start/end
run_step() {
    local func_name=$1
    local description=$2
    log "--- Starting: ${description} ---"
    if $func_name; then
        log "✅ --- Finished: ${description} ---"
    else
        log "❌ --- FAILED: ${description} ---"
        exit 1
    fi
}

# --- 3. SETUP FUNCTIONS ---

# Initializes logging and environment
initialize_setup() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    log "🏗️ Preparing EC2 instance for ComfyUI AMI creation (Docker-Free)..."
    log "Logging to ${LOG_FILE}"
    log "Environment: ${ENVIRONMENT}"
    log "AWS Region: ${AWS_REGION}"
    log "S3 Path: ${S3_PREFIX}"
}

# Installs all required system packages
setup_system_deps() {
    log "📦 Preparing package manager (dnf)..."
    # Safeguard: kill any hanging dnf processes (rare but can happen)
    timeout 10 pkill -9 -f dnf || true
    sleep 2
    dnf -y update

    log "📦 Installing system dependencies..."
    # Alphabetized list for easier maintenance
    dnf install -y \
        at-spi2-atk \
        at-spi2-core \
        atk \
        bc \
        ca-certificates \
        cups-libs \
        git \
        glib2 \
        htop \
        inotify-tools \
        jq \
        libSM \
        libXcomposite \
        libXcursor-devel \
        libXdamage \
        libXext \
        libXi-devel \
        libXinerama-devel \
        libXrandr-devel \
        lsof \
        mesa-libGL \
        mesa-libGLU \
        nano \
        net-tools \
        nss \
        openssh-server \
        python${PYTHON_VERSION} \
        python${PYTHON_VERSION}-pip \
        tree \
        unzip \
        vim-enhanced \
        wget \
        xorg-x11-server-Xvfb \
        xxd \
        zip \
        zstd

    log "🎬 Installing static ffmpeg binary..."
    local FFMPEG_URL="https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz"
    local TEMP_DIR
    TEMP_DIR=$(mktemp -d)
    curl -Lso "${TEMP_DIR}/ffmpeg.tar.xz" "$FFMPEG_URL"
    tar -xf "${TEMP_DIR}/ffmpeg.tar.xz" -C "$TEMP_DIR"
    mv "${TEMP_DIR}"/ffmpeg-*-static/ffmpeg "${TEMP_DIR}"/ffmpeg-*-static/ffprobe /usr/local/bin/
    rm -rf "$TEMP_DIR"
    log "✅ ffmpeg and ffprobe installed in /usr/local/bin/"

    log "🧹 Cleaning up dnf cache..."
    dnf clean all
    rm -rf /var/cache/dnf
}

# Configures Python environment and installs packages
setup_python_env() {
    log "🐍 Configuring Python ${PYTHON_VERSION}..."
    ln -sf "/usr/bin/python${PYTHON_VERSION}" /usr/bin/python3
    ln -sf "/usr/bin/python${PYTHON_VERSION}" /usr/bin/python

    log "🐍 Installing Python packages for instance management..."
    python3 -m pip install --no-cache-dir \
        boto3 \
        psutil \
        requests

    log "✅ Python environment configured."
}

# Installs AWS tools like the CloudWatch Agent
install_aws_tools() {
    log "📡 Installing CloudWatch Agent..."
    local CW_AGENT_RPM="/tmp/amazon-cloudwatch-agent.rpm"
    wget -q -O "$CW_AGENT_RPM" "https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm"
    # Use dnf to handle dependencies correctly
    dnf install -y "$CW_AGENT_RPM"
    rm -f "$CW_AGENT_RPM"
    log "✅ CloudWatch Agent installed."
}

# Sets up service to auto-mount ephemeral NVMe storage
setup_ephemeral_storage() {
    log "💾 Setting up ephemeral disk mounting service for ${WORKSPACE_DIR}..."

    cat > /usr/local/bin/mount-ephemeral-storage << 'EOF'
#!/bin/bash
# Mounts the first available non-root NVMe ephemeral disk to /workspace.
set -e
MOUNT_POINT="/workspace"
LOG_FILE="/var/log/ephemeral-mount.log"
log_message() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"; }

log_message "Starting ephemeral storage setup..."
mkdir -p "$MOUNT_POINT"
if mount | grep -q " on $MOUNT_POINT "; then
    log_message "$MOUNT_POINT is already mounted. Nothing to do."
    exit 0
fi

ROOT_DEVICE=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)")
log_message "Root device is '$ROOT_DEVICE', which will be excluded."

# Find NVMe devices that are disks, not the root device, and not mounted
NVME_DEVICE=$(lsblk -ndo NAME,TYPE,MOUNTPOINT | awk -v root="$ROOT_DEVICE" '$1 !~ root && $2 == "disk" && $3 == "" {print $1; exit}')

if [ -z "$NVME_DEVICE" ]; then
    log_message "No available ephemeral NVMe devices found to mount."
    exit 0
fi

DEVICE_PATH="/dev/${NVME_DEVICE}"
log_message "Found available device: $DEVICE_PATH"

if ! blkid "$DEVICE_PATH" >/dev/null 2>&1; then
    log_message "Device is not formatted. Formatting with ext4..."
    mkfs.ext4 -F "$DEVICE_PATH"
fi

log_message "Mounting $DEVICE_PATH to $MOUNT_POINT..."
mount "$DEVICE_PATH" "$MOUNT_POINT"
chown root:root "$MOUNT_POINT"
chmod 755 "$MOUNT_POINT"

df -h "$MOUNT_POINT" >> "$LOG_FILE"
log_message "SUCCESS: Ephemeral storage mounted."
EOF
    chmod +x /usr/local/bin/mount-ephemeral-storage

    cat > /etc/systemd/system/mount-ephemeral-storage.service << 'EOF'
[Unit]
Description=Mount Ephemeral Storage to /workspace
DefaultDependencies=false
After=local-fs-pre.target
Before=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mount-ephemeral-storage
RemainAfterExit=yes
StandardOutput=journal+console

[Install]
WantedBy=local-fs.target
EOF
    systemctl enable mount-ephemeral-storage.service
    log "✅ Ephemeral disk mounting service enabled."

    log "🧪 Testing mount script (will likely fail if no ephemeral disk is present)..."
    /usr/local/bin/mount-ephemeral-storage || log "⚠️ Test mount failed as expected (no ephemeral disk on this builder instance)."
}

# Downloads management scripts from S3
download_and_setup_scripts() {
    log "📥 Downloading management scripts from S3..."
    mkdir -p /scripts
    
    log "🔐 Verifying AWS CLI access..."
    if ! aws sts get-caller-identity --region "${AWS_REGION}" >/dev/null; then
        log "❌ AWS CLI access test failed. Check IAM Role and permissions."
        return 1
    fi
    log "✅ AWS CLI access confirmed."

    if ! aws s3 sync "${S3_PREFIX}/" /scripts --region "${AWS_REGION}"; then
        log "❌ Failed to download scripts from S3. Path: ${S3_PREFIX}"
        return 1
    fi

    log "✅ Scripts downloaded to /scripts. Verifying critical files..."
    ls -la /scripts

    if [ ! -s "/scripts/tenant_manager.py" ] || [ ! -s "/scripts/setup_components.sh" ]; then
        log "❌ Critical script (tenant_manager.py or setup_components.sh) is missing or empty."
        aws s3 ls "${S3_PREFIX}/" --region "${AWS_REGION}"
        return 1
    fi

    log "🔧 Making all downloaded scripts executable..."
    find /scripts -name "*.sh" -exec chmod +x {} \;
    find /scripts -name "*.py" -exec chmod +x {} \;

    log "✅ Scripts successfully downloaded and prepared."
}

# Installs the base shared ComfyUI environment
install_comfyui_base() {
    log "🎨 Installing base ComfyUI environment into ${BASE_DIR}..."
    mkdir -p "${BASE_DIR}" "${VENV_DIR}"
    chmod 755 "${BASE_DIR}" "${BASE_DIR}/venv"

    log "🔧 Running setup_components.sh..."
    # Set env vars for the setup script
    export NETWORK_VOLUME="${BASE_DIR}"
    export PYTORCH_VERSION="${PYTORCH_VERSION}"
    export GIT_BRANCH="${GIT_BRANCH}"

    if bash /scripts/setup_components.sh 2>&1 | tee -a "$LOG_FILE"; then
        log "✅ Base ComfyUI environment installed successfully."
    else
        log "❌ setup_components.sh failed. See logs for details."
        return 1
    fi

    log "🔍 Verifying base installation..."
    if [ ! -f "${VENV_DIR}/bin/python" ] || [ ! -f "${COMFYUI_DIR}/main.py" ]; then
        log "❌ Base installation validation failed. Venv or ComfyUI missing."
        ls -la "${BASE_DIR}" "${VENV_DIR}" "${COMFYUI_DIR}"
        return 1
    fi
    log "✅ Base installation validated."
}

# Creates all systemd services and helper scripts
create_system_services() {
    log "⚙️ Creating systemd services and helper scripts..."
    
    # -- Script Sync Helper --
    cat > /usr/local/bin/sync-scripts-from-s3 <<EOF
#!/bin/bash
set -euo pipefail
LOG_TAG="[script-sync]"
echo "\$LOG_TAG Syncing scripts from ${S3_PREFIX}..."
aws s3 sync "${S3_PREFIX}/" /scripts --region "${AWS_REGION}" --delete
echo "\$LOG_TAG Making scripts executable..."
find /scripts -name "*.sh" -exec chmod +x {} \;
find /scripts -name "*.py" -exec chmod +x {} \;
if [ -f "/scripts/tenant_manager.py" ]; then
    echo "\$LOG_TAG Updating main tenant manager binary..."
    cp /scripts/tenant_manager.py /usr/local/bin/tenant_manager
    chmod +x /usr/local/bin/tenant_manager
fi
echo "\$LOG_TAG Sync complete."
EOF
    chmod +x /usr/local/bin/sync-scripts-from-s3

    # -- Main Tenant Manager Service --
    cp /scripts/tenant_manager.py /usr/local/bin/tenant_manager
    chmod +x /usr/local/bin/tenant_manager

    cat > /etc/systemd/system/comfyui-multitenant.service << 'EOF'
[Unit]
Description=ComfyUI Multi-Tenant Manager
After=network-online.target mount-ephemeral-storage.service
Wants=network-online.target
Requires=mount-ephemeral-storage.service

[Service]
Type=simple
User=root
WorkingDirectory=/workspace
Restart=always
RestartSec=10

# Allow binding to privileged ports (e.g., 80)
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# Sync scripts before starting
ExecStartPre=-/usr/local/bin/sync-scripts-from-s3

# Main process
ExecStart=/usr/bin/python3 /usr/local/bin/tenant_manager

# Environment
Environment=PYTHONUNBUFFERED=1

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=comfyui-multitenant

[Install]
WantedBy=multi-user.target
EOF

    # -- Helper/Utility Scripts --
    cat > /usr/local/bin/comfyui-monitor << 'EOF'
#!/bin/bash
echo "--- ComfyUI Multi-Tenant Status ---"
echo; echo "● Service Status:"
systemctl status comfyui-multitenant --no-pager
echo; echo "● Ephemeral Storage:"
df -h /workspace
echo; echo "● Listening Ports (80, 8xxx):"
ss -tulpn | grep -E ':(80|8[0-9]{3})\s' || echo "No standard ports in use."
echo; echo "● Recent Logs (last 20 lines):"
journalctl -u comfyui-multitenant -n 20 --no-pager
EOF
    chmod +x /usr/local/bin/comfyui-monitor

    cat > /usr/local/bin/update-scripts << 'EOF'
#!/bin/bash
echo "🔄 Manually syncing scripts from S3 and restarting service..."
/usr/local/bin/sync-scripts-from-s3
systemctl restart comfyui-multitenant.service
echo "✅ Done. Use 'comfyui-monitor' to check status."
EOF
    chmod +x /usr/local/bin/update-scripts

    # -- Log Rotation --
    cat > /etc/logrotate.d/comfyui << 'EOF'
/var/log/comfyui/*.log /workspace/*/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
EOF
    
    systemctl daemon-reload
    systemctl enable comfyui-multitenant.service
    log "✅ Systemd services and helpers created and enabled."
}

# Performs final validation checks on the entire system
final_validation() {
    local errors=0

    log "🔍 Performing final validation..."

    # Test tenant manager import
    if ! python3 -c "import sys; sys.path.append('/usr/local/bin'); import tenant_manager"; then
        log "❌ Validation Error: Tenant manager script is invalid or cannot be imported."
        errors=$((errors + 1))
    fi

    # Start service for health check
    log "🚀 Starting service for live validation..."
    systemctl start comfyui-multitenant.service
    log "⏳ Waiting for service to initialize (15s)..."
    sleep 15

    if ! systemctl is-active --quiet comfyui-multitenant.service; then
        log "❌ Validation Error: comfyui-multitenant.service failed to start."
        journalctl -u comfyui-multitenant.service -n 50 --no-pager
        errors=$((errors + 1))
    else
        log "✅ Service is active. Checking health endpoint..."
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/health || echo "000")
        if [ "$http_code" != "200" ]; then
            log "❌ Validation Error: Health check failed! Received HTTP status ${http_code}."
            errors=$((errors + 1))
        else
            log "✅ Health endpoint is responsive (HTTP 200)."
        fi
    fi

    if [ $errors -gt 0 ]; then
        log "❌ Found ${errors} validation error(s). Halting AMI creation."
        return 1
    fi

    log "🎉 All validation checks passed!"
}

# Cleans the instance before creating the AMI
finalize_and_cleanup() {
    log "🧹 Finalizing and cleaning up for AMI creation..."

    # Stop service now that validation is complete
    systemctl stop comfyui-multitenant.service

    # Clean package cache
    dnf autoremove -y
    dnf clean all
    rm -rf /var/cache/dnf

    # Create AMI summary log
    cat > /var/log/ami-summary.log << EOF
=== ComfyUI AMI Preparation Summary ===
Completion Time: $(date)
Build Type: Docker-Free Multi-Tenant
Environment: ${ENVIRONMENT}
Base ComfyUI: ${COMFYUI_DIR}
Python Version: $(python3 --version)
Services: comfyui-multitenant, mount-ephemeral-storage
Monitoring: /usr/local/bin/comfyui-monitor
Update Utility: /usr/local/bin/update-scripts
EOF
    log "📋 AMI summary created at /var/log/ami-summary.log"

    # Clear shell history
    history -c && history -w
    > ~/.bash_history

    # Signal completion
    touch /tmp/ami_ready.txt

    log "🚀🚀🚀 AMI preparation completed successfully! 🚀🚀🚀"
    log "The instance is now clean and ready to be imaged."
    log "On new instances, use 'comfyui-monitor' to check status."
}

# --- 4. MAIN EXECUTION ---

main() {
    initialize_setup
    run_step setup_system_deps "Install System Dependencies"
    run_step setup_python_env "Configure Python Environment"
    run_step install_aws_tools "Install AWS Tools"
    run_step setup_ephemeral_storage "Set Up Ephemeral Storage Service"
    run_step download_and_setup_scripts "Download Management Scripts from S3"
    run_step install_comfyui_base "Install Base ComfyUI Environment"
    run_step create_system_services "Create Systemd Services"
    run_step final_validation "Perform Final Validation"
    run_step finalize_and_cleanup "Finalize and Clean Up"
}

# Execute the main function, redirecting all output to the log function
main