#!/bin/bash
# AMI Preparation Script for Multi-Tenant ComfyUI

echo "🏗️ Preparing EC2 instance for AMI creation..."

# Set up logging
exec 1> >(tee -a /var/log/ami-preparation.log)
exec 2> >(tee -a /var/log/ami-preparation.log >&2)

echo "=== AMI Preparation Started - $(date) ==="

# Create checkpoint function for progress tracking
checkpoint() {
    local step="$1"
    echo "✅ CHECKPOINT: $step completed at $(date)"
    echo "$step" > /tmp/ami_progress.txt
}

checkpoint "AMI_PREP_STARTED"

# Setup CloudWatch logging early for real-time monitoring
echo "🔧 Setting up CloudWatch logging early for debugging..."
if [ -f "/scripts/setup_cloudwatch.sh" ]; then
    bash /scripts/setup_cloudwatch.sh
    echo "✅ CloudWatch logging configured - logs should be visible in AWS Console"
    checkpoint "CLOUDWATCH_CONFIGURED"
else
    echo "⚠️ CloudWatch setup script not found, will retry later..."
    checkpoint "CLOUDWATCH_SKIPPED"
fi

# Update system packages
echo "📦 Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Kill any existing apt processes that might be locking
echo "🔧 Checking for existing apt processes..."
pkill -f apt-get || true
pkill -f dpkg || true
pkill -f unattended-upgrade || true
sleep 3

# Wait for dpkg lock to be available with timeout
echo "⏳ Waiting for dpkg lock..."
LOCK_TIMEOUT=30
for i in $(seq 1 $LOCK_TIMEOUT); do
    if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && \
       ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1 && \
       ! fuser /var/cache/apt/archives/lock >/dev/null 2>&1; then
        echo "✅ Package management locks are available"
        break
    fi
    if [ $i -eq $LOCK_TIMEOUT ]; then
        echo "❌ Timeout waiting for package management locks"
        echo "🔍 Processes holding locks:"
        fuser /var/lib/dpkg/lock-frontend 2>/dev/null || echo "No processes holding dpkg lock"
        fuser /var/lib/apt/lists/lock 2>/dev/null || echo "No processes holding apt lists lock"
        fuser /var/cache/apt/archives/lock 2>/dev/null || echo "No processes holding apt cache lock"
        ps aux | grep -E "(apt|dpkg|unattended)" | grep -v grep || echo "No apt/dpkg processes running"
        exit 1
    fi
    echo "⏳ Waiting for package management locks... (attempt $i/$LOCK_TIMEOUT)"
    sleep 2
done

# Configure apt to be non-interactive
echo 'APT::Get::Assume-Yes "true";' > /etc/apt/apt.conf.d/90-noninteractive
echo 'APT::Get::AllowUnauthenticated "true";' >> /etc/apt/apt.conf.d/90-noninteractive
echo 'DPkg::Options "--force-confdef";' >> /etc/apt/apt.conf.d/90-noninteractive
echo 'DPkg::Options "--force-confold";' >> /etc/apt/apt.conf.d/90-noninteractive
echo 'DPkg::Use-Pty "0";' >> /etc/apt/apt.conf.d/90-noninteractive

# Update package lists
echo "🔄 Updating package lists..."
apt-get update -y || {
    echo "❌ Failed to update package lists"
    exit 1
}
echo "✅ Package lists updated successfully"

# Skip upgrade for faster AMI preparation (we'll do essential packages only)
echo "⚡ Skipping full system upgrade for faster AMI preparation..."
echo "💡 Installing only essential packages..."

# Install essential packages first (one by one for better error tracking)
echo "📦 Installing essential packages individually..."

ESSENTIAL_PACKAGES=("ca-certificates" "curl" "wget" "gnupg" "lsb-release")

for package in "${ESSENTIAL_PACKAGES[@]}"; do
    echo "📦 Installing $package..."
    apt-get install -y --no-install-recommends "$package" || {
        echo "❌ Failed to install $package"
        echo "🔍 Package info:"
        apt-cache show "$package" 2>/dev/null || echo "Package not found in cache"
        echo "🔍 System status:"
        df -h
        free -m
        exit 1
    }
    echo "✅ $package installed successfully"
done

echo "✅ All essential packages installed"
checkpoint "ESSENTIAL_PACKAGES_INSTALLED"

# Install Docker if not already installed
echo "🐳 Starting Docker installation process..."
checkpoint "DOCKER_INSTALL_STARTED"

