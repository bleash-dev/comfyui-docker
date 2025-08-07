#!/bin/bash

# Create AMI Script
# Creates an AMI from a running instance and updates SSM parameters

set -e

# Source configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

print_usage() {
    echo "Usage: $0 [OPTIONS] <instance-name> [ami-description]"
    echo ""
    echo "Create an AMI from a running build instance"
    echo ""
    echo "Options:"
    echo "  --ami-name NAME         Custom AMI name (auto-generated if not specified)"
    echo "  --no-reboot            Create AMI without rebooting instance"
    echo "  --no-ssm-update        Don't update SSM parameters (for testing)"
    echo "  --terminate-instance    Terminate the source instance after AMI creation"
    echo "  --environment ENV       Target environment (default: $ENVIRONMENT)"
    echo "  --dry-run               Show what would be done without actually doing it"
    echo "  --help                  Show this help message"
    echo ""
    echo "Arguments:"
    echo "  instance-name           Name of the build instance to create AMI from"
    echo "  ami-description         Description for the new AMI (optional)"
    echo ""
    echo "Examples:"
    echo "  $0 my-build-instance"
    echo "  $0 my-build-instance 'Updated ComfyUI with bug fixes'"
    echo "  $0 --no-ssm-update test-build 'Experimental features'"
    echo "  $0 --terminate-instance my-build 'Production ready AMI'"
    echo "  $0 --environment staging my-build 'Staging release v2.1'"
}

# Default configuration
AMI_NAME=""
NO_REBOOT=false
NO_SSM_UPDATE=false
TERMINATE_INSTANCE=true
TARGET_ENVIRONMENT="$ENVIRONMENT"
DRY_RUN=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --ami-name)
            AMI_NAME="$2"
            shift 2
            ;;
        --no-reboot)
            NO_REBOOT=true
            shift
            ;;
        --no-ssm-update)
            NO_SSM_UPDATE=true
            shift
            ;;
        --terminate-instance)
            TERMINATE_INSTANCE=true
            shift
            ;;
        --environment)
            TARGET_ENVIRONMENT="$2"
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
            elif [[ -z "${AMI_DESCRIPTION:-}" ]]; then
                AMI_DESCRIPTION="$1"
            else
                echo "Too many arguments"
                print_usage
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [[ -z "${INSTANCE_NAME:-}" ]]; then
    log_error "Instance name is required"
    print_usage
    exit 1
fi

# Validate AWS CLI
validate_aws_cli

log_header "Creating AMI from instance: $INSTANCE_NAME"

# Find the instance
log_step "Finding build instance..."
INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null)

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
    log_error "Instance '$INSTANCE_NAME' not found or not in a valid state"
    exit 1
fi

# Get instance details
INSTANCE_INFO=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].[State.Name,InstanceType,Tags[?Key==`Purpose`].Value|[0]]' \
    --output text \
    --region "$AWS_REGION")

read -r INSTANCE_STATE INSTANCE_TYPE INSTANCE_PURPOSE <<< "$INSTANCE_INFO"

log_success "Found instance: $INSTANCE_ID"
log_info "Instance Details:"
echo "   State: $INSTANCE_STATE"
echo "   Type: $INSTANCE_TYPE"
echo "   Purpose: ${INSTANCE_PURPOSE:-Unknown}"

# Validate instance state and purpose
if [[ "$INSTANCE_STATE" != "running" && "$INSTANCE_STATE" != "stopped" ]]; then
    log_error "Instance must be in 'running' or 'stopped' state (current: $INSTANCE_STATE)"
    exit 1
fi

if [[ "$INSTANCE_PURPOSE" != "AMI-Building" ]]; then
    log_warning "Instance doesn't have 'AMI-Building' purpose tag. Continue anyway? (y/N)"
    read -r -n 1 REPLY
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Operation cancelled"
        exit 0
    fi
fi

# Generate AMI name if not provided
if [[ -z "$AMI_NAME" ]]; then
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    AMI_NAME="${AMI_NAME_PREFIX}-${TARGET_ENVIRONMENT}-${TIMESTAMP}"
fi

# Set default description if not provided
if [[ -z "${AMI_DESCRIPTION:-}" ]]; then
    AMI_DESCRIPTION="ComfyUI AMI for $TARGET_ENVIRONMENT environment - Created $(date -u +%Y-%m-%d\ %H:%M:%S\ UTC)"
fi

