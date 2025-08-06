#!/bin/bash

# EC2 Test Instance Management Script
# Launch/stop EC2 instances for testing ComfyUI connectivity issues

set -e

# Configuration
AWS_REGION="us-east-1"
INSTANCE_TYPE="g4dn.xlarge"  # GPU instance with A10G (24GB GPU memory) + 250GB ephemeral NVMe SSD - ideal for ComfyUI
IAM_ROLE_NAME="viral-comm-api-shared-instance-profile-dev"  # Will be auto-detected from available instance profiles
KEY_PAIR_NAME=""  # Optional: Add your key pair name here for SSH access

# Network Configuration (with fallback to auto-detection)
PREFERRED_SUBNET_ID="subnet-028352ae3329680c0"  # Specific subnet for testing
PREFERRED_SG_ID="sg-04fc7bbc5e0bb8362"          # Specific security group for testing

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_usage() {
    echo "Usage: $0 [launch|stop|status|connect|logs] [instance-name]"
    echo ""
    echo "Commands:"
    echo "  launch [name]  - Launch a new test instance"
    echo "  stop [name]    - Stop/terminate an instance"
    echo "  status [name]  - Show instance status"
    echo "  connect [name] - Show connection information"
    echo "  logs [name]    - Get instance logs via SSM"
    echo "  list          - List all test instances"
    echo ""
    echo "Examples:"
    echo "  $0 launch test-connectivity"
    echo "  $0 status test-connectivity"
    echo "  $0 logs test-connectivity"
    echo "  $0 stop test-connectivity"
}

