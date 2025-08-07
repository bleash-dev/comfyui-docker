#!/bin/bash

# List AMIs Script
# Display all ComfyUI AMIs with detailed information

set -e

# Source configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "List ComfyUI AMIs with detailed information"
    echo ""
    echo "Options:"
    echo "  --environment ENV       Filter by environment (default: all)"
    echo "  --ami-prefix PREFIX     AMI name prefix to filter (default: $AMI_NAME_PREFIX)"
    echo "  --show-snapshots        Show associated EBS snapshots"
    echo "  --show-ssm              Show SSM parameter mappings"
    echo "  --format FORMAT         Output format: table|json|csv (default: table)"
    echo "  --limit COUNT           Limit number of results (default: 20)"
    echo "  --help                  Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                              # List all ComfyUI AMIs"
    echo "  $0 --environment prod           # List only production AMIs"
    echo "  $0 --show-snapshots             # Include snapshot information"
    echo "  $0 --format json                # Output in JSON format"
    echo "  $0 --limit 10                   # Show only 10 most recent AMIs"
}

# Default configuration
TARGET_ENVIRONMENT=""
TARGET_AMI_PREFIX="$AMI_NAME_PREFIX"
SHOW_SNAPSHOTS=false
SHOW_SSM=false
OUTPUT_FORMAT="table"
LIMIT=20

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --environment)
            TARGET_ENVIRONMENT="$2"
            shift 2
            ;;
        --ami-prefix)
            TARGET_AMI_PREFIX="$2"
            shift 2
            ;;
        --show-snapshots)
            SHOW_SNAPSHOTS=true
            shift
            ;;
        --show-ssm)
            SHOW_SSM=true
            shift
            ;;
        --format)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        --limit)
            LIMIT="$2"
            shift 2
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
if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [[ "$LIMIT" -lt 1 ]]; then
    log_error "Limit must be a positive integer"
    exit 1
fi

case "$OUTPUT_FORMAT" in
    "table"|"json"|"csv") ;;
    *)
        log_error "Invalid format. Use: table, json, or csv"
        exit 1
        ;;
esac

# Validate AWS CLI
validate_aws_cli

log_header "ComfyUI AMIs"

# Build AMI name pattern
if [[ -n "$TARGET_ENVIRONMENT" ]]; then
    AMI_PATTERN="${TARGET_AMI_PREFIX}-${TARGET_ENVIRONMENT}-*"
    log_info "Filtering by environment: $TARGET_ENVIRONMENT"
else
    AMI_PATTERN="${TARGET_AMI_PREFIX}-*"
    log_info "Showing all environments"
fi

log_info "Configuration:"
echo "   AMI Pattern: $AMI_PATTERN"
echo "   Limit: $LIMIT"
echo "   Format: $OUTPUT_FORMAT"
echo "   Show Snapshots: $SHOW_SNAPSHOTS"
echo "   Show SSM: $SHOW_SSM"

# Get AMIs
log_step "Fetching AMI information..."

AMIS_JSON=$(aws ec2 describe-images \
    --owners self \
    --filters "Name=name,Values=$AMI_PATTERN" \
    --query 'Images[*].[ImageId,Name,State,CreationDate,Description,Architecture,VirtualizationType,RootDeviceType,BlockDeviceMappings[0].Ebs.VolumeSize,Tags[?Key==`Environment`].Value|[0],Tags[?Key==`CreatedBy`].Value|[0]]' \
    --output json \
    --region "$AWS_REGION")

if [[ "$AMIS_JSON" == "[]" || -z "$AMIS_JSON" ]]; then
    log_warning "No AMIs found matching pattern: $AMI_PATTERN"
    exit 0
fi

# Sort by creation date (newest first) and limit results
SORTED_AMIS=$(echo "$AMIS_JSON" | jq -r '.[] | @csv' | sort -t',' -k4 -r | head -n "$LIMIT")

TOTAL_COUNT=$(echo "$SORTED_AMIS" | wc -l | tr -d ' ')
log_success "Found $TOTAL_COUNT AMIs"

# Get SSM parameter information if requested
if [[ "$SHOW_SSM" == "true" ]]; then
    log_step "Fetching SSM parameter mappings..."
    
    # Get all ComfyUI SSM parameters
    SSM_PARAMS=$(aws ssm get-parameters-by-path \
        --path "/comfyui/ami" \
        --recursive \
        --query 'Parameters[?ends_with(Name, `/latest`) || ends_with(Name, `/previous`)].{Name:Name,Value:Value}' \
        --output json \
        --region "$AWS_REGION" 2>/dev/null || echo "[]")
fi