log_info "AMI Configuration:"
echo "   Name: $AMI_NAME"
echo "   Description: $AMI_DESCRIPTION"
echo "   Environment: $TARGET_ENVIRONMENT"
echo "   No Reboot: $NO_REBOOT"
echo "   Update SSM: $([[ "$NO_SSM_UPDATE" == "true" ]] && echo "No" || echo "Yes")"
echo "   Terminate Instance: $([[ "$TERMINATE_INSTANCE" == "true" ]] && echo "Yes" || echo "No")"

# Stop instance if it's running and we need to reboot
if [[ "$INSTANCE_STATE" == "running" && "$NO_REBOOT" == "false" ]]; then
    log_step "Stopping instance for consistent AMI creation..."
    aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" >/dev/null
    log_info "Waiting for instance to stop..."
    wait_for_instance_state "$INSTANCE_ID" "stopped"
    log_success "Instance stopped"
fi

if [[ "$DRY_RUN" == "true" ]]; then
    log_warning "DRY RUN: Would create AMI with the following configuration:"
    echo "   aws ec2 create-image --instance-id $INSTANCE_ID --name '$AMI_NAME' --description '$AMI_DESCRIPTION' --no-reboot=$NO_REBOOT"
    if [[ "$NO_SSM_UPDATE" == "false" ]]; then
        echo "   Would update SSM parameter: /comfyui/ami/$TARGET_ENVIRONMENT/latest"
    fi
    if [[ "$TERMINATE_INSTANCE" == "true" ]]; then
        echo "   Would terminate instance: $INSTANCE_ID ($INSTANCE_NAME)"
    fi
    exit 0
fi

# Create the AMI
log_step "Creating AMI..."
CREATE_AMI_PARAMS=(
    --instance-id "$INSTANCE_ID"
    --name "$AMI_NAME"
    --description "$AMI_DESCRIPTION"
    --region "$AWS_REGION"
)

if [[ "$NO_REBOOT" == "true" ]]; then
    CREATE_AMI_PARAMS+=(--no-reboot)
fi

AMI_ID=$(aws ec2 create-image "${CREATE_AMI_PARAMS[@]}" --query 'ImageId' --output text)

if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
    log_error "Failed to create AMI"
    exit 1
fi

log_success "AMI creation initiated: $AMI_ID"

# Wait for AMI to be available
log_step "Waiting for AMI to be available..."
log_info "This may take several minutes..."

# Monitor AMI creation progress
while true; do
    AMI_STATE=$(aws ec2 describe-images \
        --image-ids "$AMI_ID" \
        --query 'Images[0].State' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "")
    
    case "$AMI_STATE" in
        "available")
            log_success "AMI is now available!"
            break
            ;;
        "pending")
            log_info "AMI creation in progress..."
            sleep 30
            ;;
        "failed")
            log_error "AMI creation failed"
            
            # Get failure reason
            FAILURE_REASON=$(aws ec2 describe-images \
                --image-ids "$AMI_ID" \
                --query 'Images[0].StateReason.Message' \
                --output text \
                --region "$AWS_REGION" 2>/dev/null || echo "Unknown")
            
            log_error "Failure reason: $FAILURE_REASON"
            exit 1
            ;;
        "")
            log_error "Failed to query AMI state"
            exit 1
            ;;
        *)
            log_warning "Unexpected AMI state: $AMI_STATE"
            sleep 30
            ;;
    esac
done

# Get AMI details
AMI_DETAILS=$(aws ec2 describe-images \
    --image-ids "$AMI_ID" \
    --query 'Images[0].[CreationDate,Architecture,VirtualizationType,RootDeviceType]' \
    --output text \
    --region "$AWS_REGION")

read -r CREATION_DATE ARCHITECTURE VIRT_TYPE ROOT_DEVICE <<< "$AMI_DETAILS"

log_success "AMI Details:"
echo "   AMI ID: $AMI_ID"
echo "   Name: $AMI_NAME"
echo "   Created: $CREATION_DATE"
echo "   Architecture: $ARCHITECTURE"
echo "   Virtualization: $VIRT_TYPE"
echo "   Root Device: $ROOT_DEVICE"

