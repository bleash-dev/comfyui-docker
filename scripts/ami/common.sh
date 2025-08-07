#!/bin/bash

# Common configuration for AMI management scripts
# This file contains shared settings used across all AMI scripts

# AWS Configuration
AWS_REGION="us-east-1"
BUILD_INSTANCE_TYPE="c5d.large"  # Same as GitHub Actions - good for building AMIs with local NVMe SSD
IAM_ROLE_NAME="viral-comm-api-shared-instance-profile-dev"  # Instance profile for AMI operations

# Network Configuration (same as test_instance.sh for consistency)
PREFERRED_SUBNET_ID="subnet-028352ae3329680c0"  # Specific subnet for operations
PREFERRED_SG_ID="sg-04fc7bbc5e0bb8362"          # Specific security group for operations

# Default settings
DEFAULT_VOLUME_SIZE=50  # GB
DEFAULT_KEY_PAIR_NAME=""  # Optional: Add your key pair name here for SSH access

# AMI Configuration
AMI_NAME_PREFIX="comfyui-multitenant"
ENVIRONMENT="${DEPLOYMENT_TARGET:-dev}"  # Default to dev environment

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_step() {
    echo -e "${CYAN}🔧 $1${NC}"
}

log_header() {
    echo -e "${BOLD}${BLUE}$1${NC}"
}

# Validation functions
validate_aws_cli() {
    if ! command -v aws >/dev/null 2>&1; then
        log_error "AWS CLI not found. Please install it first."
        return 1
    fi
    
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log_error "AWS CLI not configured or no valid credentials."
        return 1
    fi
    
    log_success "AWS CLI is configured and working"
    return 0
}

validate_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq not found. Please install it first."
        return 1
    fi
    return 0
}

# Network discovery functions (same logic as test_instance.sh)
get_vpc_and_subnet() {
    log_step "Finding VPC and subnet..."
    
    # First try to use the preferred subnet if specified
    if [[ -n "$PREFERRED_SUBNET_ID" ]]; then
        log_info "Checking preferred subnet: $PREFERRED_SUBNET_ID"
        
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
            
            log_success "Using preferred subnet: $SUBNET_ID (Name: $SUBNET_NAME)"
            log_success "VPC: $VPC_ID (Name: $VPC_NAME)"
            log_info "Subnet details: AZ=$AZ, Public IP on launch=$PUBLIC_IP_ON_LAUNCH"
            return 0
        else
            log_warning "Preferred subnet not found or not accessible, falling back to auto-detection..."
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
        log_warning "Preferred VPC not found, trying pattern match..."
        VPC_ID=$(aws ec2 describe-vpcs \
            --filters "Name=tag:Name,Values=*proxy-vpc-dev" \
            --query 'Vpcs[0].VpcId' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "")
    fi
    
    # Fallback: Default VPC
    if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
        log_warning "No proxy VPC found, using default VPC..."
        VPC_ID=$(aws ec2 describe-vpcs \
            --filters "Name=is-default,Values=true" \
            --query 'Vpcs[0].VpcId' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "")
    fi
    
    # Final fallback: Any VPC
    if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
        log_warning "No default VPC found, using any available VPC..."
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
    
    log_success "Selected VPC: $VPC_ID (Name: $VPC_NAME)"
    
    # Find subnet
    log_step "Finding subnet in VPC..."
    
    # Try preferred subnet pattern
    SUBNET_ID=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=*vpc-proxy-subnetSubnet1*" \
        --query 'Subnets[0].SubnetId' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "")
    
    # Fallback: Any public subnet
    if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
        log_warning "Preferred subnet not found, looking for public subnet..."
        SUBNET_ID=$(aws ec2 describe-subnets \
            --filters "Name=vpc-id,Values=${VPC_ID}" "Name=map-public-ip-on-launch,Values=true" \
            --query 'Subnets[0].SubnetId' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "")
    fi
    
    # Final fallback: Any subnet
    if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
        log_warning "No public subnet found, using any subnet..."
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
    
    log_success "Selected Subnet: $SUBNET_ID (Name: $SUBNET_NAME, Public: $SUBNET_PUBLIC)"
    
    # Check if we got preferred resources
    if [[ "$VPC_NAME" == *"viral-comm-api-proxy-vpc-dev"* ]]; then
        log_success "🎉 Using preferred VPC!"
    else
        log_warning "Using fallback VPC"
    fi
    
    if [[ "$SUBNET_NAME" == *"vpc-proxy-subnetSubnet1"* ]]; then
        log_success "🎉 Using preferred subnet!"
    else
        log_warning "Using fallback subnet"
    fi
}

