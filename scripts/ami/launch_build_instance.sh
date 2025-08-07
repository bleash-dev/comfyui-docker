#!/bin/bash

# Launch Build Instance Script
# Creates an EC2 instance for manual AMI building

set -e

# Source configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

print_usage() {
    echo "Usage: $0 [OPTIONS] [instance-name]"
    echo ""
    echo "Launch an EC2 instance for AMI building"
    echo ""
    echo "Options:"
    echo "  --instance-type TYPE    Instance type (default: $BUILD_INSTANCE_TYPE)"
    echo "  --key-pair NAME         EC2 key pair name"
    echo "  --subnet-id ID          Subnet ID to launch in"
    echo "  --security-group ID     Security group ID"
    echo "  --config FILE           Load configuration from file"
    echo "  --base-ami ID           Base AMI to start from (auto-detected if not specified)"
    echo "  --volume-size GB        Root volume size in GB (default: 50)"
    echo "  --dry-run               Show what would be launched without actually doing it"
    echo "  --help                  Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 my-build-instance"
    echo "  $0 --instance-type g4dn.2xlarge --volume-size 100 large-build"
    echo "  $0 --config configs/staging.env staging-build"
    echo "  $0 --base-ami ami-1234567890abcdef0 custom-build"
}

# Default configuration
INSTANCE_TYPE="c5d.large"
KEY_PAIR="vf-keys"
BASE_AMI=""
VOLUME_SIZE="20"
DRY_RUN=false
CONFIG_FILE=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --instance-type)
            INSTANCE_TYPE="$2"
            shift 2
            ;;
        --key-pair)
            KEY_PAIR="$2"
            shift 2
            ;;
        --subnet-id)
            SUBNET_ID="$2"
            shift 2
            ;;
        --security-group)
            SECURITY_GROUP="$2"
            shift 2
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --base-ami)
            BASE_AMI="$2"
            shift 2
            ;;
        --volume-size)
            VOLUME_SIZE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            print_usage
            exit 0
            ;;
        --*)
            echo "Unknown option: $1"
            print_usage
            exit 1
            ;;
        *)
            if [[ -z "${INSTANCE_NAME:-}" ]]; then
                INSTANCE_NAME="$1"
            else
                echo "Multiple instance names specified"
                print_usage
                exit 1
            fi
            shift
            ;;
    esac
done

# Load additional config if specified
if [[ -n "$CONFIG_FILE" ]]; then
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "Loading configuration from $CONFIG_FILE"
        source "$CONFIG_FILE"
    else
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
fi

# Set default instance name if not provided
if [[ -z "${INSTANCE_NAME:-}" ]]; then
    INSTANCE_NAME="comfyui-build-$(date +%Y%m%d-%H%M%S)"
fi

log_info "Launching build instance: $INSTANCE_NAME"

# Auto-detect base AMI if not specified
if [[ -z "$BASE_AMI" ]]; then
    log_info "Auto-detecting base AMI..."
    
    # Try to get the latest ComfyUI AMI
    BASE_AMI=$(aws ssm get-parameter \
        --name "/comfyui/ami/${ENVIRONMENT}/latest" \
        --query 'Parameter.Value' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "")
    
    # Fallback to Ubuntu if no ComfyUI AMI exists
    if [[ -z "$BASE_AMI" || "$BASE_AMI" == "None" ]]; then
        log_warning "No existing ComfyUI AMI found, using Ubuntu 22.04 LTS"
        BASE_AMI=ami-09ddf6b7d718bc247 # ML AMAZON AMI
    else
        log_success "Using existing ComfyUI AMI: $BASE_AMI"
    fi
fi


# Validate the base AMI exists
log_info "Validating base AMI..."
AMI_INFO=$(aws ec2 describe-images \
    --image-ids "$BASE_AMI" \
    --query 'Images[0].[ImageId,State,Name,Description]' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")

if [[ -z "$AMI_INFO" ]]; then
    log_error "Base AMI not found: $BASE_AMI"
    BASE_AMI="ami-09ddf6b7d718bc247" # ML AMAZON AMI
    AMI_INFO=$(aws ec2 describe-images \
    --image-ids "$BASE_AMI" \
    --query 'Images[0].[ImageId,State,Name,Description]' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")
fi

read -r AMI_ID AMI_STATE AMI_NAME AMI_DESC <<< "$AMI_INFO"
if [[  "$AMI_STATE" != "available" ]]; then
    log_error "Base AMI is not available (state: $AMI_STATE)"
    exit 1
fi

log_info "Base AMI Details:"
echo "   ID: $AMI_ID"
echo "   Name: $AMI_NAME"
echo "   Description: $AMI_DESC"



# Prepare launch parameters
LAUNCH_PARAMS=(
    --image-id "$BASE_AMI"
    --instance-type "$INSTANCE_TYPE"
    --subnet-id "$PREFERRED_SUBNET_ID"
    --security-group-ids "$PREFERRED_SG_ID"
    --associate-public-ip-address
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=Purpose,Value=AMI-Building},{Key=Environment,Value=${ENVIRONMENT}},{Key=BuildType,Value=manual},{Key=CreatedBy,Value=$(whoami)},{Key=CreatedAt,Value=$(date -u +%Y-%m-%dT%H:%M:%SZ)}]"
    --region "$AWS_REGION"
)