get_vpc_and_subnet() {
    echo -e "${BLUE}🔍 Finding VPC and subnet...${NC}"
    
    # First try to use the preferred subnet if specified
    if [[ -n "$PREFERRED_SUBNET_ID" ]]; then
        echo -e "${BLUE}🎯 Checking preferred subnet: $PREFERRED_SUBNET_ID${NC}"
        
        # Verify the subnet exists and get its VPC
        SUBNET_CHECK=$(aws ec2 describe-subnets \
            --subnet-ids "$PREFERRED_SUBNET_ID" \
            --query 'Subnets[0].[SubnetId,VpcId,AvailabilityZone,MapPublicIpOnLaunch]' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "")
        
        if [[ -n "$SUBNET_CHECK" && "$SUBNET_CHECK" != "None" ]]; then
            read -r SUBNET_ID VPC_ID AZ PUBLIC_IP_ON_LAUNCH <<< "$SUBNET_CHECK"
            
            # Get subnet and VPC names
            SUBNET_NAME=$(aws ec2 describe-subnets \
                --subnet-ids "$SUBNET_ID" \
                --query 'Subnets[0].Tags[?Key==`Name`].Value' \
                --output text \
                --region "$AWS_REGION" 2>/dev/null || echo "No name tag")
            
            VPC_NAME=$(aws ec2 describe-vpcs \
                --vpc-ids "$VPC_ID" \
                --query 'Vpcs[0].Tags[?Key==`Name`].Value' \
                --output text \
                --region "$AWS_REGION" 2>/dev/null || echo "No name tag")
            
            echo -e "${GREEN}✅ Using preferred subnet: $SUBNET_ID (Name: $SUBNET_NAME)${NC}"
            echo -e "${GREEN}✅ VPC: $VPC_ID (Name: $VPC_NAME)${NC}"
            echo -e "${BLUE}📋 Subnet details: AZ=$AZ, Public IP on launch=$PUBLIC_IP_ON_LAUNCH${NC}"
            return 0
        else
            echo -e "${YELLOW}⚠️ Preferred subnet not found or not accessible, falling back to auto-detection...${NC}"
        fi
    fi
    
    # Try to find preferred VPC first
    VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=viral-comm-api-viral-community-stack-dev/viral-comm-api-common-networking-dev/viral-comm-api-proxy-vpc-dev" \
        --query 'Vpcs[0].VpcId' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "")
    
    # Fallback: Try pattern match
    if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
        echo -e "${YELLOW}⚠️ Preferred VPC not found, trying pattern match...${NC}"
        VPC_ID=$(aws ec2 describe-vpcs \
            --filters "Name=tag:Name,Values=*proxy-vpc-dev" \
            --query 'Vpcs[0].VpcId' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "")
    fi
    
    # Fallback: Default VPC
    if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
        echo -e "${YELLOW}⚠️ No proxy VPC found, using default VPC...${NC}"
        VPC_ID=$(aws ec2 describe-vpcs \
            --filters "Name=is-default,Values=true" \
            --query 'Vpcs[0].VpcId' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "")
    fi
    
    # Final fallback: Any VPC
    if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
        echo -e "${YELLOW}⚠️ No default VPC found, using any available VPC...${NC}"
        VPC_ID=$(aws ec2 describe-vpcs \
            --query 'Vpcs[0].VpcId' \
            --output text \
            --region "$AWS_REGION")
    fi
    
    # Get VPC name
    VPC_NAME=$(aws ec2 describe-vpcs \
        --vpc-ids "$VPC_ID" \
        --query 'Vpcs[0].Tags[?Key==`Name`].Value' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "No name tag")
    
    echo -e "${GREEN}✅ Selected VPC: $VPC_ID (Name: $VPC_NAME)${NC}"
    
    # Find subnet
    echo -e "${BLUE}🔍 Finding subnet in VPC...${NC}"
    
    # Try preferred subnet pattern
    SUBNET_ID=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=*vpc-proxy-subnetSubnet1*" \
        --query 'Subnets[0].SubnetId' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "")
    
    # Fallback: Any public subnet
    if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
        echo -e "${YELLOW}⚠️ Preferred subnet not found, looking for public subnet...${NC}"
        SUBNET_ID=$(aws ec2 describe-subnets \
            --filters "Name=vpc-id,Values=${VPC_ID}" "Name=map-public-ip-on-launch,Values=true" \
            --query 'Subnets[0].SubnetId' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "")
    fi
    
    # Final fallback: Any subnet
    if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
        echo -e "${YELLOW}⚠️ No public subnet found, using any subnet...${NC}"
        SUBNET_ID=$(aws ec2 describe-subnets \
            --filters "Name=vpc-id,Values=${VPC_ID}" \
            --query 'Subnets[0].SubnetId' \
            --output text \
            --region "$AWS_REGION")
    fi
    
    # Get subnet details
    SUBNET_NAME=$(aws ec2 describe-subnets \
        --subnet-ids "$SUBNET_ID" \
        --query 'Subnets[0].Tags[?Key==`Name`].Value' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "No name tag")
    
    SUBNET_PUBLIC=$(aws ec2 describe-subnets \
        --subnet-ids "$SUBNET_ID" \
        --query 'Subnets[0].MapPublicIpOnLaunch' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "Unknown")
    
    echo -e "${GREEN}✅ Selected Subnet: $SUBNET_ID (Name: $SUBNET_NAME, Public: $SUBNET_PUBLIC)${NC}"
    
    # Check if we got preferred resources
    if [[ "$VPC_NAME" == *"viral-comm-api-proxy-vpc-dev"* ]]; then
        echo -e "${GREEN}🎉 Using preferred VPC!${NC}"
    else
        echo -e "${YELLOW}⚠️ Using fallback VPC${NC}"
    fi
    
    if [[ "$SUBNET_NAME" == *"vpc-proxy-subnetSubnet1"* ]]; then
        echo -e "${GREEN}🎉 Using preferred subnet!${NC}"
    else
        echo -e "${YELLOW}⚠️ Using fallback subnet${NC}"
    fi
}

