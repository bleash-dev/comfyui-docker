# 🔄 Docker to AMI Migration Guide

This guide helps teams transition from Docker-based ComfyUI deployment to the new AMI-based approach.

## 🎯 Why Migrate?

### Benefits of AMI Deployment
- **Better Performance**: 10-15% CPU improvement, 5-10% memory savings
- **Simplified Architecture**: No Docker layer complexity
- **Direct Process Access**: Easier debugging and monitoring
- **Faster Startup**: ComfyUI instances start more quickly
- **Native System Integration**: Better CloudWatch, systemd integration

### Docker Limitations
- Container overhead impacts GPU workloads
- Complex networking setup for multi-tenant scenarios
- Additional layer for troubleshooting
- Volume mounting complexity for large model files

## 📋 Pre-Migration Checklist

### 1. Audit Current Docker Setup
```bash
# Document current Docker images
docker images | grep comfyui

# List running containers
docker ps -a | grep comfyui

# Check volume mounts
docker inspect $(docker ps -q) | grep -A 10 "Mounts"

# Document environment variables
docker inspect $(docker ps -q) | grep -A 20 "Env"
```

### 2. Backup Critical Data
```bash
# Backup custom models
aws s3 sync /docker/volumes/models s3://your-backup/models/

# Backup custom nodes and configurations
tar -czf comfyui-custom-$(date +%Y%m%d).tar.gz \
    /docker/volumes/ComfyUI/custom_nodes/ \
    /docker/volumes/ComfyUI/user/

# Export environment configurations
docker inspect $(docker ps -q) > docker-config-backup.json
```

### 3. Document Custom Configurations
- Environment variables used
- Custom model paths
- Network port mappings
- Volume mount points
- Any custom startup scripts

## 🏗️ Migration Process

### Phase 1: Build New AMI

1. **Prepare Scripts**
```bash
# Ensure all scripts are up to date
git pull origin main

# Verify prepare_ami.sh includes your customizations
cat scripts/prepare_ami.sh | grep -A 5 -B 5 "CUSTOM"
```

2. **Launch Base Instance**
```bash
# Use same instance type as current Docker deployment
aws ec2 run-instances \
    --image-id ami-0c02fb55956c7d316 \  # Ubuntu 22.04 LTS
    --instance-type g4dn.xlarge \
    --key-name your-key-pair \
    --security-group-ids sg-your-security-group
```

3. **Transfer Custom Configurations**
```bash
# Copy custom files to preparation instance
scp -r custom_models/ ubuntu@new-instance:/tmp/custom_models/
scp custom_config.json ubuntu@new-instance:/tmp/
```

4. **Run AMI Preparation**
```bash
# SSH to instance and prepare
ssh ubuntu@new-instance
sudo /tmp/scripts/prepare_ami.sh

# Add custom configurations during preparation
sudo cp /tmp/custom_models/* /workspace/shared_models/
sudo cp /tmp/custom_config.json /usr/local/etc/comfyui/
```

### Phase 2: Parallel Testing

1. **Launch Test Instance from New AMI**
```bash
aws ec2 run-instances \
    --image-id ami-your-new-ami \
    --instance-type g4dn.xlarge \
    --key-name your-key-pair \
    --security-group-ids sg-your-security-group
```

2. **Compare Functionality**
```bash
# Test tenant creation on both systems
# Docker system:
curl -X POST http://docker-instance:3000/start -d '{"pod_id":"test1"}'

# AMI system:
curl -X POST http://ami-instance:3000/start -d '{"pod_id":"test1"}'
```

3. **Performance Comparison**
```bash
# Monitor resource usage on both
# Docker system:
docker stats

# AMI system:
htop
free -h
```

### Phase 3: Gradual Migration

1. **Start with Development/Staging**
```bash
# Replace dev instances first
# Keep production Docker instances running
```

2. **Migrate Low-Traffic Tenants**
```bash
# Migrate tenants with less critical workloads
# Monitor for any issues
```

3. **Full Production Migration**
```bash
# Once confident, migrate all production workloads
# Keep rollback plan ready
```

## 🔧 Configuration Mapping

### Docker → AMI Equivalents

| Docker Component | AMI Equivalent | Notes |
|------------------|----------------|-------|
| `docker run` | `systemctl start comfyui-multitenant` | Systemd service management |
| `docker logs` | `journalctl -u comfyui-multitenant` | System journal logs |
| `docker exec` | Direct SSH access | No container barrier |
| Volume mounts | Direct filesystem paths | `/workspace/[tenant]/` |
| Environment variables | `/etc/environment` | System-wide env vars |
| Docker network | Host networking | Direct port binding |
| Container health checks | Built-in health monitoring | Process + service checks |

### Environment Variables Migration
```bash
# Docker environment variables
docker inspect container | jq '.[0].Config.Env'

# Convert to AMI environment file
echo 'export COMFYUI_VENV=/opt/venv/comfyui' >> /etc/environment
echo 'export PYTHON_VERSION=3' >> /etc/environment
```