# System diagnostics before Docker installation
echo "🔍 System diagnostics before Docker installation:"
echo "  - OS: $(lsb_release -d 2>/dev/null | cut -f2 || echo 'Unknown')"
echo "  - Kernel: $(uname -r)"
echo "  - Architecture: $(dpkg --print-architecture)"
echo "  - Available space: $(df -h / | tail -1 | awk '{print $4}')"
echo "  - Available memory: $(free -h | grep 'Mem:' | awk '{print $7}')"
echo "  - Network connectivity: $(curl -s --max-time 5 http://google.com >/dev/null && echo 'OK' || echo 'FAILED')"

if ! command -v docker &> /dev/null; then
    echo "🐳 Docker not found, installing Docker with timeout protection..."
    
    # Simple, reliable Docker installation with timeouts
    echo "📦 Installing Docker from Ubuntu repository with timeout..."
    
    # Method 1: Try docker.io from Ubuntu repo (fastest)
    echo "📦 Attempting docker.io installation..."
    apt-get install -y --no-install-recommends docker.io 2>&1 | tee /tmp/docker_install.log
    DOCKER_INSTALL_EXIT_CODE=$?
    
    if [ $DOCKER_INSTALL_EXIT_CODE -ne 0 ]; then
        echo "❌ docker.io installation failed (exit code: $DOCKER_INSTALL_EXIT_CODE)"
        echo "🔍 Installation log:"
        tail -20 /tmp/docker_install.log 2>/dev/null || echo "No installation log available"
        
        # Method 2: Try installing via Docker convenience script with timeout
        echo "📦 Trying Docker convenience script..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh || {
            echo "❌ Failed to download Docker script"
            exit 1
        }
        
        echo "🔧 Running Docker installation script with timeout..."
        timeout 600 sh /tmp/get-docker.sh 2>&1 | tee /tmp/docker_script.log
        SCRIPT_EXIT_CODE=$?
        
        if [ $SCRIPT_EXIT_CODE -ne 0 ]; then
            echo "❌ Docker script installation failed (exit code: $SCRIPT_EXIT_CODE)"
            echo "🔍 Script log:"
            tail -20 /tmp/docker_script.log 2>/dev/null || echo "No script log available"
            exit 1
        fi
        
        rm -f /tmp/get-docker.sh
        echo "✅ Docker installed via convenience script"
    else
        echo "✅ Docker installed via apt"
    fi
    
    # Clean up installation logs
    rm -f /tmp/docker_install.log /tmp/docker_script.log
    
    echo "🔍 Verifying Docker was installed..."
    if ! command -v docker &> /dev/null; then
        echo "❌ Docker command not found after installation"
        echo "🔍 Checking /usr/bin and /usr/local/bin:"
        ls -la /usr/bin/docker* 2>/dev/null || echo "No docker in /usr/bin"
        ls -la /usr/local/bin/docker* 2>/dev/null || echo "No docker in /usr/local/bin"
        exit 1
    fi
    echo "✅ Docker command found"
    checkpoint "DOCKER_COMMAND_INSTALLED"
    
    echo "🔍 Checking Docker version..."
    docker --version || {
        echo "❌ Docker version check failed"
        exit 1
    }
    echo "✅ Docker version check passed"
    
    # Add ubuntu user to docker group if exists
    if id "ubuntu" &>/dev/null; then
        usermod -aG docker ubuntu
        echo "✅ Added ubuntu user to docker group"
    fi
    
    checkpoint "DOCKER_PACKAGE_INSTALLED"
    
    # Enable Docker service
    echo "🔧 Enabling Docker service..."
    systemctl enable docker || {
        echo "❌ Failed to enable Docker service"
        systemctl status docker --no-pager || echo "No Docker service status available"
        exit 1
    }
    
    # Start Docker service with debugging
    echo "🚀 Starting Docker service..."
    systemctl start docker || {
        echo "❌ Failed to start Docker service"
        echo "🔍 Docker service status:"
        systemctl status docker --no-pager -l
        echo "🔍 Docker service logs:"
        journalctl -u docker.service --no-pager -l --since "1 minute ago" || echo "No Docker service logs available"
        exit 1
    }
    
    echo "🔍 Checking Docker service status after start..."
    systemctl status docker --no-pager -l || echo "Docker service status check completed"
    
    checkpoint "DOCKER_SERVICE_STARTED"
    
    # Wait for Docker to be fully ready with better error handling
    echo "⏳ Waiting for Docker to be ready..."
    DOCKER_READY=false
    for i in {1..30}; do
        if systemctl is-active --quiet docker; then
            echo "✅ Docker service is active"
            if docker version >/dev/null 2>&1; then
                echo "✅ Docker daemon is responding"
                DOCKER_READY=true
                break
            else
                echo "⏳ Docker service active but daemon not responding yet... (attempt $i/30)"
            fi
        else
            echo "⏳ Docker service not active yet... (attempt $i/30)"
        fi
        sleep 3
    done
    
    if [ "$DOCKER_READY" != "true" ]; then
        echo "❌ Docker failed to become ready within timeout"
        echo "🔍 Docker service status:"
        systemctl status docker --no-pager -l
        echo "🔍 Docker daemon logs:"
        journalctl -u docker.service --no-pager -l --since "5 minutes ago" || echo "No recent Docker logs"
        exit 1
    fi
    
    # Test Docker functionality with a simple command
    echo "🧪 Testing Docker functionality..."
    if timeout 30 docker run --rm hello-world >/dev/null 2>&1; then
        echo "✅ Docker functionality test passed"
    else
        echo "⚠️ Docker functionality test failed, but continuing (hello-world image may not be available)"
        # Test with a simpler docker command
        if timeout 10 docker version >/dev/null 2>&1; then
            echo "✅ Docker daemon is responding to commands"
        else
            echo "❌ Docker daemon is not responding to commands"
            echo "🔍 Docker daemon status:"
            systemctl status docker --no-pager -l
            exit 1
        fi
    fi
    
    echo "✅ Docker installed and configured successfully"
    checkpoint "DOCKER_INSTALLED"
