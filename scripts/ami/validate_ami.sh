#!/bin/bash

# Validate AMI Script
# Test an AMI by launching a test instance (similar to test_instance.sh)

set -e

# Source configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

print_usage() {
    echo "Usage: $0 [OPTIONS] [ami-id]"
    echo ""
    echo "Validate an AMI by launching a test instance"
    echo ""
    echo "Options:"
    echo "  --instance-type TYPE    Instance type for testing (default: g4dn.xlarge)"
    echo "  --instance-name NAME    Name for test instance (auto-generated if not specified)"
    echo "  --keep-instance         Don't terminate test instance after validation"
    echo "  --timeout MINUTES       Validation timeout in minutes (default: 10)"
    echo "  --environment ENV       Environment to validate for (default: $ENVIRONMENT)"
    echo "  --dry-run               Show what would be done without actually doing it"
    echo "  --help                  Show this help message"
    echo ""
    echo "Arguments:"
    echo "  ami-id                  AMI ID to validate (uses latest from SSM if not specified)"
    echo ""
    echo "Examples:"
    echo "  $0                                    # Validate latest AMI from SSM"
    echo "  $0 ami-1234567890abcdef0              # Validate specific AMI"
    echo "  $0 --keep-instance                    # Keep test instance running"
    echo "  $0 --instance-type g4dn.2xlarge      # Use larger instance for testing"
}