get_security_group() {
    echo -e "${BLUE}🔍 Finding security group...${NC}"
    
    # First try to use the preferred security group if specified
    if [[ -n "$PREFERRED_SG_ID" ]]; then
        echo -e "${BLUE}🎯 Checking preferred security group: $PREFERRED_SG_ID${NC}"
        
        # Verify the security group exists and is in the right VPC
        SG_CHECK=$(aws ec2 describe-security-groups \
            --group-ids "$PREFERRED_SG_ID" \
            --query 'SecurityGroups[0].[GroupId,VpcId,GroupName]' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "")
        
        if [[ -n "$SG_CHECK" && "$SG_CHECK" != "None" ]]; then
            read -r SG_ID SG_VPC_ID SG_NAME <<< "$SG_CHECK"
            
            # Check if the security group is in the same VPC as our subnet
            if [[ "$SG_VPC_ID" == "$VPC_ID" ]]; then
                echo -e "${GREEN}✅ Using preferred security group: $SG_ID (Name: $SG_NAME)${NC}"
                echo -e "${GREEN}✅ Security group VPC matches subnet VPC: $VPC_ID${NC}"
            else
                echo -e "${YELLOW}⚠️ Preferred security group is in different VPC ($SG_VPC_ID vs $VPC_ID), falling back...${NC}"
                SG_ID=""
            fi
        else
            echo -e "${YELLOW}⚠️ Preferred security group not found or not accessible, falling back to auto-detection...${NC}"
            SG_ID=""
        fi
    fi
    
    # Fall back to auto-detection if preferred SG not usable
    if [[ -z "$SG_ID" ]]; then
        echo -e "${BLUE}🔍 Auto-detecting security group...${NC}"
        
        # Try to find CDK-managed security group
        SG_ID=$(aws ec2 describe-security-groups \
            --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:aws:cloudformation:logical-id,Values=*SecurityGroup*" \
            --query 'SecurityGroups[0].GroupId' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "")
        
        # Fallback: Default security group
        if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
            echo -e "${YELLOW}⚠️ No CDK security group found, using default...${NC}"
            SG_ID=$(aws ec2 describe-security-groups \
                --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=default" \
                --query 'SecurityGroups[0].GroupId' \
                --output text \
                --region "$AWS_REGION")
        fi
        
        echo -e "${GREEN}✅ Auto-detected Security Group: $SG_ID${NC}"
    fi
    
    # Show security group rules
    echo -e "${BLUE}📋 Security Group Rules:${NC}"
    aws ec2 describe-security-groups \
        --group-ids "$SG_ID" \
        --query 'SecurityGroups[0].IpPermissions[*].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp]' \
        --output table \
        --region "$AWS_REGION" || echo "Could not retrieve rules"
}

get_comfyui_ami() {
    echo -e "${BLUE}🔍 Finding ComfyUI AMI...${NC}"
    
    # First try to get the latest ComfyUI AMI from SSM Parameter Store
    ENVIRONMENT="${DEPLOYMENT_TARGET:-dev}"  # Default to dev environment for testing
    
    echo -e "${BLUE}🔍 Checking SSM Parameter Store for ComfyUI AMI...${NC}"
    COMFYUI_AMI=$(aws ssm get-parameter \
        --name "/comfyui/ami/$ENVIRONMENT/latest" \
        --query 'Parameter.Value' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "")
    
    if [[ -n "$COMFYUI_AMI" && "$COMFYUI_AMI" != "None" ]]; then
        echo -e "${GREEN}✅ Found ComfyUI AMI from SSM: $COMFYUI_AMI${NC}"
        
        # Verify the AMI exists and is available
        AMI_STATE=$(aws ec2 describe-images \
            --image-ids "$COMFYUI_AMI" \
            --query 'Images[0].State' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "")
        
        if [[ "$AMI_STATE" == "available" ]]; then
            echo -e "${GREEN}✅ ComfyUI AMI is available and ready${NC}"
            SELECTED_AMI="$COMFYUI_AMI"
            AMI_TYPE="comfyui"
        else
            echo -e "${YELLOW}⚠️ ComfyUI AMI not available (state: $AMI_STATE), falling back...${NC}"
            SELECTED_AMI=""
        fi
    else
        echo -e "${YELLOW}⚠️ No ComfyUI AMI found in SSM Parameter Store, searching manually...${NC}"
        SELECTED_AMI=""
    fi
    
    # Fallback: Search for ComfyUI AMI by name pattern
    if [[ -z "$SELECTED_AMI" ]]; then
        echo -e "${BLUE}🔍 Searching for ComfyUI AMI by name pattern...${NC}"
        COMFYUI_AMI=$(aws ec2 describe-images \
            --owners self \
            --filters "Name=name,Values=comfyui-multitenant-*" \
            --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "")
        
        if [[ -n "$COMFYUI_AMI" && "$COMFYUI_AMI" != "None" ]]; then
            echo -e "${GREEN}✅ Found ComfyUI AMI by search: $COMFYUI_AMI${NC}"
            SELECTED_AMI="$COMFYUI_AMI"
            AMI_TYPE="comfyui"
        fi
    fi
    
    # Final fallback: Use Ubuntu AMI
    if [[ -z "$SELECTED_AMI" ]]; then
        echo -e "${YELLOW}⚠️ No ComfyUI AMI found, using Ubuntu AMI for basic testing...${NC}"
        UBUNTU_AMI=$(aws ec2 describe-images \
            --owners 099720109477 \
            --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
                "Name=state,Values=available" \
            --query "Images | sort_by(@, &CreationDate) | [-1].ImageId" \
            --output text \
            --region "$AWS_REGION")
        
        SELECTED_AMI="$UBUNTU_AMI"
        AMI_TYPE="ubuntu"
        echo -e "${GREEN}✅ Selected Ubuntu AMI: $SELECTED_AMI${NC}"
    fi
    
    # Show what we're using
    echo -e "${BLUE}📋 AMI Selection Summary:${NC}"
    echo "   AMI ID: $SELECTED_AMI"
    echo "   AMI Type: $AMI_TYPE"
    
    if [[ "$AMI_TYPE" == "comfyui" ]]; then
        echo -e "${GREEN}🎉 Using actual ComfyUI AMI - this will test the real deployment!${NC}"
    else
        echo -e "${YELLOW}⚠️ Using Ubuntu AMI - basic connectivity test only${NC}"
    fi
}

launch_instance() {
    local instance_name="${1:-comfyui-test-$(date +%Y%m%d-%H%M%S)}"
    
    echo -e "${BLUE}🚀 Launching test instance: $instance_name${NC}"
    
    # Get network configuration
    get_vpc_and_subnet
    get_security_group
    get_comfyui_ami
    
    # Create user data script for testing
    cat > user-data-test.sh << 'EOF'
#!/bin/bash
set -e

# Log everything
exec > >(tee /var/log/user-data.log) 2>&1
echo "=== ComfyUI Test Instance Started at $(date) ==="

# The ComfyUI AMI should already have everything set up
# We just need to ensure services are running and accessible

echo "🎨 ComfyUI AMI detected - checking existing services..."

# Check if the tenant manager is running
if systemctl is-active --quiet docker; then
    echo "✅ Docker is running"
else
    echo "🔧 Starting Docker..."
    systemctl start docker
    sleep 5
fi

# Check if the ComfyUI tenant manager is running  
if docker ps | grep -q tenant_manager; then
    echo "✅ ComfyUI tenant manager is already running"
else
    echo "🔧 ComfyUI tenant manager not detected in Docker, checking systemd..."
    
    # Try to start the tenant manager if it exists as a service
    if systemctl list-units --type=service | grep -q comfyui; then
        echo "🔧 Starting ComfyUI service..."
        systemctl start comfyui-multitenant.service || echo "⚠️ Could not start via systemctl"
    else
        echo "� Starting tenant manager manually..."
        cd /workspace
        # Start the tenant manager in the background
        nohup python3 /tenant_manager.py > /var/log/tenant_manager.log 2>&1 &
        sleep 10
    fi
fi

# Verify the tenant manager health endpoint
echo "🔍 Testing tenant manager health endpoint..."
for i in {1..30}; do
    if curl -s http://localhost/health >/dev/null 2>&1; then
        echo "✅ Tenant manager health endpoint is responding"
        break
    fi
    echo "⏳ Waiting for tenant manager to start (attempt $i/30)..."
    sleep 10
done

# Check what's listening on port 80
echo "📊 Checking what's listening on port 80..."
netstat -tlnp | grep :80 || echo "Nothing listening on port 80"

# Check what's listening on port 8188
echo "📊 Checking what's listening on port 8188..."
netstat -tlnp | grep :8188 || echo "Nothing listening on port 8188"

# Test the health endpoint
echo "🩺 Testing health endpoint..."
curl -s http://localhost/health | jq . || echo "Health endpoint not responding or invalid JSON"

# Test the metrics endpoint
echo "📊 Testing metrics endpoint..."
curl -s http://localhost/metrics | jq . || echo "Metrics endpoint not responding or invalid JSON"

# Show running Docker containers
echo "🐳 Running Docker containers:"
docker ps

# Show system status
echo "💻 System status:"
echo "Memory: $(free -h | grep Mem:)"
echo "Disk: $(df -h / | tail -1)"

# Signal completion
echo "TEST_SETUP_COMPLETE" > /tmp/test-ready.txt
echo "=== ComfyUI Test Instance Setup Completed at $(date) ==="
EOF

    # Launch the instance
    echo -e "${BLUE}🚀 Launching EC2 instance...${NC}"
    
    # Prepare launch parameters
    LAUNCH_PARAMS=(
        --image-id "$SELECTED_AMI"
        --instance-type "$INSTANCE_TYPE"
        --subnet-id "$SUBNET_ID"
        --security-group-ids "$SG_ID"
        --associate-public-ip-address
        --iam-instance-profile "Name=$IAM_ROLE_NAME"
        --user-data "file://user-data-test.sh"
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$instance_name},{Key=Purpose,Value=ComfyUI-Testing},{Key=Environment,Value=test},{Key=AutoTerminate,Value=manual}]"
        --region "$AWS_REGION"
    )
    
    # Add key pair if specified
    if [[ -n "$KEY_PAIR_NAME" ]]; then
        LAUNCH_PARAMS+=(--key-name "$KEY_PAIR_NAME")
    fi
    
    INSTANCE_ID=$(aws ec2 run-instances "${LAUNCH_PARAMS[@]}" --query 'Instances[0].InstanceId' --output text)
    
    echo -e "${GREEN}✅ Instance launched: $INSTANCE_ID${NC}"
    
    # Wait for instance to be running
    echo -e "${BLUE}⏳ Waiting for instance to be running...${NC}"
    aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
    
    # Get public IP
    PUBLIC_IP=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text \
        --region "$AWS_REGION")
    
    echo -e "${GREEN}✅ Instance is running!${NC}"
    echo -e "${BLUE}📋 Instance Details:${NC}"
    echo "   Instance ID: $INSTANCE_ID"
    echo "   Public IP: $PUBLIC_IP"
    echo "   VPC: $VPC_ID ($VPC_NAME)"
    echo "   Subnet: $SUBNET_ID ($SUBNET_NAME)"
    echo "   Security Group: $SG_ID"
    
    echo -e "${BLUE}🌐 Testing URLs (wait 2-3 minutes for setup):${NC}"
    echo "   Main test page: http://$PUBLIC_IP"
    echo "   ComfyUI test port: http://$PUBLIC_IP:8188"
    
    echo -e "${BLUE}🔍 Monitoring commands:${NC}"
    echo "   Check status: $0 status $instance_name"
    echo "   View logs: $0 logs $instance_name"
    echo "   Connect info: $0 connect $instance_name"
    echo "   Stop instance: $0 stop $instance_name"
    
    # Cleanup temp file
    rm -f user-data-test.sh
    
    echo -e "${GREEN}🎉 Instance launch complete!${NC}"
}