else
    echo "✅ Docker already installed"
    checkpoint "DOCKER_ALREADY_PRESENT"
    
    # Ensure Docker is running even if already installed
    if ! systemctl is-active --quiet docker; then
        echo "🔄 Starting existing Docker service..."
        systemctl start docker
        
        # Wait for Docker to be ready
        for i in {1..15}; do
            if systemctl is-active --quiet docker && docker version >/dev/null 2>&1; then
                echo "✅ Docker service started (attempt $i)"
                break
            fi
            echo "⏳ Waiting for Docker service... (attempt $i/15)"
            sleep 2
        done
    fi
fi

# Final Docker verification before proceeding
echo "🔍 Final Docker verification..."
if ! systemctl is-active --quiet docker; then
    echo "❌ CRITICAL: Docker service is not active"
    systemctl status docker
    exit 1
fi

if ! docker version >/dev/null 2>&1; then
    echo "❌ CRITICAL: Docker daemon is not responding"
    docker version
    exit 1
fi

echo "✅ Docker verification passed - service is active and responding"
checkpoint "DOCKER_VERIFIED"

# Set up Docker logging to file for CloudWatch monitoring
echo "📝 Setting up Docker service logging..."
journalctl -u docker -f > /var/log/docker.log &
DOCKER_LOG_PID=$!
echo "🔍 Docker logs being captured to /var/log/docker.log (PID: $DOCKER_LOG_PID)"

# Install additional system dependencies (one by one for better tracking)
echo "📦 Installing additional system dependencies..."
checkpoint "ADDITIONAL_PACKAGES_STARTED"

ADDITIONAL_PACKAGES=("jq" "unzip" "htop" "tree" "vim" "git")

for package in "${ADDITIONAL_PACKAGES[@]}"; do
    echo "📦 Installing $package..."
    apt-get install -y --no-install-recommends "$package" || {
        echo "❌ Failed to install $package"
        echo "🔍 Available alternatives:"
        apt-cache search "^$package" 2>/dev/null || echo "No alternatives found"
        echo "⚠️ Continuing without $package..."
        continue
    }
    echo "✅ $package installed successfully"
done

# Note: awscli should already be available on Ubuntu AMI
# Note: systemd and systemctl are core packages and should already be present

echo "✅ Additional system dependencies installed"
checkpoint "ADDITIONAL_PACKAGES_INSTALLED"

# Setup CloudWatch logging (if not already done)
echo "🔧 Ensuring CloudWatch logging is configured..."
if ! systemctl is-active --quiet amazon-cloudwatch-agent; then
    if [ -f "/scripts/setup_cloudwatch.sh" ]; then
        bash /scripts/setup_cloudwatch.sh
    else
        echo "⚠️ CloudWatch setup script not found, skipping..."
    fi
fi