# Update SSM parameters if requested
if [[ "$NO_SSM_UPDATE" == "false" ]]; then
    log_step "Updating SSM parameters..."
    
    # Get current latest AMI for backup
    CURRENT_LATEST=$(aws ssm get-parameter \
        --name "/comfyui/ami/$TARGET_ENVIRONMENT/latest" \
        --query 'Parameter.Value' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "")
    
    # Update previous AMI parameter if there was a previous latest
    if [[ -n "$CURRENT_LATEST" && "$CURRENT_LATEST" != "None" ]]; then
        aws ssm put-parameter \
            --name "/comfyui/ami/$TARGET_ENVIRONMENT/previous" \
            --value "$CURRENT_LATEST" \
            --type "String" \
            --overwrite \
            --region "$AWS_REGION" >/dev/null
        
        log_info "Previous AMI parameter updated: $CURRENT_LATEST"
    fi
    
    # Update latest AMI parameter
    aws ssm put-parameter \
        --name "/comfyui/ami/$TARGET_ENVIRONMENT/latest" \
        --value "$AMI_ID" \
        --type "String" \
        --overwrite \
        --region "$AWS_REGION" >/dev/null
    
    # Create build info parameter
    BUILD_INFO=$(jq -n \
        --arg ami_id "$AMI_ID" \
        --arg ami_name "$AMI_NAME" \
        --arg description "$AMI_DESCRIPTION" \
        --arg instance_id "$INSTANCE_ID" \
        --arg instance_name "$INSTANCE_NAME" \
        --arg created_by "$(whoami)" \
        --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg environment "$TARGET_ENVIRONMENT" \
        '{
            ami_id: $ami_id,
            ami_name: $ami_name,
            description: $description,
            source_instance_id: $instance_id,
            source_instance_name: $instance_name,
            created_by: $created_by,
            created_at: $created_at,
            environment: $environment
        }')
    
    aws ssm put-parameter \
        --name "/comfyui/ami/$TARGET_ENVIRONMENT/build-info" \
        --value "$BUILD_INFO" \
        --type "String" \
        --overwrite \
        --region "$AWS_REGION" >/dev/null
    
    log_success "SSM parameters updated successfully"
    log_info "SSM Parameters:"
    echo "   /comfyui/ami/$TARGET_ENVIRONMENT/latest -> $AMI_ID"
    if [[ -n "$CURRENT_LATEST" && "$CURRENT_LATEST" != "None" ]]; then
        echo "   /comfyui/ami/$TARGET_ENVIRONMENT/previous -> $CURRENT_LATEST"
    fi
fi

# Tag the AMI
log_step "Tagging AMI..."
aws ec2 create-tags \
    --resources "$AMI_ID" \
    --tags \
        "Key=Name,Value=$AMI_NAME" \
        "Key=Environment,Value=$TARGET_ENVIRONMENT" \
        "Key=Purpose,Value=ComfyUI-Deployment" \
        "Key=SourceInstance,Value=$INSTANCE_ID" \
        "Key=SourceInstanceName,Value=$INSTANCE_NAME" \
        "Key=CreatedBy,Value=$(whoami)" \
        "Key=CreatedAt,Value=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "Key=BuildType,Value=manual" \
    --region "$AWS_REGION" >/dev/null

log_success "AMI tagged successfully"

# Terminate instance if requested
if [[ "$TERMINATE_INSTANCE" == "true" ]]; then
    log_step "Terminating source instance..."
    log_info "Terminating instance: $INSTANCE_ID ($INSTANCE_NAME)"
    
    # Confirm termination if instance was running (to avoid accidents)
    if [[ "$INSTANCE_STATE" == "running" ]]; then
        log_warning "The source instance was originally running. Terminating it now..."
    fi
    
    aws ec2 terminate-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" >/dev/null
    
    log_success "Instance termination initiated"
    log_info "Instance $INSTANCE_ID will be terminated shortly"
    
    # Update the next steps message
    TERMINATION_NOTE="   ✅ Source instance ($INSTANCE_NAME) has been terminated"
else
    TERMINATION_NOTE="   3. Terminate build instance: $SCRIPT_DIR/manage_instance.sh terminate $INSTANCE_NAME"
fi

log_header "AMI Creation Complete!"
echo ""
log_info "Next Steps:"
echo "   1. Test the AMI: $SCRIPT_DIR/validate_ami.sh $AMI_ID"
echo "   2. Clean up old AMIs: $SCRIPT_DIR/cleanup_old_amis.sh"
echo "$TERMINATION_NOTE"
echo ""
log_info "Deployment Information:"
echo "   New AMI ID: $AMI_ID"
echo "   Environment: $TARGET_ENVIRONMENT"
if [[ "$NO_SSM_UPDATE" == "false" ]]; then
    echo "   SSM Parameter: /comfyui/ami/$TARGET_ENVIRONMENT/latest"
    echo "   Ready for deployment in $TARGET_ENVIRONMENT environment"
else
    echo "   SSM parameters not updated - manual deployment required"
fi
