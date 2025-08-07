#!/bin/bash

# Rollback AMI Script for ComfyUI
# Rolls back to the previous AMI or a specified AMI

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/common.sh"

# Help function
show_help() {
    cat << EOF
Rollback AMI Script for ComfyUI

USAGE:
    $0 [OPTIONS] [AMI_ID]

DESCRIPTION:
    Rolls back to the previous AMI or a specified AMI by updating SSM parameters.
    This script updates the SSM parameters to point to the rollback target.

ARGUMENTS:
    AMI_ID              Specific AMI ID to rollback to (optional)
                       If not provided, rolls back to the previous AMI from SSM

OPTIONS:
    -e, --environment ENV    Environment (default: dev)
    -y, --yes               Skip confirmation prompt
    --dry-run              Show what would be done without making changes
    -h, --help             Show this help message

EXAMPLES:
    # Rollback to previous AMI
    $0

    # Rollback to specific AMI
    $0 ami-1234567890abcdef0

    # Rollback for staging environment
    $0 --environment staging

    # Dry run to see what would happen
    $0 --dry-run

    # Auto-confirm rollback
    $0 --yes

ENVIRONMENT VARIABLES:
    ENVIRONMENT            Environment name (default: dev)
    AWS_REGION            AWS region (default: us-east-1)
    AWS_PROFILE           AWS profile to use (optional)

SSM PARAMETERS:
    The script manages these SSM parameters:
    - /comfyui/ami/{env}/latest    - Current latest AMI
    - /comfyui/ami/{env}/previous  - Previous AMI (rollback target)

NOTES:
    - This script only updates SSM parameters
    - Running instances will continue using their current AMI
    - New instances will use the rolled-back AMI
    - Always validate the rollback target before proceeding

EOF
}