# Create directories for multi-tenant operation
echo "📁 Creating multi-tenant directories..."
mkdir -p /var/log/comfyui
mkdir -p /workspace
mkdir -p /tmp/tenants
chmod 755 /var/log/comfyui
chmod 755 /workspace
chmod 755 /tmp/tenants

echo "✅ Created directory structure:"
echo "  - /var/log/comfyui (tenant manager logs)"
echo "  - /workspace (tenant workspaces)"
echo "  - /tmp/tenants (temporary tenant data)"

# Pull the ComfyUI Docker image
echo "🐳 Pulling ComfyUI Docker image..."
checkpoint "DOCKER_IMAGE_PULL_STARTED"

# Get Docker image from environment variables
DOCKER_IMAGE="${COMFYUI_DOCKER_IMAGE:-}"
if [ -z "$DOCKER_IMAGE" ]; then
    echo "❌ ERROR: COMFYUI_DOCKER_IMAGE environment variable not set"
    echo "💡 This should be set to the full ECR image URI"
    echo "💡 Example: public.ecr.aws/alias/comfyui-docker:latest"
    exit 1
fi

echo "📝 Using Docker image: $DOCKER_IMAGE"

# Verify Docker is still working before image operations
if ! docker version >/dev/null 2>&1; then
    echo "❌ CRITICAL: Docker stopped working before image pull"
    systemctl status docker
    exit 1
fi

# Login to ECR if needed (for private repositories)
if [[ "$DOCKER_IMAGE" == *"ecr"* ]]; then
    echo "🔐 Logging into ECR..."
    aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws || {
        echo "⚠️ ECR login failed, but continuing (image may be public)"
    }
fi

echo "⬇️ Pulling Docker image: $DOCKER_IMAGE"
if docker pull "$DOCKER_IMAGE"; then
    echo "✅ Docker image pulled successfully"
    
    # Tag as latest for local use
    docker tag "$DOCKER_IMAGE" comfyui-multitenant:latest
    
    # Also tag with the original name for the service
    docker tag "$DOCKER_IMAGE" comfyui-multitenant:source
    
    echo "🏷️ Image tagged as: comfyui-multitenant:latest"
    
    # Verify the image was tagged correctly
    echo "🔍 Verifying tagged images..."
    docker images | grep comfyui-multitenant || {
        echo "❌ Failed to verify tagged images"
        exit 1
    }
    
else
    echo "❌ Failed to pull Docker image: $DOCKER_IMAGE"
    echo "💡 Please ensure the image exists and you have proper permissions"
    echo "🔍 Docker daemon status:"
    systemctl status docker
    echo "🔍 Available Docker images:"
    docker images
    exit 1
fi

# Stop Docker logging background process before AMI creation
if [ -n "$DOCKER_LOG_PID" ]; then
    echo "🛑 Stopping Docker logging background process..."
    kill $DOCKER_LOG_PID 2>/dev/null || true
fi

# Create startup script for EC2 instance
echo "📝 Creating EC2 startup script..."
cat > /etc/init.d/comfyui-multitenant << 'EOF'
#!/bin/bash
### BEGIN INIT INFO
# Provides:          comfyui-multitenant
# Required-Start:    $remote_fs $syslog docker
# Required-Stop:     $remote_fs $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: ComfyUI Multi-Tenant Service
# Description:       Manages multi-tenant ComfyUI Docker containers
### END INIT INFO

NAME="comfyui-multitenant"
DOCKER_IMAGE="comfyui-multitenant:latest"
CONTAINER_NAME="comfyui-manager"

case "$1" in
    start)
        echo "Starting $NAME..."
        
        # Stop any existing container
        docker stop $CONTAINER_NAME 2>/dev/null || true
        docker rm $CONTAINER_NAME 2>/dev/null || true
        
        # Start the container
        docker run -d \
            --name $CONTAINER_NAME \
            --restart unless-stopped \
            -p 80:80 \
            -p 8000-9000:8000-9000 \
            -v /var/log/comfyui:/var/log \
            -v /tmp/tenants:/tmp/tenants \
            -v /workspace:/workspace \
            -v /dev:/dev \
            --privileged \
            $DOCKER_IMAGE
        
        echo "$NAME started"
        ;;
    stop)
        echo "Stopping $NAME..."
        docker stop $CONTAINER_NAME
        docker rm $CONTAINER_NAME
        echo "$NAME stopped"
        ;;
    restart)
        $0 stop
        sleep 2
        $0 start
        ;;
    status)
        if docker ps | grep -q $CONTAINER_NAME; then
            echo "$NAME is running"
        else
            echo "$NAME is not running"
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac

