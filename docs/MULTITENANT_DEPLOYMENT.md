# Multi-Tenant ComfyUI Docker System

This document describes the multi-tenant ComfyUI system designed for AWS EC2 deployment with AMI bundling for fast startup.

## Overview

The system provides a management HTTP server on port 80 that can start, stop, and monitor multiple ComfyUI instances for different users on the same EC2 instance. Each tenant gets their own isolated environment and network volume.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    EC2 Instance                             │
│                                                             │
│  ┌─────────────────┐    ┌─────────────────────────────────┐ │
│  │ Management API  │    │         Docker Engine           │ │
│  │   (Port 80)     │    │                                 │ │
│  └─────────────────┘    │  ┌─────────────────────────────┐ │ │
│           │              │  │     ComfyUI Container      │ │ │
│           │              │  │    (Tenant Manager)        │ │ │
│           └──────────────┼─▶│                            │ │ │
│                          │  │  Spawns tenant processes:  │ │ │
│                          │  │  • Port 8001: User A       │ │ │
│  ┌─────────────────┐    │  │  • Port 8002: User B        │ │ │
│  │   CloudWatch    │◀───┼──│  • Port 8003: User C        │ │ │
│  │    Logging      │    │  │  • ...                      │ │ │
│  └─────────────────┘    │  └─────────────────────────────┘ │ │
│                          └─────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## API Endpoints

### Management Endpoints

#### Health Check
```http
GET /health
```
Returns system health status and basic metrics.

#### System Metrics
```http
GET /metrics
```
Returns detailed system metrics including CPU, memory, GPU usage, and tenant information.

### Tenant Management

#### Start Tenant
```http
POST /start
Content-Type: application/json

{
    "POD_ID": "user-123-session-456",
    "POD_USERNAME": "user123",
    "PORT": 8001,
    "env": {
        "NETWORK_VOLUME": "/tmp/tenant_user-123-session-456",
        "AWS_BUCKET_NAME": "my-comfyui-bucket",
        "AWS_ACCESS_KEY_ID": "AKIA...",
        "AWS_SECRET_ACCESS_KEY": "...",
        "AWS_REGION": "us-east-1",
        "_NETWORK_VOLUME": "/shared/user123"
    }
}
```

Response:
```json
{
    "status": "started",
    "port": 8001,
    "pid": 12345,
    "network_volume": "/tmp/tenant_user-123-session-456"
}
```

#### Stop Tenant
```http
POST /stop
Content-Type: application/json

{
    "POD_ID": "user-123-session-456"
}
```

Response:
```json
{
    "status": "stopped"
}
```

### Utility Endpoints

#### Execute Command
```http
POST /execute
Content-Type: application/json

{
    "command": "nvidia-smi"
}
```

## Environment Variables

### Required for Each Tenant
- `POD_ID`: Unique identifier for the tenant instance
- `POD_USERNAME`: Username for the tenant
- `NETWORK_VOLUME`: Tenant-specific storage directory
- `COMFYUI_PORT`: Port for the ComfyUI instance

### AWS Configuration
- `AWS_BUCKET_NAME`: S3 bucket for data persistence
- `AWS_ACCESS_KEY_ID`: AWS access key
- `AWS_SECRET_ACCESS_KEY`: AWS secret key
- `AWS_REGION`: AWS region

### Optional Optimization
- `_NETWORK_VOLUME`: Shared network volume for optimization

## Deployment with AMI

### Building the AMI

1. **Launch EC2 Instance**:
   ```bash
   # Use Ubuntu 22.04 LTS
   # Instance type: g4dn.xlarge or similar (GPU recommended)
   ```

2. **Prepare Instance**:
   ```bash
   # Copy preparation script to instance
   scp scripts/prepare_ami.sh ubuntu@<instance-ip>:~/
   
   # Run preparation
   ssh ubuntu@<instance-ip>
   sudo bash prepare_ami.sh
   ```

3. **Create AMI**:
   - Stop the instance
   - Create AMI through AWS Console
   - Name: `comfyui-multitenant-v1.0`

### Launching from AMI

1. **Launch Instance**:
   ```bash
   # Use the created AMI
   # Attach IAM role with CloudWatch and S3 permissions
   ```

2. **Verify Service**:
   ```bash
   # Check service status
   sudo systemctl status comfyui-multitenant
   
   # Monitor system
   comfyui-monitor
   
   # Check API
   curl http://localhost:80/health
   ```

## CloudWatch Integration

### Log Groups
- `/aws/ec2/comfyui/tenant-manager`: Management server logs
- `/aws/ec2/comfyui/tenant-startup`: Tenant startup logs
- `/aws/ec2/comfyui/tenant-runtime`: ComfyUI runtime logs
- `/aws/ec2/comfyui/tenant-user-scripts`: User script execution logs

### Metrics
- System CPU, memory, disk usage
- GPU utilization and memory
- Network I/O
- Active tenant count

### Setup
CloudWatch is automatically configured during AMI preparation. Ensure the EC2 instance has appropriate IAM permissions:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents",
                "logs:DescribeLogStreams",
                "cloudwatch:PutMetricData"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::your-bucket-name",
                "arn:aws:s3:::your-bucket-name/*"
            ]
        }
    ]
}
```

## Network Volume Optimization

The system supports network volume optimization for shared data:

- **Shared Data**: Virtual environments, configurations, custom nodes
- **Symlink Strategy**: Create symlinks from tenant volume to shared volume
- **Performance**: Significant startup time reduction for subsequent tenants

## Process Management

### Process Tracking
- Processes stored in `/tmp/comfyui_processes.json`
- Automatic cleanup of dead processes
- PID-based process lifecycle management

### Resource Isolation
- Each tenant runs in isolated environment
- Separate log files and directories
- Port allocation prevents conflicts

## Monitoring and Troubleshooting

### System Status
```bash
# Check overall system
comfyui-monitor

# Check specific service
sudo systemctl status comfyui-multitenant

# View logs
sudo journalctl -u comfyui-multitenant -f
```

### API Testing
```bash
# Test system
/scripts/test_multitenant.sh

# Manual tests
curl http://localhost:80/health
curl http://localhost:80/metrics
```

### Common Issues

1. **Port Conflicts**: Ensure ports 8000-8100 are available
2. **Storage Issues**: Check disk space and permissions
3. **GPU Access**: Verify NVIDIA drivers and Docker GPU support
4. **Network Issues**: Check security groups and firewall rules

## Security Considerations

- Each tenant runs with isolated environment variables
- Process isolation through separate process groups
- File system isolation through separate directories
- Network isolation through dedicated ports

## Performance Optimization

- Use network volume optimization for shared data
- Pre-pull Docker images in AMI
- Configure appropriate instance types (GPU recommended)
- Monitor resource usage through CloudWatch metrics

## Scaling

- **Vertical**: Use larger instance types for more tenants
- **Horizontal**: Deploy multiple instances behind load balancer
- **Auto-scaling**: Use CloudWatch metrics for scaling decisions

## Cost Optimization

- Use Spot instances for development/testing
- Implement auto-shutdown for idle tenants
- Use CloudWatch for usage-based billing tracking