# Output based on format
case "$OUTPUT_FORMAT" in
    "json")
        # JSON output
        echo "$SORTED_AMIS" | while IFS=, read -r ami_id name state creation_date description architecture virt_type root_device volume_size environment created_by; do
            # Remove quotes from CSV
            ami_id=$(echo "$ami_id" | tr -d '"')
            name=$(echo "$name" | tr -d '"')
            state=$(echo "$state" | tr -d '"')
            creation_date=$(echo "$creation_date" | tr -d '"')
            description=$(echo "$description" | tr -d '"')
            architecture=$(echo "$architecture" | tr -d '"')
            virt_type=$(echo "$virt_type" | tr -d '"')
            root_device=$(echo "$root_device" | tr -d '"')
            volume_size=$(echo "$volume_size" | tr -d '"')
            environment=$(echo "$environment" | tr -d '"')
            created_by=$(echo "$created_by" | tr -d '"')
            
            # Build JSON object
            jq -n \
                --arg ami_id "$ami_id" \
                --arg name "$name" \
                --arg state "$state" \
                --arg creation_date "$creation_date" \
                --arg description "$description" \
                --arg architecture "$architecture" \
                --arg virt_type "$virt_type" \
                --arg root_device "$root_device" \
                --arg volume_size "$volume_size" \
                --arg environment "$environment" \
                --arg created_by "$created_by" \
                '{
                    ami_id: $ami_id,
                    name: $name,
                    state: $state,
                    creation_date: $creation_date,
                    description: $description,
                    architecture: $architecture,
                    virtualization_type: $virt_type,
                    root_device_type: $root_device,
                    volume_size_gb: $volume_size,
                    environment: $environment,
                    created_by: $created_by
                }'
        done | jq -s '.'
        ;;
        
    "csv")
        # CSV output
        echo "AMI_ID,Name,State,Creation_Date,Description,Architecture,Virtualization,Root_Device,Volume_Size_GB,Environment,Created_By"
        echo "$SORTED_AMIS"
        ;;
        
    "table")
        # Table output (default)
        echo ""
        
        if [[ "$SHOW_SSM" == "true" ]]; then
            log_info "SSM Parameter Mappings:"
            if [[ "$SSM_PARAMS" != "[]" ]]; then
                echo "$SSM_PARAMS" | jq -r '.[] | "   \(.Name) -> \(.Value)"'
            else
                echo "   No SSM parameters found"
            fi
            echo ""
        fi
        
        echo "$SORTED_AMIS" | while IFS=, read -r ami_id name state creation_date description architecture virt_type root_device volume_size environment created_by; do
            # Remove quotes from CSV
            ami_id=$(echo "$ami_id" | tr -d '"')
            name=$(echo "$name" | tr -d '"')
            state=$(echo "$state" | tr -d '"')
            creation_date=$(echo "$creation_date" | tr -d '"')
            description=$(echo "$description" | tr -d '"' | cut -c1-50)
            architecture=$(echo "$architecture" | tr -d '"')
            virt_type=$(echo "$virt_type" | tr -d '"')
            root_device=$(echo "$root_device" | tr -d '"')
            volume_size=$(echo "$volume_size" | tr -d '"')
            environment=$(echo "$environment" | tr -d '"')
            created_by=$(echo "$created_by" | tr -d '"')
            
            # Format creation date
            formatted_date=$(date -d "$creation_date" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$creation_date")
            
            # Add status indicator
            case "$state" in
                "available") status_icon="🟢" ;;
                "pending") status_icon="🟡" ;;
                "failed") status_icon="🔴" ;;
                *) status_icon="⚪" ;;
            esac
            
            # Check if this AMI is current or previous in SSM
            ssm_indicator=""
            if [[ "$SHOW_SSM" == "true" && "$SSM_PARAMS" != "[]" ]]; then
                if echo "$SSM_PARAMS" | jq -e ".[] | select(.Value == \"$ami_id\" and (.Name | contains(\"/latest\")))" >/dev/null 2>&1; then
                    ssm_indicator=" (CURRENT)"
                elif echo "$SSM_PARAMS" | jq -e ".[] | select(.Value == \"$ami_id\" and (.Name | contains(\"/previous\")))" >/dev/null 2>&1; then
                    ssm_indicator=" (PREVIOUS)"
                fi
            fi
            
            echo ""
            echo "$status_icon $name$ssm_indicator"
            echo "   ID: $ami_id"
            echo "   State: $state"
            echo "   Created: $formatted_date"
            echo "   Environment: ${environment:-Unknown}"
            echo "   Created By: ${created_by:-Unknown}"
            echo "   Architecture: $architecture ($virt_type)"
            echo "   Storage: ${volume_size:-Unknown}GB $root_device"
            
            if [[ -n "$description" && "$description" != "null" ]]; then
                echo "   Description: $description"
            fi
            
            # Show snapshots if requested
            if [[ "$SHOW_SNAPSHOTS" == "true" ]]; then
                snapshots=$(aws ec2 describe-images \
                    --image-ids "$ami_id" \
                    --query 'Images[0].BlockDeviceMappings[*].Ebs.SnapshotId' \
                    --output text \
                    --region "$AWS_REGION" 2>/dev/null || echo "")
                
                if [[ -n "$snapshots" && "$snapshots" != "None" ]]; then
                    echo "   Snapshots: $snapshots"
                fi
            fi
        done
        
        echo ""
        log_info "Summary:"
        echo "   Total AMIs shown: $TOTAL_COUNT"
        echo "   Pattern: $AMI_PATTERN"
        
        if [[ "$TOTAL_COUNT" -eq "$LIMIT" ]]; then
            echo "   Note: Results limited to $LIMIT. Use --limit to see more."
        fi
        
        echo ""
        log_info "Management Commands:"
        echo "   Validate AMI: $SCRIPT_DIR/validate_ami.sh <ami-id>"
        echo "   Create new AMI: $SCRIPT_DIR/create_ami.sh <instance-name>"
        echo "   Cleanup old AMIs: $SCRIPT_DIR/cleanup_old_amis.sh"
        ;;
esac