find_instance() {
    local instance_name="$1"
    
    if [[ -z "$instance_name" ]]; then
        echo -e "${RED}❌ Instance name required${NC}"
        return 1
    fi
    
    INSTANCE_ID=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$instance_name" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null)
    
    if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
        echo -e "${RED}❌ Instance '$instance_name' not found${NC}"
        return 1
    fi
    
    echo "$INSTANCE_ID"
}

show_status() {
    local instance_name="$1"
    local instance_id
    
    instance_id=$(find_instance "$instance_name")
    if [[ $? -ne 0 ]]; then return 1; fi
    
    echo -e "${BLUE}📊 Instance Status: $instance_name${NC}"
    
    # Get instance details
    aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].[InstanceId,State.Name,InstanceType,PublicIpAddress,PrivateIpAddress,LaunchTime]' \
        --output table \
        --region "$AWS_REGION"
    
    # Check if ports are accessible
    PUBLIC_IP=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text \
        --region "$AWS_REGION")
    
    if [[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "None" ]]; then
        echo -e "${BLUE}🌐 Connectivity Tests:${NC}"
        
        # Test HTTP port 80
        if timeout 5 curl -s "http://$PUBLIC_IP" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Port 80 (HTTP): Accessible${NC}"
        else
            echo -e "${RED}❌ Port 80 (HTTP): Not accessible${NC}"
        fi
        
        # Test ComfyUI port 8188
        if timeout 5 curl -s "http://$PUBLIC_IP:8188" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Port 8188 (ComfyUI): Accessible${NC}"
        else
            echo -e "${RED}❌ Port 8188 (ComfyUI): Not accessible${NC}"
        fi
        
        echo -e "${BLUE}🔗 URLs:${NC}"
        echo "   Test page: http://$PUBLIC_IP"
        echo "   ComfyUI test: http://$PUBLIC_IP:8188"
    fi
}

