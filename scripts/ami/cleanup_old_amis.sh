#!/bin/bash

# Cleanup Old AMIs Script
# Removes old ComfyUI AMIs while keeping the most recent ones

set -e

# Source configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Clean up old ComfyUI AMIs to save storage costs"
    echo ""
    echo "Options:"
    echo "  --keep COUNT            Number of recent AMIs to keep (default: 5)"
    echo "  --environment ENV       Target environment (default: $ENVIRONMENT)"
    echo "  --ami-prefix PREFIX     AMI name prefix to filter (default: $AMI_NAME_PREFIX)"
    echo "  --dry-run               Show what would be deleted without actually doing it"
    echo "  --force                 Skip confirmation prompts"
    echo "  --include-snapshots     Also delete associated EBS snapshots"
    echo "  --help                  Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                              # Keep 5 most recent AMIs"
    echo "  $0 --keep 3                     # Keep only 3 most recent AMIs"
    echo "  $0 --environment staging        # Clean up staging AMIs"
    echo "  $0 --dry-run                    # Preview what would be deleted"
    echo "  $0 --include-snapshots --force  # Delete AMIs and snapshots without prompting"
}

# Default configuration
KEEP_COUNT=5
TARGET_ENVIRONMENT="$ENVIRONMENT"
TARGET_AMI_PREFIX="$AMI_NAME_PREFIX"
DRY_RUN=false
FORCE=false
INCLUDE_SNAPSHOTS=true

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --keep)
            KEEP_COUNT="$2"
            shift 2
            ;;
        --environment)
            TARGET_ENVIRONMENT="$2"
            shift 2
            ;;
        --ami-prefix)
            TARGET_AMI_PREFIX="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --include-snapshots)
            INCLUDE_SNAPSHOTS=true
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
            echo "Unexpected argument: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Validate arguments
if ! [[ "$KEEP_COUNT" =~ ^[0-9]+$ ]] || [[ "$KEEP_COUNT" -lt 1 ]]; then
    log_error "Keep count must be a positive integer"
    exit 1
fi

# Validate AWS CLI
validate_aws_cli

log_header "Cleaning up old ComfyUI AMIs"

log_info "Configuration:"
echo "   Environment: $TARGET_ENVIRONMENT"
echo "   AMI Prefix: $TARGET_AMI_PREFIX"
echo "   Keep Count: $KEEP_COUNT"
echo "   Include Snapshots: $INCLUDE_SNAPSHOTS"
echo "   Dry Run: $DRY_RUN"

# Get all ComfyUI AMIs for the environment
log_step "Finding ComfyUI AMIs..."

# Build filter pattern for environment-specific AMIs
AMI_PATTERN="${TARGET_AMI_PREFIX}-${TARGET_ENVIRONMENT}-*"

# Get AMIs owned by current account with the specified pattern
AMIS_JSON=$(aws ec2 describe-images \
    --owners self \
    --filters "Name=name,Values=$AMI_PATTERN" "Name=state,Values=available" \
    --query 'Images[*].[ImageId,Name,CreationDate,Description]' \
    --output json \
    --region "$AWS_REGION")

if [[ "$AMIS_JSON" == "[]" || -z "$AMIS_JSON" ]]; then
    log_warning "No ComfyUI AMIs found matching pattern: $AMI_PATTERN"
    exit 0
fi

# Parse and sort AMIs by creation date (newest first)
SORTED_AMIS=$(echo "$AMIS_JSON" | jq -r '.[] | @csv' | sort -t',' -k3 -r)

# Count total AMIs
TOTAL_AMIS=$(echo "$SORTED_AMIS" | wc -l | tr -d ' ')

log_success "Found $TOTAL_AMIS AMIs matching pattern: $AMI_PATTERN"

# Check if we need to delete any AMIs
if [[ "$TOTAL_AMIS" -le "$KEEP_COUNT" ]]; then
    log_info "No cleanup needed - found $TOTAL_AMIS AMIs, keeping $KEEP_COUNT"
    exit 0