exit 0
EOF

chmod +x /etc/init.d/comfyui-multitenant

# Enable the service to start on boot
update-rc.d comfyui-multitenant defaults

# Create systemd service as well (for modern systems)
cat > /etc/systemd/system/comfyui-multitenant.service << 'EOF'
[Unit]
Description=ComfyUI Multi-Tenant Service
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/init.d/comfyui-multitenant start
ExecStop=/etc/init.d/comfyui-multitenant stop
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable comfyui-multitenant

# Create monitoring script
echo "📊 Creating monitoring script..."
cat > /usr/local/bin/comfyui-monitor << 'EOF'
#!/bin/bash
# ComfyUI Multi-Tenant Monitoring Script

echo "🔍 ComfyUI Multi-Tenant System Status"
echo "======================================"

# Check Docker
echo "🐳 Docker Status:"
if systemctl is-active --quiet docker; then
    echo "  ✅ Docker service is running"
    echo "  📊 Containers: $(docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}')"
else
    echo "  ❌ Docker service is not running"
fi

echo ""

# Check ComfyUI service
echo "🎯 ComfyUI Service Status:"
if systemctl is-active --quiet comfyui-multitenant; then
    echo "  ✅ ComfyUI multi-tenant service is active"
else
    echo "  ❌ ComfyUI multi-tenant service is not active"
fi

echo ""

# Check system resources
echo "💻 System Resources:"
echo "  CPU: $(top -bn1 | grep 'Cpu(s)' | awk '{print $2}' | cut -d'%' -f1)% used"
echo "  Memory: $(free | grep Mem | awk '{printf "%.1f%% used", $3/$2 * 100.0}')"
echo "  Disk: $(df -h / | tail -1 | awk '{print $5}') used"

# Check GPU if available
if command -v nvidia-smi &> /dev/null; then
    echo "  GPU: $(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | head -1)% used"
fi

echo ""

# Check logs
echo "📝 Recent Logs:"
echo "  Tenant Manager: $(tail -1 /var/log/comfyui/tenant_manager.log 2>/dev/null || echo 'No logs found')"

echo ""

# Check API endpoint
echo "🌐 API Health Check:"
if curl -s http://localhost:80/health > /dev/null; then
    echo "  ✅ Management API is responding"
    
    # Get tenant count
    tenant_count=$(curl -s http://localhost:80/metrics | jq -r '.tenants.tenants | length' 2>/dev/null || echo "unknown")
    echo "  👥 Active tenants: $tenant_count"
else
    echo "  ❌ Management API is not responding"
fi
EOF

chmod +x /usr/local/bin/comfyui-monitor

# Create log rotation configuration
echo "📄 Setting up log rotation..."
cat > /etc/logrotate.d/comfyui << 'EOF'
/var/log/comfyui/*.log {
    daily
    missingok
    rotate 30
    compress
    notifempty
    create 0644 root root
    postrotate
        # Restart CloudWatch agent to pick up new log files
        systemctl restart amazon-cloudwatch-agent 2>/dev/null || true
    endscript
}

/workspace/*/*.log {
    daily
    missingok
    rotate 7
    compress
    notifempty
    create 0644 root root
}
EOF

# Clean up package cache and temporary files
echo "🧹 Cleaning up..."
apt-get autoremove -y
apt-get autoclean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/*
rm -rf /var/tmp/*

# Clear logs for AMI
echo "📝 Clearing logs for AMI..."
> /var/log/ami-preparation.log
find /var/log -name "*.log" -exec truncate -s 0 {} \;

# Clear bash history
history -c
> ~/.bash_history

echo "✅ AMI preparation completed successfully!"
checkpoint "AMI_PREPARATION_COMPLETE"

# Signal completion for the workflow
echo "AMI_PREPARATION_COMPLETE" > /tmp/ami_ready.txt

echo ""
echo "📋 Summary:"
echo "  - Docker installed and configured"
echo "  - Docker image: $DOCKER_IMAGE"
echo "  - CloudWatch logging configured"
echo "  - ComfyUI service configured for auto-start"
echo "  - Monitoring tools installed"
echo "  - Log rotation configured"
echo "  - Workspace structure: /workspace/<pod-id>/"
echo ""
echo "🚀 Ready to create AMI!"
echo "💡 After launching from AMI, the ComfyUI service will start automatically"
echo "💡 Use 'comfyui-monitor' command to check system status"