show_logs() {
    local instance_name="$1"
    local instance_id
    
    instance_id=$(find_instance "$instance_name")
    if [[ $? -ne 0 ]]; then return 1; fi
    
    echo -e "${BLUE}📋 Getting instance logs: $instance_name${NC}"
    
    # Check if SSM is available
    if aws ssm describe-instance-information \
        --filters "Key=InstanceIds,Values=$instance_id" \
        --region "$AWS_REGION" \
        --query 'InstanceInformationList[0].PingStatus' \
        --output text 2>/dev/null | grep -q "Online"; then
        
        echo -e "${GREEN}✅ SSM agent is online, fetching logs...${NC}"
        
        COMMAND_ID=$(aws ssm send-command \
            --instance-ids "$instance_id" \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=[
                "echo === User Data Log ===",
                "tail -50 /var/log/user-data.log 2>/dev/null || echo No user data log",
                "echo === System Status ===",
                "systemctl status comfyui-test.service --no-pager -l || echo ComfyUI test service not found",
                "echo === Network Status ===",
                "netstat -tlnp | grep -E \":80|:8188\" || echo No services on ports 80/8188",
                "echo === Recent System Logs ===",
                "journalctl --since \"10 minutes ago\" --no-pager -n 20 || echo No recent logs"
            ]' \
            --region "$AWS_REGION" \
            --query 'Command.CommandId' \
            --output text)
        
        sleep 5
        
        aws ssm get-command-invocation \
            --command-id "$COMMAND_ID" \
            --instance-id "$instance_id" \
            --region "$AWS_REGION" \
            --query 'StandardOutputContent' \
            --output text
    else
        echo -e "${RED}❌ SSM agent not available. Try using EC2 Instance Connect or SSH with your key pair.${NC}"
        echo -e "${BLUE}💡 Alternative: Check the EC2 console for instance logs${NC}"
    fi
}

show_connection_info() {
    local instance_name="$1"
    local instance_id
    
    instance_id=$(find_instance "$instance_name")
    if [[ $? -ne 0 ]]; then return 1; fi
    
    echo -e "${BLUE}🔗 Connection Information: $instance_name${NC}"
    
    # Get instance details
    INSTANCE_INFO=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].[PublicIpAddress,PrivateIpAddress,KeyName,SecurityGroups[0].GroupId]' \
        --output text \
        --region "$AWS_REGION")
    
    read -r PUBLIC_IP PRIVATE_IP KEY_NAME SG_ID <<< "$INSTANCE_INFO"
    
    echo "Instance ID: $instance_id"
    echo "Public IP: $PUBLIC_IP"
    echo "Private IP: $PRIVATE_IP"
    echo "Key Pair: ${KEY_NAME:-None}"
    echo "Security Group: $SG_ID"
    echo ""
    
    if [[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "None" ]]; then
        echo -e "${GREEN}🌐 Web Access:${NC}"
        echo "   Main test page: http://$PUBLIC_IP"
        echo "   ComfyUI test: http://$PUBLIC_IP:8188"
        echo ""
        
        if [[ -n "$KEY_NAME" && "$KEY_NAME" != "None" ]]; then
            echo -e "${GREEN}🔑 SSH Access:${NC}"
            echo "   ssh -i ~/.ssh/$KEY_NAME.pem ubuntu@$PUBLIC_IP"
            echo ""
        fi
        
        echo -e "${BLUE}🔍 Quick Tests:${NC}"
        echo "   curl http://$PUBLIC_IP"
        echo "   curl http://$PUBLIC_IP:8188"
        echo "   telnet $PUBLIC_IP 80"
        echo "   telnet $PUBLIC_IP 8188"
    else
        echo -e "${RED}❌ No public IP assigned${NC}"
    fi
    
    # Show security group rules
    echo -e "${BLUE}🔒 Security Group Rules:${NC}"
    aws ec2 describe-security-groups \
        --group-ids "$SG_ID" \
        --query 'SecurityGroups[0].IpPermissions[*].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp]' \
        --output table \
        --region "$AWS_REGION" || echo "Could not retrieve security group rules"
}

