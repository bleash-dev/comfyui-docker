# ComfyUI Connectivity Testing Guide

This guide helps you test and debug connectivity issues with ComfyUI instances using the provided testing scripts.

## 🚀 Quick Start

### 1. Launch a Test Instance

```bash
# Launch a test instance with automatic setup
./scripts/test_instance.sh launch my-test-instance

# Wait 2-3 minutes for setup to complete, then check status
./scripts/test_instance.sh status my-test-instance
```

### 2. Test Connectivity

```bash
# Get the public IP from the status command above, then test it
./scripts/test_connectivity.sh 1.2.3.4

# Test specific port only
./scripts/test_connectivity.sh 1.2.3.4 8188
```

### 3. Debug Issues

```bash
# View instance logs
./scripts/test_instance.sh logs my-test-instance

# Get connection details
./scripts/test_instance.sh connect my-test-instance

# List all test instances
./scripts/test_instance.sh list
```

### 4. Clean Up

```bash
# Stop the test instance when done
./scripts/test_instance.sh stop my-test-instance
```

## 📋 What the Test Instance Does

The test instance automatically sets up:

1. **Web Server on Port 80**: Simple test page showing instance info
2. **ComfyUI Test on Port 8188**: Mimics ComfyUI port for connectivity testing
3. **Docker**: Pre-installed and configured
4. **System Monitoring**: Tools for debugging connectivity issues

## 🔍 Understanding Test Results

### Successful Connectivity

If everything works, you should see:
- ✅ Ping successful (may fail due to ICMP blocking - normal)
- ✅ Port 80 accessible
- ✅ Port 8188 accessible  
- ✅ HTTP responses from both ports

### Common Issues and Solutions

#### Port 80 works, Port 8188 doesn't
**Likely cause**: Security group doesn't allow port 8188

**Solution**: 
```bash
# Check security group rules
aws ec2 describe-security-groups --group-ids sg-xxxxxx

# Add rule for port 8188
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxxx \
  --protocol tcp \
  --port 8188 \
  --cidr 0.0.0.0/0
```

#### Neither port works
**Likely causes**:
1. Security group blocks all traffic
2. Instance not in public subnet
3. No internet gateway route
4. Network ACL blocking traffic

**Solution**: Use the debug scripts to check each component

#### Connection timeout
**Likely causes**:
1. Instance not running
2. Network configuration issues
3. Firewall blocking traffic

## 🛠️ Advanced Debugging

### Check Network Configuration
```bash
# Debug the exact VPC/subnet selection logic used by the workflow
./scripts/debug_network.sh us-east-1

# Test specific AWS CLI queries
./scripts/test_network_queries.sh us-east-1
```

### Manual AWS CLI Checks
```bash
# Find your instance
aws ec2 describe-instances --filters "Name=tag:Name,Values=my-test-instance"

# Check security group rules
aws ec2 describe-security-groups --group-ids sg-xxxxxx

# Check subnet configuration
aws ec2 describe-subnets --subnet-ids subnet-xxxxxx

# Check route table
aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=subnet-xxxxxx"
```

### Connect via SSM (if SSH not available)
```bash
# Connect to instance via SSM Session Manager
aws ssm start-session --target i-xxxxxx

# Run commands on instance via SSM
aws ssm send-command \
  --instance-ids i-xxxxxx \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo netstat -tlnp"]'
```

## 🔧 Script Configuration

### Customize Test Instance Script

Edit `/scripts/test_instance.sh` to modify:

- **Instance Type**: Change `INSTANCE_TYPE="t3.large"`
- **Region**: Change `AWS_REGION="us-east-1"`
- **IAM Role**: Already set to `viral-comm-api-shared-instance-profile-dev`
- **Key Pair**: Set `KEY_PAIR_NAME="your-key"` for SSH access
- **Preferred Subnet**: Set `PREFERRED_SUBNET_ID="subnet-xxxxxx"` to use specific subnet
- **Preferred Security Group**: Set `PREFERRED_SG_ID="sg-xxxxxx"` to use specific security group

**Note**: The script will attempt to use preferred subnet/security group first, then fall back to auto-detection if they're not available or not compatible.

### Add SSH Key Support

If you want SSH access to test instances:

1. Edit `test_instance.sh`
2. Set `KEY_PAIR_NAME="your-existing-key-pair"`
3. The script will include the key pair in launched instances

## 🎯 Expected Behavior

### Successful Test Instance
- Web page accessible at `http://public-ip`
- ComfyUI test page at `http://public-ip:8188`
- Both pages load within 5 seconds
- No connection timeouts or refused connections

### Working ComfyUI Instance
- Should behave exactly like the test instance
- ComfyUI interface loads at port 8188
- No connectivity errors in browser console

## 📞 Troubleshooting Help

If you're still having issues after running these tests:

1. **Capture test output**: Run tests and save output to file
2. **Check AWS Console**: Verify VPC, subnet, security group, and route table configuration
3. **Compare working vs broken**: Use test instance as baseline for comparison
4. **Check service logs**: Use SSM or SSH to check ComfyUI service logs

### Common AWS Networking Issues

1. **Security Group**: Most common cause - ports not open
2. **Network ACL**: Less common - check both inbound and outbound rules  
3. **Route Table**: Missing 0.0.0.0/0 → internet gateway route
4. **Subnet**: Instance in private subnet without NAT gateway
5. **Public IP**: Instance doesn't have public IP assigned

The test scripts will help identify which of these is the issue.