fi

# Calculate how many to delete
DELETE_COUNT=$((TOTAL_AMIS - KEEP_COUNT))

log_warning "Will delete $DELETE_COUNT old AMIs (keeping $KEEP_COUNT most recent)"

# Get current AMI from SSM for protection
CURRENT_AMI=$(aws ssm get-parameter \
    --name "/comfyui/ami/$TARGET_ENVIRONMENT/latest" \
    --query 'Parameter.Value' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")

PREVIOUS_AMI=$(aws ssm get-parameter \
    --name "/comfyui/ami/$TARGET_ENVIRONMENT/previous" \
    --query 'Parameter.Value' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")

# Get AMIs to keep (most recent ones)
KEEP_AMIS=$(echo "$SORTED_AMIS" | head -n "$KEEP_COUNT")
DELETE_AMIS=$(echo "$SORTED_AMIS" | tail -n "+$((KEEP_COUNT + 1))")

echo ""
log_info "AMIs to KEEP (${KEEP_COUNT} most recent):"
echo "$KEEP_AMIS" | while IFS=, read -r ami_id ami_name creation_date description; do
    # Remove quotes from CSV
    ami_id=$(echo "$ami_id" | tr -d '"')
    ami_name=$(echo "$ami_name" | tr -d '"')
    creation_date=$(echo "$creation_date" | tr -d '"')
    
    # Add indicator if this is current or previous
    INDICATOR=""
    if [[ "$ami_id" == "$CURRENT_AMI" ]]; then
        INDICATOR=" (CURRENT)"
    elif [[ "$ami_id" == "$PREVIOUS_AMI" ]]; then
        INDICATOR=" (PREVIOUS)"
    fi
    
    echo "   ✅ $ami_id - $ami_name - $creation_date$INDICATOR"
done

echo ""
log_warning "AMIs to DELETE (${DELETE_COUNT} oldest):"
echo "$DELETE_AMIS" | while IFS=, read -r ami_id ami_name creation_date description; do
    # Remove quotes from CSV
    ami_id=$(echo "$ami_id" | tr -d '"')
    ami_name=$(echo "$ami_name" | tr -d '"')
    creation_date=$(echo "$creation_date" | tr -d '"')
    
    # Check if this AMI is protected
    PROTECTED=""
    if [[ "$ami_id" == "$CURRENT_AMI" ]]; then
        PROTECTED=" (⚠️  PROTECTED - CURRENT AMI)"
    elif [[ "$ami_id" == "$PREVIOUS_AMI" ]]; then
        PROTECTED=" (⚠️  PROTECTED - PREVIOUS AMI)"
    fi
    
    echo "   ❌ $ami_id - $ami_name - $creation_date$PROTECTED"
done

# Check for protected AMIs in delete list
PROTECTED_IN_DELETE=$(echo "$DELETE_AMIS" | while IFS=, read -r ami_id ami_name creation_date description; do
    ami_id=$(echo "$ami_id" | tr -d '"')
    if [[ "$ami_id" == "$CURRENT_AMI" ]] || [[ "$ami_id" == "$PREVIOUS_AMI" ]]; then
        echo "$ami_id"
    fi
done)

if [[ -n "$PROTECTED_IN_DELETE" ]]; then
    log_error "Cannot delete AMIs that are marked as current or previous in SSM parameters!"
    log_error "Protected AMIs: $PROTECTED_IN_DELETE"
    log_info "Consider increasing --keep count or updating SSM parameters first"
    exit 1
fi

# Dry run output
if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    log_warning "DRY RUN: Would delete the following AMIs:"
    echo "$DELETE_AMIS" | while IFS=, read -r ami_id ami_name creation_date description; do
        ami_id=$(echo "$ami_id" | tr -d '"')
        echo "   aws ec2 deregister-image --image-id $ami_id"
        
        if [[ "$INCLUDE_SNAPSHOTS" == "true" ]]; then
            # Get associated snapshots
            SNAPSHOTS=$(aws ec2 describe-images \
                --image-ids "$ami_id" \
                --query 'Images[0].BlockDeviceMappings[*].Ebs.SnapshotId' \
                --output text \
                --region "$AWS_REGION" 2>/dev/null || echo "")
            
            if [[ -n "$SNAPSHOTS" && "$SNAPSHOTS" != "None" ]]; then
                for snapshot in $SNAPSHOTS; do
                    echo "   aws ec2 delete-snapshot --snapshot-id $snapshot"
                done
            fi
        fi
    done
    exit 0
fi

# Confirmation prompt
if [[ "$FORCE" == "false" ]]; then
    echo ""
    log_warning "This will permanently delete $DELETE_COUNT AMIs!"
    if [[ "$INCLUDE_SNAPSHOTS" == "true" ]]; then
        log_warning "This will also delete associated EBS snapshots!"
    fi
    echo ""
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Operation cancelled"
        exit 0
    fi
fi

# Delete AMIs
echo ""
log_step "Deleting old AMIs..."

DELETED_COUNT=0
FAILED_COUNT=0

echo "$DELETE_AMIS" | while IFS=, read -r ami_id ami_name creation_date description; do
    ami_id=$(echo "$ami_id" | tr -d '"')
    ami_name=$(echo "$ami_name" | tr -d '"')
    
    log_info "Deleting AMI: $ami_id ($ami_name)"
    
    # Get associated snapshots before deleting AMI
    if [[ "$INCLUDE_SNAPSHOTS" == "true" ]]; then
        SNAPSHOTS=$(aws ec2 describe-images \
            --image-ids "$ami_id" \
            --query 'Images[0].BlockDeviceMappings[*].Ebs.SnapshotId' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "")
    fi
    
    # Deregister the AMI
    if aws ec2 deregister-image --image-id "$ami_id" --region "$AWS_REGION" >/dev/null 2>&1; then
        log_success "Deregistered AMI: $ami_id"
        DELETED_COUNT=$((DELETED_COUNT + 1))
        
        # Delete associated snapshots if requested
        if [[ "$INCLUDE_SNAPSHOTS" == "true" && -n "$SNAPSHOTS" && "$SNAPSHOTS" != "None" ]]; then
            for snapshot in $SNAPSHOTS; do
                log_info "Deleting snapshot: $snapshot"
                if aws ec2 delete-snapshot --snapshot-id "$snapshot" --region "$AWS_REGION" >/dev/null 2>&1; then
                    log_success "Deleted snapshot: $snapshot"
                else
                    log_warning "Failed to delete snapshot: $snapshot (may be in use)"
                fi
            done
        fi
    else
        log_error "Failed to deregister AMI: $ami_id"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
done

# Final summary
echo ""
log_header "Cleanup Complete!"
log_success "Successfully deleted $DELETED_COUNT AMIs"

if [[ "$FAILED_COUNT" -gt 0 ]]; then
    log_warning "Failed to delete $FAILED_COUNT AMIs"
fi

# Show remaining AMIs
log_info "Remaining AMIs in $TARGET_ENVIRONMENT:"
echo "$KEEP_AMIS" | while IFS=, read -r ami_id ami_name creation_date description; do
    ami_id=$(echo "$ami_id" | tr -d '"')
    ami_name=$(echo "$ami_name" | tr -d '"')
    creation_date=$(echo "$creation_date" | tr -d '"')
    
    INDICATOR=""
    if [[ "$ami_id" == "$CURRENT_AMI" ]]; then
        INDICATOR=" (CURRENT)"
    elif [[ "$ami_id" == "$PREVIOUS_AMI" ]]; then
        INDICATOR=" (PREVIOUS)"
    fi
    
    echo "   📦 $ami_id - $ami_name - $creation_date$INDICATOR"
done

echo ""
log_info "Storage savings achieved by removing $DELETED_COUNT old AMIs"
if [[ "$INCLUDE_SNAPSHOTS" == "true" ]]; then
    log_info "EBS snapshot cleanup also performed"
fi