### Port Mapping Migration
```bash
# Docker port mapping
docker ps --format "table {{.Names}}\t{{.Ports}}"

# AMI direct port binding
ss -tulpn | grep :80
```

## 🧪 Testing Strategy

### 1. Functionality Tests
```bash
# Test basic API endpoints
curl http://localhost:3000/health
curl http://localhost:3000/tenants

# Test tenant lifecycle
curl -X POST http://localhost:3000/start -d '{"pod_id":"test"}'
curl -X POST http://localhost:3000/stop -d '{"pod_id":"test"}'
```

### 2. Performance Tests
```bash
# Load test with multiple tenants
for i in {1..5}; do
    curl -X POST http://localhost:3000/start \
        -d "{\"pod_id\":\"load-test-$i\"}" &
done

# Monitor resource usage
iostat 1
vmstat 1
```

### 3. Reliability Tests
```bash
# Test service restart
sudo systemctl restart comfyui-multitenant

# Test instance reboot
sudo reboot

# Test process recovery
sudo pkill -f tenant_manager
# Verify systemd restarts it
```

## 🚨 Rollback Plan

### Emergency Rollback to Docker

If issues arise, you can quickly rollback:

1. **Keep Docker Images Available**
```bash
# Don't delete Docker images immediately
docker images --no-trunc > docker-images-backup.txt
```

2. **Maintain Docker Infrastructure**
```bash
# Keep Docker-based launch templates in AWS
# Tag them as "rollback-ready"
```

3. **Quick Rollback Process**
```bash
# Launch instances from Docker AMI/template
aws ec2 run-instances \
    --launch-template LaunchTemplateName=ComfyUI-Docker-Rollback
```

### Gradual Rollback

If needed, roll back tenant by tenant:
```bash
# Stop AMI-based tenant
curl -X POST http://ami-instance:3000/stop -d '{"pod_id":"tenant1"}'

# Start Docker-based tenant
docker run -d --name tenant1-rollback [docker-options] comfyui-image
```

## 📊 Success Metrics

Track these metrics to validate migration success:

### Performance Metrics
- CPU utilization (should decrease 10-15%)
- Memory usage (should decrease 5-10%)
- Startup time (should improve)
- Request latency (should improve or stay same)

### Reliability Metrics
- Service uptime
- Failed tenant starts
- Process crashes
- Recovery time from failures

### Operational Metrics
- Deployment time
- Debugging/troubleshooting time
- Log analysis complexity
- Monitoring setup difficulty

## 🔍 Troubleshooting Common Migration Issues

### Issue: Tenant Manager Won't Start
```bash
# Check Python path
which python3
ls -la /usr/local/bin/tenant_manager.py

# Check permissions
sudo chmod +x /usr/local/bin/tenant_manager.py

# Check dependencies
python3 -c "import psutil, boto3, requests"
```

### Issue: ComfyUI Models Not Found
```bash
# Check model paths
ls -la /workspace/shared_models/
ls -la /workspace/[tenant]/models/

# Check symlinks
find /workspace -type l -ls
```

### Issue: Performance Worse Than Docker
```bash
# Check for missing optimizations
cat /proc/cmdline  # GPU drivers
nvidia-smi         # GPU status
htop               # CPU usage patterns
```

### Issue: Port Conflicts
```bash
# Check port usage
ss -tulpn | grep :80

# Restart tenant manager to reassign ports
sudo systemctl restart comfyui-multitenant
```

## ✅ Post-Migration Cleanup

Once migration is successful:

1. **Remove Docker Components**
```bash
# Stop all Docker containers
docker stop $(docker ps -aq)

# Remove containers
docker rm $(docker ps -aq)

# Remove images (after verification)
docker rmi $(docker images -q)

# Remove Docker daemon (optional)
sudo apt-get remove docker-ce docker-ce-cli containerd.io
```

2. **Update Documentation**
- Update deployment procedures
- Update monitoring runbooks
- Update troubleshooting guides

3. **Update Infrastructure as Code**
- Update Terraform/CloudFormation templates
- Update CI/CD pipelines
- Update monitoring configurations

## 🎯 Success Criteria

Migration is considered successful when:

- ✅ All tenants can be created and managed
- ✅ Performance metrics show improvement
- ✅ Monitoring and logging work correctly
- ✅ No functional regressions identified
- ✅ Team comfortable with new operational procedures
- ✅ Rollback plan tested and verified

## 📞 Support

If you encounter issues during migration:

1. Check the [AMI Deployment Guide](AMI_DEPLOYMENT.md)
2. Review logs: `sudo journalctl -u comfyui-multitenant`
3. Use monitoring script: `sudo comfyui-monitor`
4. Test connectivity: `curl http://localhost:3000/health`

Remember: The migration can be done gradually, and rollback options are always available!