stop_instance() {
    local instance_name="$1"
    local instance_id
    
    instance_id=$(find_instance "$instance_name")
    if [[ $? -ne 0 ]]; then return 1; fi
    
    echo -e "${YELLOW}⚠️ Terminating instance: $instance_name ($instance_id)${NC}"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        aws ec2 terminate-instances --instance-ids "$instance_id" --region "$AWS_REGION"
        echo -e "${GREEN}✅ Instance termination initiated${NC}"
    else
        echo -e "${BLUE}ℹ️ Operation cancelled${NC}"
    fi
}

list_instances() {
    echo -e "${BLUE}📋 Test Instances:${NC}"
    
    aws ec2 describe-instances \
        --filters "Name=tag:Purpose,Values=ComfyUI-Testing" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value|[0],InstanceId,State.Name,PublicIpAddress,LaunchTime]' \
        --output table \
        --region "$AWS_REGION" || echo "No test instances found"
}

# Main script logic
case "${1:-}" in
    "launch")
        launch_instance "$2"
        ;;
    "stop")
        if [[ -z "$2" ]]; then
            echo -e "${RED}❌ Instance name required${NC}"
            print_usage
            exit 1
        fi
        stop_instance "$2"
        ;;
    "status")
        if [[ -z "$2" ]]; then
            echo -e "${RED}❌ Instance name required${NC}"
            print_usage
            exit 1
        fi
        show_status "$2"
        ;;
    "connect")
        if [[ -z "$2" ]]; then
            echo -e "${RED}❌ Instance name required${NC}"
            print_usage
            exit 1
        fi
        show_connection_info "$2"
        ;;
    "logs")
        if [[ -z "$2" ]]; then
            echo -e "${RED}❌ Instance name required${NC}"
            print_usage
            exit 1
        fi
        show_logs "$2"
        ;;
    "list")
        list_instances
        ;;
    *)
        print_usage
        exit 1
        ;;
esac
