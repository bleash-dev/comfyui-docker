# Manual AMI Management for ComfyUI

This directory contains scripts for manual AMI creation and management, providing a simpler alternative to automated CI/CD pipelines.

## Overview

The manual AMI workflow allows you to:
1. Launch a base instance
2. Make changes and test manually
3. Create a new AMI from the configured instance
4. Update SSM parameters to point to the new AMI
5. Terminate the build instance

## Scripts

### Core Scripts

- **`launch_build_instance.sh`** - Launch an EC2 instance for AMI building
- **`create_ami.sh`** - Create an AMI from a running instance and update SSM parameters
- **`manage_instance.sh`** - Start/stop/status of build instances
- **`cleanup_old_amis.sh`** - Clean up old AMIs to save costs

### Utility Scripts

- **`list_amis.sh`** - List all ComfyUI AMIs with details
- **`validate_ami.sh`** - Test an AMI by launching a test instance
- **`rollback_ami.sh`** - Rollback to a previous AMI version

## Quick Start

### 1. Launch Build Instance

```bash
# Launch a new build instance
./launch_build_instance.sh

# Or launch with a specific name
./launch_build_instance.sh my-build-instance
```

### 2. Configure Your Instance

SSH into the instance and make your changes:
- Install software
- Configure settings
- Test functionality

### 3. Create AMI

```bash
# Create AMI from the running instance
./create_ami.sh my-build-instance

# Or create with custom AMI name
./create_ami.sh my-build-instance "v2.1.0-custom-features"

# Create AMI and automatically terminate the source instance
./create_ami.sh --terminate-instance my-build-instance "Production ready AMI"
```

### 4. Validate (Optional)

```bash
# Test the new AMI
./validate_ami.sh ami-1234567890abcdef0
```

### 5. Cleanup

```bash
# Clean up old AMIs (keeps last 5)
./cleanup_old_amis.sh

# Note: If you used --terminate-instance option, the build instance is already terminated
```

## Configuration

### Environment Variables

The scripts use shared configuration from `common.sh` for consistency with test instances:

```bash
# AWS Configuration
AWS_REGION=us-east-1
AWS_PROFILE=default  # Optional

# Instance Configuration - Same as GitHub Actions
BUILD_INSTANCE_TYPE=c5d.large  # CPU optimized with local NVMe SSD for faster builds
BUILD_KEY_PAIR=your-key-pair-name
BUILD_SUBNET_ID=subnet-028352ae3329680c0  # Same as test_instance.sh
BUILD_SECURITY_GROUP=sg-04fc7bbc5e0bb8362  # Same as test_instance.sh

# IAM Configuration - Same as test_instance.sh
BUILD_IAM_ROLE=viral-comm-api-shared-instance-profile-dev

# AMI Configuration
AMI_PREFIX=comfyui-multitenant
ENVIRONMENT=dev
SSM_PARAMETER_PATH=/comfyui/ami

# Cleanup Configuration
KEEP_AMI_COUNT=5  # Number of AMIs to keep during cleanup
```

## Configuration Summary

These scripts use the **same network configuration** as `test/test_instance.sh` for consistency:
- VPC: `viral-comm-api-proxy-vpc-dev` (auto-detected)
- Subnet: `subnet-028352ae3329680c0`
- Security Group: `sg-04fc7bbc5e0bb8362`
- IAM Role: `viral-comm-api-shared-instance-profile-dev`
- Region: `us-east-1`

**Instance Type Differences:**
- **AMI Build**: `c5d.large` (same as GitHub Actions - CPU optimized with local NVMe SSD)
- **Testing**: `g4dn.xlarge` (GPU enabled for running ComfyUI workloads)

This ensures AMIs are built in the same network environment where they'll be tested and deployed.

### SSM Parameters

The scripts manage these SSM parameters:

- `/comfyui/ami/{environment}/latest` - Latest AMI ID
- `/comfyui/ami/{environment}/previous` - Previous AMI ID (for rollbacks)
- `/comfyui/ami/{environment}/build-info` - Build metadata

## Workflow Examples

### Basic Update Workflow

```bash
# 1. Launch instance
./launch_build_instance.sh update-$(date +%Y%m%d)

# 2. SSH and make changes
ssh -i ~/.ssh/your-key.pem ubuntu@<instance-ip>

# 3. Create AMI and terminate instance automatically
./create_ami.sh --terminate-instance update-$(date +%Y%m%d) "Update-$(date +%Y%m%d)-bug-fixes"

# 4. Validate
./validate_ami.sh $(aws ssm get-parameter --name /comfyui/ami/dev/latest --query 'Parameter.Value' --output text)

# 5. Clean up old AMIs
./cleanup_old_amis.sh
```

