#!/bin/bash
# AMI Preparation Script for Multi-Tenant ComfyUI

echo "🏗️ Preparing EC2 instance for AMI creation..."

# Set up logging
exec 1> >(tee -a /var/log/ami-preparation.log)
exec 2> >(tee -a /var/log/ami-preparation.log >&2)

echo "=== AMI Preparation Started - $(date) ==="

# Setup CloudWatch logging early for real-time monitoring
echo "🔧 Setting up CloudWatch logging early for debugging..."
if [ -f "/scripts/setup_cloudwatch.sh" ]; then
    bash /scripts/setup_cloudwatch.sh
    echo "✅ CloudWatch logging configured - logs should be visible in AWS Console"
else
    echo "⚠️ CloudWatch setup script not found, will retry later..."
fi

# Update system packages
echo "📦 Updating system packages..."
apt-get update -y
apt-get upgrade -y

# Install Docker if not already installed
if ! command -v docker &> /dev/null; then
    echo "🐳 Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
    
    # Add ubuntu user to docker group if exists
    if id "ubuntu" &>/dev/null; then
        usermod -aG docker ubuntu
    fi
    
    # Enable Docker service
    systemctl enable docker
    systemctl start docker
    
    # Configure Docker logging to file for CloudWatch
    echo "📝 Configuring Docker logging..."
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << 'DOCKER_EOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m",
        "max-file": "3"
    }
}
DOCKER_EOF
    
    # Restart Docker to apply logging configuration
    systemctl restart docker
    
    # Wait for Docker to be fully ready
    echo "⏳ Waiting for Docker to be ready..."
    for i in {1..30}; do
        if systemctl is-active --quiet docker && docker version >/dev/null 2>&1; then
            echo "✅ Docker is ready (attempt $i)"
            break
        fi
        echo "⏳ Docker not ready yet, waiting... (attempt $i/30)"
        sleep 2
    done
    
    # Final verification
    if ! systemctl is-active --quiet docker; then
        echo "❌ Docker service failed to start properly"
        systemctl status docker
        exit 1
    fi
    
    if ! docker version >/dev/null 2>&1; then
        echo "❌ Docker daemon is not responding"
        docker version
        exit 1
    fi
    
    echo "✅ Docker installed and configured successfully"
else
    echo "✅ Docker already installed"
    
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

# Set up Docker logging to file for CloudWatch monitoring
echo "📝 Setting up Docker service logging..."
journalctl -u docker -f > /var/log/docker.log &
DOCKER_LOG_PID=$!
echo "🔍 Docker logs being captured to /var/log/docker.log (PID: $DOCKER_LOG_PID)"

# Install additional system dependencies
echo "📦 Installing system dependencies..."
apt-get install -y \
    curl \
    wget \
    jq \
    unzip \
    awscli \
    htop \
    tree \
    vim \
    git

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
