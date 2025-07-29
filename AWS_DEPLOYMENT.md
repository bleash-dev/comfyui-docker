# AWS Deployment Guide

This guide explains how to deploy the ComfyUI Multi-Tenant system to AWS using ECR and AMI.

## Overview

The deployment process consists of two main jobs:
1. **Build and Push**: Builds Docker image and pushes to Amazon ECR Public
2. **Create AMI**: Creates an EC2 AMI with the Docker image pre-installed

## Required AWS Resources

### IAM Role for GitHub Actions

Create an IAM role for GitHub OIDC with the following permissions:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ecr-public:*",
                "ec2:*",
                "ssm:*",
                "iam:PassRole"
            ],
            "Resource": "*"
        }
    ]
}
```

### Required Secrets

Configure these secrets in your GitHub repository:

- `GH_ROLE_ARN`: ARN of the IAM role for GitHub Actions

### Optional Secrets (for advanced configurations)

These are only needed if you want custom networking or SSH access:

- `EC2_KEY_NAME`: Name of EC2 key pair (only if you need SSH debugging)
- `EC2_SECURITY_GROUP_ID`: Security group ID (only if you need custom networking)
- `EC2_SUBNET_ID`: Subnet ID (only if you need specific subnet placement)
- `EC2_INSTANCE_PROFILE`: Instance profile name (only if you need ECR/CloudWatch permissions during build)

### Environment Configuration

Update the workflow file with your values:

```yaml
env:
  AWS_REGION: us-east-1
  IMAGE_NAME: comfyui-docker
  PUBLIC_REGISTRY_ALIAS: your-ecr-alias  # Update this!
```

## Deployment Process

### 1. Docker Image Build

- Builds multi-tenant ComfyUI Docker image
- Pushes to ECR Public registry
- Tags based on branch:
  - `main` branch → `latest` tag
  - `dev` branch → `dev-latest` tag
- Creates separate repositories for dev/prod environments

### 2. AMI Creation

- Launches Ubuntu EC2 instance
- Installs Docker and system dependencies
- Pulls the newly built Docker image
- Configures CloudWatch logging
- Creates multi-tenant directory structure
- Sets up auto-start services
- Creates AMI and terminates builder instance

## Usage

### Launching from AMI

1. Launch EC2 instance from the created AMI
2. The ComfyUI management service starts automatically on port 80
3. Access the management API at `http://<instance-ip>/`

### Available Endpoints

- `GET /health` - Health check
- `GET /metrics` - System and tenant metrics
- `POST /start` - Start a new tenant
- `POST /stop` - Stop a tenant
- `POST /execute` - Execute commands

### Tenant Workspace Structure

Each tenant gets its own workspace:
```
/workspace/<pod-id>/
├── logs/
│   ├── startup.log
│   ├── comfyui.log
│   └── user-script.log
├── scripts/
├── ComfyUI/
└── venv/
```

## Monitoring

### CloudWatch Integration

Logs are automatically streamed to CloudWatch:
- `/aws/ec2/comfyui/tenant-manager` - Management server logs
- `/aws/ec2/comfyui/tenant-startup` - Tenant startup logs
- `/aws/ec2/comfyui/tenant-runtime` - ComfyUI runtime logs
- `/aws/ec2/comfyui/tenant-user-scripts` - User script execution logs

### System Monitoring

Use the built-in monitoring command:
```bash
comfyui-monitor
```

## Environment Differences

### Production (`main` branch)
- ECR repository: `comfyui-docker`
- AMI name: `comfyui-multitenant-prod-*`
- Docker tag: `latest`

### Development (`dev` branch)
- ECR repository: `comfyui-docker-dev`
- AMI name: `comfyui-multitenant-dev-*`
- Docker tag: `dev-latest`

## Cost Optimization

- AMI builder instances are automatically terminated after AMI creation
- Use appropriate instance types for your workload
- Monitor CloudWatch costs and set retention policies
- Consider using EC2 Spot instances for non-production workloads

## Troubleshooting

### Common Issues

1. **ECR Access Denied**: Ensure the GitHub OIDC role has proper ECR permissions
2. **AMI Build Timeout**: Increase the timeout or check instance logs via SSM
3. **Docker Pull Failed**: Verify the ECR repository exists and image was pushed
4. **Instance Launch Failed**: Check security group, subnet, and key pair configuration

### Debugging

Check AMI builder logs:
```bash
aws ssm start-session --target <instance-id>
sudo tail -f /var/log/ami-preparation.log
```

View CloudWatch logs:
```bash
aws logs tail /aws/ec2/comfyui/tenant-manager --follow
```