### Manual Instance Management Workflow

```bash
# 1. Launch instance
./launch_build_instance.sh update-$(date +%Y%m%d)

# 2. SSH and make changes
ssh -i ~/.ssh/your-key.pem ubuntu@<instance-ip>

# 3. Create AMI (keep instance for testing)
./create_ami.sh update-$(date +%Y%m%d) "Update-$(date +%Y%m%d)-bug-fixes"

# 4. Validate
./validate_ami.sh $(aws ssm get-parameter --name /comfyui/ami/dev/latest --query 'Parameter.Value' --output text)

# 5. Manually terminate when ready
./manage_instance.sh terminate update-$(date +%Y%m%d)
```

### Emergency Rollback

```bash
# Rollback to previous AMI
./rollback_ami.sh

# Or rollback to specific AMI
./rollback_ami.sh ami-1234567890abcdef0
```

### Development Testing

```bash
# Launch development instance
./launch_build_instance.sh dev-test-$(whoami)

# Make experimental changes...

# Create development AMI (doesn't update production SSM, but terminates instance)
./create_ami.sh --no-ssm-update --terminate-instance dev-test-$(whoami) "experimental-features"

# Test the AMI
./validate_ami.sh <new-ami-id>
```

## Best Practices

### Before Building

1. **Plan your changes** - Document what you're updating
2. **Check current state** - Run `./list_amis.sh` to see current AMIs
3. **Backup strategy** - Ensure previous AMI is working before replacing

### During Building

1. **Use screen/tmux** - For long-running installations
2. **Test thoroughly** - Validate all functionality works
3. **Document changes** - Keep notes of what was modified
4. **Clean up** - Remove temporary files and logs

### After Building

1. **Validate immediately** - Test the new AMI
2. **Update documentation** - Record the changes made
3. **Monitor deployments** - Watch for issues in production
4. **Clean up resources** - Terminate build instances

## Troubleshooting

### Instance Won't Start

```bash
# Check instance status
./manage_instance.sh status my-instance

# Check instance logs
aws ec2 get-console-output --instance-id i-1234567890abcdef0
```

### AMI Creation Fails

```bash
# Check if instance is stopped
./manage_instance.sh stop my-instance

# Retry AMI creation
./create_ami.sh my-instance
```

### SSM Parameter Issues

```bash
# List all ComfyUI SSM parameters
aws ssm get-parameters-by-path --path "/comfyui" --recursive

# Check specific parameter
aws ssm get-parameter --name "/comfyui/ami/dev/latest"
```

## Security Considerations

1. **IAM Permissions** - Ensure your AWS credentials have necessary permissions
2. **Security Groups** - Use restrictive security groups for build instances
3. **Key Management** - Protect your EC2 key pairs
4. **Network Access** - Consider using private subnets for sensitive builds

## Cost Optimization

1. **Instance Types** - Use appropriate instance types for your workload
2. **AMI Cleanup** - Regularly clean up old AMIs
3. **Snapshot Management** - Monitor EBS snapshot costs
4. **Instance Termination** - Always terminate build instances when done

## Advanced Usage

### Custom Instance Configuration

Create a custom configuration file:

```bash
# config/custom-build.env
BUILD_INSTANCE_TYPE=g4dn.2xlarge
BUILD_SUBNET_ID=subnet-custom123
AMI_PREFIX=comfyui-custom
```

Use it:

```bash
./launch_build_instance.sh --config config/custom-build.env my-instance
```

### Multi-Environment Management

```bash
# Build for different environments
ENVIRONMENT=staging ./create_ami.sh my-instance
ENVIRONMENT=prod ./create_ami.sh my-instance
```

### Integration with External Tools

```bash
# Use with Terraform
LATEST_AMI=$(aws ssm get-parameter --name /comfyui/ami/prod/latest --query 'Parameter.Value' --output text)
terraform apply -var="ami_id=$LATEST_AMI"
```

## Support

For issues with these scripts:

1. Check the troubleshooting section above
2. Review AWS CloudTrail logs for API errors
3. Verify IAM permissions
4. Check instance logs and system status

Remember: This manual process gives you full control but requires careful attention to detail. Always test changes thoroughly before deploying to production.