# Add IAM instance profile if specified
if [[ -n "${IAM_ROLE_NAME:-}" ]]; then
    LAUNCH_PARAMS+=(--iam-instance-profile "Name=$IAM_ROLE_NAME")
fi

# Add key pair if specified
if [[ -n "$KEY_PAIR" ]]; then
    LAUNCH_PARAMS+=(--key-name "$KEY_PAIR")
    SSH_INFO="SSH: ssh -i ~/.ssh/${KEY_PAIR}.pem ubuntu@<instance-ip>"
else
    SSH_INFO="SSH: Use EC2 Instance Connect (no key pair specified)"
fi

# Show what will be launched
log_info "Launch Configuration:"
echo "   Instance Name: $INSTANCE_NAME"
echo "   Instance Type: $INSTANCE_TYPE"
echo "   Base AMI: $BASE_AMI"
echo "   Subnet: $SUBNET_ID"
echo "   Security Group: $SECURITY_GROUP"
echo "   Volume Size: ${VOLUME_SIZE}GB"
echo "   Key Pair: ${KEY_PAIR:-None (use Instance Connect)}"
echo "   IAM Role: ${IAM_ROLE_NAME:-None}"

if [[ "$DRY_RUN" == "true" ]]; then
    log_warning "DRY RUN: Would execute the following command:"
    echo "aws ec2 run-instances ${LAUNCH_PARAMS[*]}"
    exit 0
fi

# Launch the instance
log_info "Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances "${LAUNCH_PARAMS[@]}" --query 'Instances[0].InstanceId' --output text)

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
    log_error "Failed to launch instance"
    exit 1
fi

log_success "Instance launched: $INSTANCE_ID"

# Wait for instance to be running
log_info "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"

# Get instance details
INSTANCE_INFO=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].[PublicIpAddress,PrivateIpAddress,InstanceType,Placement.AvailabilityZone]' \
    --output text \
    --region "$AWS_REGION")

read -r PUBLIC_IP PRIVATE_IP ACTUAL_TYPE AZ <<< "$INSTANCE_INFO"

log_success "Instance is running!"
log_info "Instance Details:"
echo "   Instance ID: $INSTANCE_ID"
echo "   Name: $INSTANCE_NAME"
echo "   Type: $ACTUAL_TYPE"
echo "   Public IP: $PUBLIC_IP"
echo "   Private IP: $PRIVATE_IP"
echo "   Availability Zone: $AZ"
echo ""
log_info "Connection Information:"
echo "   $SSH_INFO"
if [[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "None" ]]; then
    if [[ -n "$KEY_PAIR" ]]; then
        echo "   Quick connect: ssh -i ~/.ssh/${KEY_PAIR}.pem ubuntu@${PUBLIC_IP}"
    fi
fi
echo ""
log_info "Next Steps:"
echo "   1. SSH into the instance and make your changes"
echo "   2. Test your changes thoroughly"
echo "   3. Run: $SCRIPT_DIR/create_ami.sh $INSTANCE_NAME"
echo "   4. Run: $SCRIPT_DIR/manage_instance.sh terminate $INSTANCE_NAME"
echo ""
log_info "Management Commands:"
echo "   Status: $SCRIPT_DIR/manage_instance.sh status $INSTANCE_NAME"
echo "   Stop: $SCRIPT_DIR/manage_instance.sh stop $INSTANCE_NAME"
echo "   Start: $SCRIPT_DIR/manage_instance.sh start $INSTANCE_NAME"
echo "   Terminate: $SCRIPT_DIR/manage_instance.sh terminate $INSTANCE_NAME"

# Save instance info for other scripts
echo "INSTANCE_ID=$INSTANCE_ID" > "/tmp/ami-build-${INSTANCE_NAME}.env"
echo "INSTANCE_NAME=$INSTANCE_NAME" >> "/tmp/ami-build-${INSTANCE_NAME}.env"
echo "PUBLIC_IP=$PUBLIC_IP" >> "/tmp/ami-build-${INSTANCE_NAME}.env"
echo "PRIVATE_IP=$PRIVATE_IP" >> "/tmp/ami-build-${INSTANCE_NAME}.env"
echo "BASE_AMI=$BASE_AMI" >> "/tmp/ami-build-${INSTANCE_NAME}.env"

# Cleanup temp files
rm -f "/tmp/user-data-build-${INSTANCE_NAME}.sh"

log_success "Build instance launch complete!"