get_security_group() {
    log_step "Finding security group..."
    
    # First try to use the preferred security group if specified
    if [[ -n "$PREFERRED_SG_ID" ]]; then
        log_info "Checking preferred security group: $PREFERRED_SG_ID"
        
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
                log_success "Using preferred security group: $SG_ID (Name: $SG_NAME)"
                log_success "Security group VPC matches subnet VPC: $VPC_ID"
                return 0
            else
                log_warning "Preferred security group is in different VPC ($SG_VPC_ID vs $VPC_ID), falling back..."
                SG_ID=""
            fi
        else
            log_warning "Preferred security group not found or not accessible, falling back to auto-detection..."
            SG_ID=""
        fi
    fi
    
    # Fall back to auto-detection if preferred SG not usable
    if [[ -z "$SG_ID" ]]; then
        log_step "Auto-detecting security group..."
        
        # Try to find CDK-managed security group
        SG_ID=$(aws ec2 describe-security-groups \
            --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:aws:cloudformation:logical-id,Values=*SecurityGroup*" \
            --query 'SecurityGroups[0].GroupId' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "")
        
        # Fallback: Default security group
        if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
            log_warning "No CDK security group found, using default..."
            SG_ID=$(aws ec2 describe-security-groups \
                --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=default" \
                --query 'SecurityGroups[0].GroupId' \
                --output text \
                --region "$AWS_REGION")
        fi
        
        log_success "Auto-detected Security Group: $SG_ID"
    fi
    
    # Show security group rules
    log_info "Security Group Rules:"
    aws ec2 describe-security-groups \
        --group-ids "$SG_ID" \
        --query 'SecurityGroups[0].IpPermissions[*].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp]' \
        --output table \
        --region "$AWS_REGION" || echo "Could not retrieve rules"
}

# AMI discovery functions
get_base_ami() {
    local preferred_ami="$1"
    
    log_step "Finding base AMI..."
    
    # If a specific AMI was provided, use it
    if [[ -n "$preferred_ami" ]]; then
        log_info "Using specified base AMI: $preferred_ami"
        
        # Verify the AMI exists and is available
        AMI_STATE=$(aws ec2 describe-images \
            --image-ids "$preferred_ami" \
            --query 'Images[0].State' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "")
        
        if [[ "$AMI_STATE" == "available" ]]; then
            log_success "Specified AMI is available and ready"
            SELECTED_AMI="$preferred_ami"
            AMI_TYPE="specified"
            return 0
        else
            log_warning "Specified AMI not available (state: $AMI_STATE), falling back..."
        fi
    fi
    
    # First try to get the latest ComfyUI AMI from SSM Parameter Store
    log_info "Checking SSM Parameter Store for ComfyUI AMI..."
    COMFYUI_AMI=$(aws ssm get-parameter \
        --name "/comfyui/ami/$ENVIRONMENT/latest" \
        --query 'Parameter.Value' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "")
    
    if [[ -n "$COMFYUI_AMI" && "$COMFYUI_AMI" != "None" ]]; then
        log_success "Found ComfyUI AMI from SSM: $COMFYUI_AMI"
        
        # Verify the AMI exists and is available
        AMI_STATE=$(aws ec2 describe-images \
            --image-ids "$COMFYUI_AMI" \
            --query 'Images[0].State' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "")
        
        if [[ "$AMI_STATE" == "available" ]]; then
            log_success "ComfyUI AMI is available and ready"
            SELECTED_AMI="$COMFYUI_AMI"
            AMI_TYPE="existing-comfyui"
            return 0
        else
            log_warning "ComfyUI AMI not available (state: $AMI_STATE), falling back..."
        fi
    else
        log_warning "No ComfyUI AMI found in SSM Parameter Store, searching manually..."
    fi
    
    # Fallback: Search for ComfyUI AMI by name pattern
    log_step "Searching for ComfyUI AMI by name pattern..."
    COMFYUI_AMI=$(aws ec2 describe-images \
        --owners self \
        --filters "Name=name,Values=${AMI_NAME_PREFIX}-*" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "")
    
    if [[ -n "$COMFYUI_AMI" && "$COMFYUI_AMI" != "None" ]]; then
        log_success "Found ComfyUI AMI by search: $COMFYUI_AMI"
        SELECTED_AMI="$COMFYUI_AMI"
        AMI_TYPE="existing-comfyui"
        return 0
    fi
    
    # Final fallback: Use Ubuntu AMI
    log_warning "No ComfyUI AMI found, using Ubuntu AMI for fresh build..."
    UBUNTU_AMI=ami-09ddf6b7d718bc247 # ML AMAZON AMI
    
    SELECTED_AMI="$UBUNTU_AMI"
    AMI_TYPE="ubuntu"
    log_success "Selected Ubuntu AMI: $SELECTED_AMI"
}

# Instance management functions
wait_for_instance_state() {
    local instance_id="$1"
    local desired_state="$2"
    local timeout_minutes="${3:-15}"
    
    log_step "Waiting for instance $instance_id to reach state: $desired_state"
    
    case "$desired_state" in
        "running")
            aws ec2 wait instance-running --instance-ids "$instance_id" --region "$AWS_REGION"
            ;;
        "stopped")
            aws ec2 wait instance-stopped --instance-ids "$instance_id" --region "$AWS_REGION"
            ;;
        "terminated")
            aws ec2 wait instance-terminated --instance-ids "$instance_id" --region "$AWS_REGION"
            ;;
        *)
            log_error "Unknown state: $desired_state"
            return 1
            ;;
    esac
    
    log_success "Instance reached state: $desired_state"
}

get_instance_ip() {
    local instance_id="$1"
    
    aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text \
        --region "$AWS_REGION"
}

# Export variables that will be used by other scripts
export AWS_REGION
export BUILD_INSTANCE_TYPE
export IAM_ROLE_NAME
export PREFERRED_SUBNET_ID
export PREFERRED_SG_ID
export DEFAULT_VOLUME_SIZE
export DEFAULT_KEY_PAIR_NAME
export AMI_NAME_PREFIX
export ENVIRONMENT