# Default configuration
TEST_INSTANCE_TYPE="g4dn.xlarge"  # Same as test_instance.sh - GPU for ComfyUI testing
TEST_INSTANCE_NAME=""
KEEP_INSTANCE=false
TIMEOUT_MINUTES=10
TARGET_ENVIRONMENT="$ENVIRONMENT"
DRY_RUN=false
AMI_ID=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --instance-type)
            TEST_INSTANCE_TYPE="$2"
            shift 2
            ;;
        --instance-name)
            TEST_INSTANCE_NAME="$2"
            shift 2
            ;;
        --keep-instance)
            KEEP_INSTANCE=true
            shift
            ;;
        --timeout)
            TIMEOUT_MINUTES="$2"
            shift 2
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
            if [[ -z "$AMI_ID" ]]; then
                AMI_ID="$1"
            else
                echo "Too many arguments"
                print_usage
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate timeout
if ! [[ "$TIMEOUT_MINUTES" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT_MINUTES" -lt 1 ]]; then
    log_error "Timeout must be a positive integer"
    exit 1
fi

# Validate AWS CLI
validate_aws_cli

log_header "Validating ComfyUI AMI"

# Get AMI to validate
if [[ -z "$AMI_ID" ]]; then
    log_step "Getting latest AMI from SSM Parameter Store..."
    AMI_ID=$(aws ssm get-parameter \
        --name "/comfyui/ami/$TARGET_ENVIRONMENT/latest" \
        --query 'Parameter.Value' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "")
    
    if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
        log_error "No AMI found in SSM parameter: /comfyui/ami/$TARGET_ENVIRONMENT/latest"
        exit 1
    fi
    
    log_success "Using latest AMI from SSM: $AMI_ID"
else
    log_info "Using specified AMI: $AMI_ID"
fi

# Validate AMI exists and is available
log_step "Validating AMI..."
AMI_INFO=$(aws ec2 describe-images \
    --image-ids "$AMI_ID" \
    --query 'Images[0].[ImageId,State,Name,Description,CreationDate,Architecture]' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")

if [[ -z "$AMI_INFO" ]]; then
    log_error "AMI not found: $AMI_ID"
    exit 1
fi

read -r ami_id ami_state ami_name ami_desc creation_date architecture <<< "$AMI_INFO"

if [[ "$ami_state" != "available" ]]; then
    log_error "AMI is not available (state: $ami_state)"
    exit 1
fi

log_success "AMI Details:"
echo "   ID: $ami_id"
echo "   Name: $ami_name"
echo "   State: $ami_state"
echo "   Created: $creation_date"
echo "   Architecture: $architecture"

# Generate test instance name if not provided
if [[ -z "$TEST_INSTANCE_NAME" ]]; then
    TEST_INSTANCE_NAME="ami-validation-$(date +%Y%m%d-%H%M%S)"
fi

# Get network configuration (same as test_instance.sh)
log_step "Configuring network (same as test instances)..."
get_vpc_and_subnet
get_security_group

log_info "Validation Configuration:"
echo "   AMI ID: $AMI_ID"
echo "   Instance Type: $TEST_INSTANCE_TYPE"
echo "   Instance Name: $TEST_INSTANCE_NAME"
echo "   Subnet: $SUBNET_ID"
echo "   Security Group: $SG_ID"
echo "   Timeout: ${TIMEOUT_MINUTES} minutes"
echo "   Keep Instance: $KEEP_INSTANCE"

if [[ "$DRY_RUN" == "true" ]]; then
    log_warning "DRY RUN: Would launch validation instance with:"
    echo "   aws ec2 run-instances --image-id $AMI_ID --instance-type $TEST_INSTANCE_TYPE ..."
    exit 0
fi

# Create user data script for validation
log_step "Creating validation user data..."
cat > "/tmp/user-data-validation-${TEST_INSTANCE_NAME}.sh" << 'EOF'
#!/bin/bash
set -e

# Log everything
exec > >(tee /var/log/user-data.log) 2>&1
echo "=== AMI Validation Started at $(date) ==="

# Signal that validation is starting
echo "VALIDATION_STARTING" > /tmp/validation_status.txt

# Check if this is a ComfyUI AMI or base Ubuntu
if systemctl list-units --type=service | grep -q comfyui; then
    echo "🎨 ComfyUI AMI detected - checking services..."
    
    # Check Docker
    if systemctl is-active --quiet docker; then
        echo "✅ Docker is running"
    else
        echo "🔧 Starting Docker..."
        systemctl start docker
        sleep 5
    fi
    
    # Check for ComfyUI services
    if docker ps | grep -q tenant_manager; then
        echo "✅ ComfyUI tenant manager is running"
    else
        echo "🔧 Starting ComfyUI services..."
        systemctl start comfyui-multitenant.service || echo "⚠️ Could not start via systemctl"
        sleep 10
    fi
    
    # Test health endpoints
    echo "🩺 Testing health endpoints..."
    for i in {1..30}; do
        if curl -s http://localhost/health >/dev/null 2>&1; then
            echo "✅ Health endpoint responding"
            break
        fi
        echo "⏳ Waiting for health endpoint (attempt $i/30)..."
        sleep 10
    done
    
    # Check ports
    echo "📊 Checking service ports..."
    netstat -tlnp | grep -E ":80|:8188" || echo "⚠️ No services on expected ports"
    
    # Test ComfyUI functionality
    echo "🧪 Testing ComfyUI functionality..."
    if curl -s http://localhost:8188 | grep -q "ComfyUI" 2>/dev/null; then
        echo "✅ ComfyUI interface accessible"
    else
        echo "⚠️ ComfyUI interface not responding"
    fi
    
    echo "COMFYUI_VALIDATION_COMPLETE" > /tmp/validation_status.txt
else
    echo "📦 Base Ubuntu AMI detected - checking basic functionality..."
    
    # Check basic system
    echo "🔍 System checks..."
    echo "Memory: $(free -h | grep Mem:)"
    echo "Disk: $(df -h / | tail -1)"
    echo "Uptime: $(uptime)"
    
    # Check essential services
    echo "🔍 Service checks..."
    systemctl is-active ssh && echo "✅ SSH active" || echo "⚠️ SSH not active"
    
    # Check package manager
    echo "🔍 Package manager check..."
    apt-get update >/dev/null 2>&1 && echo "✅ Package manager working" || echo "⚠️ Package manager issues"
    
    echo "UBUNTU_VALIDATION_COMPLETE" > /tmp/validation_status.txt
fi

# Show system status
echo "💻 Final system status:"
echo "Memory: $(free -h | grep Mem:)"
echo "Disk: $(df -h / | tail -1)"
echo "Load: $(uptime | awk -F'load average:' '{print $2}')"

# Signal completion
echo "VALIDATION_COMPLETE" > /tmp/validation_status.txt
echo "=== AMI Validation Completed at $(date) ==="
EOF

# Launch validation instance
log_step "Launching validation instance..."
LAUNCH_PARAMS=(
    --image-id "$AMI_ID"
    --instance-type "$TEST_INSTANCE_TYPE"
    --subnet-id "$SUBNET_ID"
    --security-group-ids "$SG_ID"
    --associate-public-ip-address
    --iam-instance-profile "Name=$IAM_ROLE_NAME"
    --user-data "file:///tmp/user-data-validation-${TEST_INSTANCE_NAME}.sh"
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${TEST_INSTANCE_NAME}},{Key=Purpose,Value=AMI-Validation},{Key=Environment,Value=${TARGET_ENVIRONMENT}},{Key=SourceAMI,Value=${AMI_ID}},{Key=CreatedBy,Value=$(whoami)},{Key=CreatedAt,Value=$(date -u +%Y-%m-%dT%H:%M:%SZ)}]"
    --region "$AWS_REGION"
)

INSTANCE_ID=$(aws ec2 run-instances "${LAUNCH_PARAMS[@]}" --query 'Instances[0].InstanceId' --output text)

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
    log_error "Failed to launch validation instance"
    exit 1
fi

log_success "Validation instance launched: $INSTANCE_ID"

# Wait for instance to be running
log_step "Waiting for instance to be running..."
wait_for_instance_state "$INSTANCE_ID" "running"

# Get instance IP
PUBLIC_IP=$(get_instance_ip "$INSTANCE_ID")

log_success "Instance is running!"
log_info "Instance Details:"
echo "   Instance ID: $INSTANCE_ID"
echo "   Public IP: ${PUBLIC_IP:-None}"

# Wait for validation to complete
log_step "Waiting for validation to complete (timeout: ${TIMEOUT_MINUTES} minutes)..."

TIMEOUT_SECONDS=$((TIMEOUT_MINUTES * 60))
START_TIME=$(date +%s)
VALIDATION_SUCCESS=false

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    
    if [[ $ELAPSED -gt $TIMEOUT_SECONDS ]]; then
        log_error "Validation timeout after ${TIMEOUT_MINUTES} minutes"
        break
    fi
    
    # Check validation status via SSM if available
    SSM_STATUS=$(aws ssm describe-instance-information \
        --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'InstanceInformationList[0].PingStatus' \
        --output text 2>/dev/null || echo "")
    
    if [[ "$SSM_STATUS" == "Online" ]]; then
        # Check validation status
        VALIDATION_STATUS=$(aws ssm send-command \
            --instance-ids "$INSTANCE_ID" \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=["cat /tmp/validation_status.txt 2>/dev/null || echo VALIDATION_PENDING"]' \
            --region "$AWS_REGION" \
            --query 'Command.CommandId' \
            --output text 2>/dev/null || echo "")
        
        if [[ -n "$VALIDATION_STATUS" ]]; then
            sleep 3
            
            STATUS_OUTPUT=$(aws ssm get-command-invocation \
                --command-id "$VALIDATION_STATUS" \
                --instance-id "$INSTANCE_ID" \
                --region "$AWS_REGION" \
                --query 'StandardOutputContent' \
                --output text 2>/dev/null || echo "")
            
            if [[ "$STATUS_OUTPUT" == *"VALIDATION_COMPLETE"* ]]; then
                log_success "Validation completed successfully!"
                VALIDATION_SUCCESS=true
                break
            elif [[ "$STATUS_OUTPUT" == *"COMFYUI_VALIDATION_COMPLETE"* ]] || [[ "$STATUS_OUTPUT" == *"UBUNTU_VALIDATION_COMPLETE"* ]]; then
                log_info "Validation phase completed, waiting for final status..."
            else
                log_info "Validation in progress... (${ELAPSED}s elapsed)"
            fi
        fi
    else
        log_info "Waiting for SSM agent... (${ELAPSED}s elapsed)"
    fi
    
    sleep 15
done

# Get validation logs
if [[ "$SSM_STATUS" == "Online" ]]; then
    log_step "Retrieving validation logs..."
    
    LOG_COMMAND=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["tail -50 /var/log/user-data.log 2>/dev/null || echo No validation log found"]' \
        --region "$AWS_REGION" \
        --query 'Command.CommandId' \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "$LOG_COMMAND" ]]; then
        sleep 3
        
        echo ""
        log_info "Validation Logs:"
        echo "----------------------------------------"
        aws ssm get-command-invocation \
            --command-id "$LOG_COMMAND" \
            --instance-id "$INSTANCE_ID" \
            --region "$AWS_REGION" \
            --query 'StandardOutputContent' \
            --output text 2>/dev/null || echo "Could not retrieve logs"
        echo "----------------------------------------"
    fi
fi

# Cleanup or keep instance
if [[ "$KEEP_INSTANCE" == "true" ]]; then
    log_info "Keeping validation instance as requested"
    log_info "Instance management:"
    echo "   Status: $SCRIPT_DIR/manage_instance.sh status $TEST_INSTANCE_NAME"
    echo "   Connect: $SCRIPT_DIR/manage_instance.sh connect $TEST_INSTANCE_NAME"
    echo "   Terminate: $SCRIPT_DIR/manage_instance.sh terminate $TEST_INSTANCE_NAME"
    
    if [[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "None" ]]; then
        echo "   Direct SSH: ssh -i ~/.ssh/your-key.pem ubuntu@$PUBLIC_IP"
    fi
else
    log_step "Terminating validation instance..."
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" >/dev/null
    log_info "Validation instance terminated"
fi

# Cleanup temp files
rm -f "/tmp/user-data-validation-${TEST_INSTANCE_NAME}.sh"

# Final result
echo ""
log_header "Validation Results"

if [[ "$VALIDATION_SUCCESS" == "true" ]]; then
    log_success "✅ AMI validation PASSED"
    log_info "AMI $AMI_ID is ready for deployment"
    echo ""
    log_info "Next steps:"
    echo "   • Deploy to $TARGET_ENVIRONMENT environment"
    echo "   • Update infrastructure to use this AMI"
    echo "   • Monitor deployment for any issues"
    exit 0
else
    log_error "❌ AMI validation FAILED or TIMED OUT"
    log_warning "Issues detected with AMI $AMI_ID"
    echo ""
    log_info "Troubleshooting steps:"
    echo "   • Check the validation logs above"
    echo "   • Launch a manual test instance to investigate"
    echo "   • Review the AMI creation process"
    if [[ "$KEEP_INSTANCE" == "false" ]]; then
        echo "   • Re-run with --keep-instance to debug the test instance"
    fi
    exit 1
fi
