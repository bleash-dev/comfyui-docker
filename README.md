# 🎨 ComfyUI Multi-Tenant Deployment

<div align="center">

<img src="https://pbs.twimg.com/profile_images/1802828693888475136/yuNS4xXR_400x400.jpg" alt="ComfyUI Logo" style="width: 100px; height: 100px; border-radius: 50%;">

### High-Performance Multi-Tenant ComfyUI for AWS EC2

[![Sponsored by Dreamshot.io](https://img.shields.io/badge/Sponsored_by-Dreamshot.io-blue?style=for-the-badge)](https://dreamshot.io)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge)](https://opensource.org/licenses/MIT)
[![EC2 AMI](https://img.shields.io/badge/AWS-EC2_AMI-orange.svg?style=for-the-badge&logo=amazon-aws&logoColor=white)](https://aws.amazon.com/ec2/)

</div>

## 🚀 Quick Start

### AMI-Based Deployment (Recommended)

Get your high-performance ComfyUI multi-tenant setup running on EC2:

1. **Launch Base Instance**
   ```bash
   # Ubuntu 22.04 LTS, g4dn.xlarge or larger recommended
   aws ec2 run-instances --image-id ami-0c02fb55956c7d316 --instance-type g4dn.xlarge
   ```

2. **Prepare AMI**
   ```bash
   # Copy scripts and run preparation
   scp -r scripts/ ubuntu@instance:/tmp/scripts/
   ssh ubuntu@instance
   sudo /tmp/scripts/prepare_ami.sh
   ```

3. **Create Custom AMI**
   ```bash
   # Create AMI from prepared instance
   aws ec2 create-image --instance-id i-xxx --name "ComfyUI-MultiTenant-$(date +%Y%m%d)"
   ```

4. **Deploy Production Instances**
   ```bash
   # Launch from your custom AMI
   aws ec2 run-instances --image-id ami-your-custom-ami --instance-type g4dn.xlarge
   ```

📖 **[Complete AMI Deployment Guide](docs/AMI_DEPLOYMENT.md)**

### Docker Deployment (Legacy)

For existing Docker-based setups:
```bash
# Legacy Docker support (use AMI for better performance)
docker run -d --name comfyui javierjrueda/comfyui-runpod:latest
```

📖 **[Migration Guide: Docker → AMI](docs/DOCKER_TO_AMI_MIGRATION.md)**

## 🌟 Why AMI Over Docker?

### Performance Benefits
- **🚀 10-15% CPU improvement** - No container overhead
- **💾 5-10% memory savings** - Direct process execution
- **⚡ Faster startup times** - No container initialization
- **🔧 Easier debugging** - Direct access to processes and logs

### Operational Benefits
- **📊 Native monitoring** - Direct systemd and CloudWatch integration
- **🔍 Simplified troubleshooting** - No container layer complexity
- **⚙️ Better resource utilization** - Full access to system resources
- **🛡️ Enhanced reliability** - Process-level management and recovery

## 🏗️ Architecture

### Multi-Tenant System
```
┌─────────────────────────────────────────────────────────────┐
│                    EC2 Instance (AMI)                      │
├─────────────────────────────────────────────────────────────┤
│  Tenant Manager (Python + systemd)                        │
│  ├─ REST API (Port 3000)                                   │
│  ├─ Health Monitoring                                      │
│  └─ Process Management                                     │
├─────────────────────────────────────────────────────────────┤
│  ComfyUI Instances (Direct Python Processes)               │
│  ├─ Tenant 1: /workspace/user1/ (Port 8001)               │
│  ├─ Tenant 2: /workspace/user2/ (Port 8002)               │
│  └─ Tenant N: /workspace/userN/ (Port 800N)               │
├─────────────────────────────────────────────────────────────┤
│  System Services                                           │
│  ├─ CloudWatch Agent (Logging)                            │
│  ├─ Log Rotation                                           │
│  └─ Health Monitoring                                      │
└─────────────────────────────────────────────────────────────┘
```

### Key Components
- **Tenant Manager**: REST API for managing ComfyUI instances
- **Health Monitoring**: Process + service health checks
- **Resource Isolation**: Per-tenant workspaces and ports
- **Logging Integration**: SystemD + CloudWatch
- **Auto-Recovery**: Failed process detection and restart

## 🔧 Management API

### Start Tenant
```bash
curl -X POST http://localhost:3000/start \
  -H "Content-Type: application/json" \
  -d '{
    "pod_id": "user123",
    "username": "alice",
    "network_volume": "/workspace/alice"
  }'
```

### List Tenants
```bash
curl http://localhost:3000/tenants | jq
# Response includes: status, process_alive, service_healthy
```

### Stop Tenant
```bash
curl -X POST http://localhost:3000/stop \
  -H "Content-Type: application/json" \
  -d '{"pod_id": "user123"}'
```

### Health Check
```bash
curl http://localhost:3000/health
```

## 📊 Enhanced Health Monitoring

### Multi-Level Health Checks
- **Process Health**: PID exists, resource usage normal
- **Service Health**: Port accessible, HTTP response OK
- **Application Health**: ComfyUI API responding correctly

### Status Types
- **✅ Healthy**: Process running + service responding
- **⚠️ Unhealthy**: Process running but service not responding
- **❌ Dead**: Process not running

### Monitoring Commands
```bash
# System status overview
sudo comfyui-monitor

# Service status
sudo systemctl status comfyui-multitenant

# Real-time logs
sudo journalctl -u comfyui-multitenant -f

# Tenant-specific logs
sudo tail -f /workspace/[tenant]/*.log
```

## 🛠️ Features

### Core Functionality
- ✅ Multi-tenant ComfyUI instance management
- ✅ REST API for programmatic control
- ✅ Automatic port assignment and conflict resolution
- ✅ Per-tenant workspace isolation
- ✅ Health monitoring and auto-recovery
- ✅ Resource usage tracking

### System Integration
- ✅ SystemD service management
- ✅ CloudWatch logging integration
- ✅ Log rotation and archival
- ✅ AWS CLI and S3 integration
- ✅ GPU support and optimization

### Development & Operations
- ✅ Comprehensive testing framework
- ✅ Performance monitoring scripts
- ✅ Automated AMI preparation
- ✅ Migration tools from Docker
- ✅ Troubleshooting guides

## 📋 Requirements

### System Requirements
- **OS**: Ubuntu 22.04 LTS
- **Instance**: g4dn.xlarge or larger (GPU workloads)
- **Storage**: 20GB+ EBS volume
- **Memory**: 16GB+ RAM recommended
- **Network**: VPC with internet access

### AWS Services (Optional)
- **S3**: Model storage and sharing
- **CloudWatch**: Centralized logging
- **EC2**: Instance management
- **IAM**: Service permissions

## 🗂️ Project Structure

```
├── scripts/
│   ├── prepare_ami.sh              # Main AMI preparation script
│   ├── tenant_manager.py           # Multi-tenant manager
│   ├── setup_cloudwatch.sh         # CloudWatch configuration
│   ├── create_s3_interactor.sh     # S3 integration tools
│   └── [other utility scripts]
├── docs/
│   ├── AMI_DEPLOYMENT.md           # Complete deployment guide
│   ├── DOCKER_TO_AMI_MIGRATION.md  # Migration guide
│   ├── CONNECTIVITY_TESTING.md     # Troubleshooting guide
│   └── NETWORK_CONFIGURATION.md    # Network setup guide
├── test/
│   ├── integration/                # Integration tests
│   ├── unit/                       # Unit tests
│   └── fixtures/                   # Test data
└── custom_nodes/                   # ComfyUI extensions
    ├── Comfyui-FileSytem-Manager/
    ├── ComfyUI-GoogleDrive-Downloader/
    └── Comfyui-Idle-Checker/
```

## 📚 Documentation

### Deployment Guides
- **[AMI Deployment Guide](docs/AMI_DEPLOYMENT.md)** - Complete setup process
- **[Docker to AMI Migration](docs/DOCKER_TO_AMI_MIGRATION.md)** - Migration steps
- **[Connectivity Testing](docs/CONNECTIVITY_TESTING.md)** - Troubleshooting network issues
- **[Network Configuration](docs/NETWORK_CONFIGURATION.md)** - VPC and subnet setup

### API Documentation
- **[Tenant Management API](docs/API.md)** - REST endpoints and usage
- **[Health Monitoring](docs/MONITORING.md)** - Health check details
- **[Performance Tuning](docs/PERFORMANCE.md)** - Optimization guide

## 🧪 Testing

### Run Test Suite
```bash
# Run all tests
./test/run_tests.sh

# Run specific test category
./test/integration/test_model_management.sh
./test/unit/test_tenant_manager.sh
```

### Integration Testing
- Multi-tenant isolation verification
- Resource usage and performance testing
- Health monitoring and recovery testing
- S3 integration testing

## 🔄 Migration Support

### From Docker to AMI
```bash
# Use migration guide and scripts
./docs/DOCKER_TO_AMI_MIGRATION.md

# Automated migration testing
./test/integration/test_migration.sh
```

### From Other Platforms
- RunPod → EC2 AMI migration tools
- Kubernetes → Direct EC2 migration
- Bare metal → AMI packaging

## 🛡️ Security & Isolation

### Tenant Isolation
- **Process isolation**: Each tenant runs as separate process
- **Filesystem isolation**: Dedicated workspace directories
- **Network isolation**: Unique port assignment per tenant
- **Resource limits**: CPU and memory controls (configurable)

### Security Features
- **No privileged containers**: Direct process execution
- **Standard Linux permissions**: File system access control
- **Network security**: Security group integration
- **Audit logging**: Complete action logging

## 🚀 Performance Optimizations

### System Optimizations
- GPU driver optimization for ML workloads
- Memory management for large model loading
- I/O optimization for model file access
- Network optimization for multi-tenant access

### Monitoring & Alerts
- Resource usage tracking per tenant
- Performance metrics collection
- Automated alerting for issues
- CloudWatch dashboard integration

## 🤝 Contributing

We welcome contributions! Please see our [Contributing Guide](CONTRIBUTING.md) for details.

### Development Setup
```bash
# Clone repository
git clone https://github.com/your-org/comfyui-multitenant

# Set up development environment
./scripts/setup_dev_environment.sh

# Run tests
./test/run_tests.sh
```

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- **ComfyUI Team** - For the amazing ComfyUI framework
- **Dreamshot.io** - For sponsoring this project
- **AWS Community** - For EC2 and infrastructure support
- **Contributors** - Everyone who helps improve this project

## 📞 Support

- 📖 **Documentation**: Check the [docs/](docs/) directory
- 🐛 **Issues**: Create a GitHub issue
- 💬 **Discussions**: Use GitHub Discussions
- 📧 **Contact**: For commercial support inquiries

---

<div align="center">

**⭐ Star this repository if it helps your ComfyUI deployment! ⭐**

</div>