# Parse command line arguments
ROLLBACK_AMI_ID=""
ENVIRONMENT="${ENVIRONMENT:-dev}"
SKIP_CONFIRMATION=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        -y|--yes)
            SKIP_CONFIRMATION=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        ami-*)
            ROLLBACK_AMI_ID="$1"
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validate environment
if [[ ! "$ENVIRONMENT" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_error "Invalid environment name: $ENVIRONMENT"
    exit 1
fi

# SSM parameter paths
LATEST_PARAM="/comfyui/ami/${ENVIRONMENT}/latest"
PREVIOUS_PARAM="/comfyui/ami/${ENVIRONMENT}/previous"
BUILD_INFO_PARAM="/comfyui/ami/${ENVIRONMENT}/build-info"

log_info "Starting rollback process for environment: $ENVIRONMENT"

# Get current AMI information
log_info "Fetching current AMI information..."

CURRENT_AMI=$(aws ssm get-parameter \
    --name "$LATEST_PARAM" \
    --query 'Parameter.Value' \
    --output text 2>/dev/null || echo "")

if [[ -z "$CURRENT_AMI" ]]; then
    log_error "No current AMI found in SSM parameter: $LATEST_PARAM"
    exit 1
fi

log_info "Current AMI: $CURRENT_AMI"

# Determine rollback target
if [[ -n "$ROLLBACK_AMI_ID" ]]; then
    ROLLBACK_TARGET="$ROLLBACK_AMI_ID"
    log_info "Using specified rollback target: $ROLLBACK_TARGET"
else
    # Get previous AMI from SSM
    ROLLBACK_TARGET=$(aws ssm get-parameter \
        --name "$PREVIOUS_PARAM" \
        --query 'Parameter.Value' \
        --output text 2>/dev/null || echo "")
    
    if [[ -z "$ROLLBACK_TARGET" ]]; then
        log_error "No previous AMI found in SSM parameter: $PREVIOUS_PARAM"
        log_error "Please specify an AMI ID manually"
        exit 1
    fi
    
    log_info "Using previous AMI as rollback target: $ROLLBACK_TARGET"
fi

# Validate rollback target AMI exists
log_info "Validating rollback target AMI..."

AMI_STATE=$(aws ec2 describe-images \
    --image-ids "$ROLLBACK_TARGET" \
    --query 'Images[0].State' \
    --output text 2>/dev/null || echo "not-found")

if [[ "$AMI_STATE" != "available" ]]; then
    log_error "Rollback target AMI is not available: $ROLLBACK_TARGET (state: $AMI_STATE)"
    exit 1
fi

# Get AMI details
AMI_NAME=$(aws ec2 describe-images \
    --image-ids "$ROLLBACK_TARGET" \
    --query 'Images[0].Name' \
    --output text)

AMI_CREATION_DATE=$(aws ec2 describe-images \
    --image-ids "$ROLLBACK_TARGET" \
    --query 'Images[0].CreationDate' \
    --output text)

log_success "Rollback target is valid"
log_info "  AMI Name: $AMI_NAME"
log_info "  Creation Date: $AMI_CREATION_DATE"

# Check if we're already using the target AMI
if [[ "$CURRENT_AMI" == "$ROLLBACK_TARGET" ]]; then
    log_warn "Current AMI is already the rollback target: $ROLLBACK_TARGET"
    log_info "No rollback needed"
    exit 0
fi

# Display rollback plan
echo
log_info "=== ROLLBACK PLAN ==="
log_info "Environment: $ENVIRONMENT"
log_info "Current AMI: $CURRENT_AMI"
log_info "Rollback to: $ROLLBACK_TARGET ($AMI_NAME)"
echo

if [[ "$DRY_RUN" == true ]]; then
    log_info "=== DRY RUN - WOULD UPDATE ==="
    log_info "SSM Parameter: $LATEST_PARAM"
    log_info "  Old Value: $CURRENT_AMI"
    log_info "  New Value: $ROLLBACK_TARGET"
    echo
    log_info "SSM Parameter: $PREVIOUS_PARAM"
    log_info "  Old Value: $ROLLBACK_TARGET"
    log_info "  New Value: $CURRENT_AMI"
    echo
    log_info "Build info would be updated with rollback timestamp"
    echo
    log_success "Dry run completed - no changes made"
    exit 0
fi

# Confirmation prompt
if [[ "$SKIP_CONFIRMATION" != true ]]; then
    echo
    read -p "Do you want to proceed with the rollback? [y/N]: " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Rollback cancelled"
        exit 0
    fi
    echo
fi

# Perform rollback
log_info "Performing rollback..."

# Update latest to rollback target
log_info "Updating latest AMI parameter..."
aws ssm put-parameter \
    --name "$LATEST_PARAM" \
    --value "$ROLLBACK_TARGET" \
    --type "String" \
    --overwrite

# Update previous to current (for potential rollback of the rollback)
log_info "Updating previous AMI parameter..."
aws ssm put-parameter \
    --name "$PREVIOUS_PARAM" \
    --value "$CURRENT_AMI" \
    --type "String" \
    --overwrite

# Update build info with rollback information
ROLLBACK_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BUILD_INFO=$(cat << EOF
{
  "rollback_timestamp": "$ROLLBACK_TIMESTAMP",
  "rolled_back_from": "$CURRENT_AMI",
  "rolled_back_to": "$ROLLBACK_TARGET",
  "ami_name": "$AMI_NAME",
  "environment": "$ENVIRONMENT",
  "rollback_method": "manual"
}
EOF
)

log_info "Updating build info parameter..."
aws ssm put-parameter \
    --name "$BUILD_INFO_PARAM" \
    --value "$BUILD_INFO" \
    --type "String" \
    --overwrite

log_success "Rollback completed successfully!"
echo

# Display final state
log_info "=== UPDATED CONFIGURATION ==="
log_info "Environment: $ENVIRONMENT"
log_info "Latest AMI: $ROLLBACK_TARGET"
log_info "Previous AMI: $CURRENT_AMI"
log_info "Rollback Time: $ROLLBACK_TIMESTAMP"
echo

log_info "=== NEXT STEPS ==="
log_info "1. Validate the rollback by launching a test instance:"
log_info "   ./validate_ami.sh $ROLLBACK_TARGET"
echo
log_info "2. Monitor any running instances - they will continue using their current AMI"
log_info "   New instances will use the rolled-back AMI: $ROLLBACK_TARGET"
echo
log_info "3. If the rollback is successful, consider cleaning up old AMIs:"
log_info "   ./cleanup_old_amis.sh"
echo

log_success "Rollback process completed"
