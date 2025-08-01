#!/bin/bash
# ECR Lifecycle Policy Setup Script
# Set up automatic cleanup policies for ECR repositories
# 
# ⚠️  IMPORTANT: ECR lifecycle policies only work for PRIVATE ECR repositories!
#     Public ECR repositories do not support lifecycle policies.
#     Use the cleanup_ecr.sh script for manual cleanup of public repositories.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration
AWS_REGION="us-east-1"
KEEP_COUNT=5

print_usage() {
    echo "Usage: $0 [options] [repository-name]"
    echo ""
    echo "Options:"
    echo "  -r, --region REGION     AWS region (default: us-east-1)"
    echo "  -k, --keep COUNT        Number of recent images to keep (default: 5)"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 comfyui-docker                    # Set up lifecycle policy for comfyui-docker"
    echo "  $0 --keep 10 comfyui-docker         # Keep 10 most recent images"
    echo ""
    echo "⚠️  Note: Lifecycle policies only work for PRIVATE ECR repositories!"
}

check_repository_type() {
    local repo_name="$1"
    
    echo -e "${BLUE}🔍 Checking repository type for: $repo_name${NC}"
    
    # Try to describe as private repository first
    if aws ecr describe-repositories --repository-names "$repo_name" --region "$AWS_REGION" &>/dev/null; then
        echo -e "${GREEN}✓ Repository $repo_name is PRIVATE - lifecycle policies are supported${NC}"
        return 0
    fi
    
    # Check if it's a public repository
    if aws ecr-public describe-repositories --repository-names "$repo_name" --region us-east-1 &>/dev/null; then
        echo -e "${RED}❌ Repository $repo_name is PUBLIC - lifecycle policies are NOT supported${NC}"
        echo -e "${YELLOW}   Use the cleanup_ecr.sh script for manual cleanup instead${NC}"
        return 1
    fi
    
    echo -e "${RED}❌ Repository $repo_name not found in either private or public ECR${NC}"
    return 1
}

setup_lifecycle_policy() {
    local repo_name="$1"
    
    # Check if repository is private (lifecycle policies only work for private repos)
    if ! check_repository_type "$repo_name"; then
        echo -e "${RED}❌ Cannot set up lifecycle policy for this repository${NC}"
        return 1
    fi
    
    echo ""
    echo -e "${BLUE}🔧 Setting up ECR lifecycle policy for: $repo_name${NC}"
    echo "  Region: $AWS_REGION"
    echo "  Keep count: $KEEP_COUNT"
    echo ""
    
    # Create lifecycle policy JSON
    LIFECYCLE_POLICY=$(cat <<EOF
{
    "rules": [
        {
            "rulePriority": 1,
            "description": "Keep only the $KEEP_COUNT most recent images",
            "selection": {
                "tagStatus": "any",
                "countType": "imageCountMoreThan",
                "countNumber": $KEEP_COUNT
            },
            "action": {
                "type": "expire"
            }
        }
    ]
}
EOF
)
    
    echo -e "${BLUE}📋 Lifecycle Policy:${NC}"
    echo "$LIFECYCLE_POLICY" | jq .
    echo ""
    
    # Apply lifecycle policy
    echo -e "${BLUE}🚀 Applying lifecycle policy...${NC}"
    if echo "$LIFECYCLE_POLICY" | aws ecr-public put-lifecycle-policy \
        --repository-name "$repo_name" \
        --region "$AWS_REGION" \
        --lifecycle-policy-text file:///dev/stdin; then
        echo -e "${GREEN}✅ Lifecycle policy applied successfully${NC}"
        echo ""
        echo -e "${YELLOW}ℹ️ Note: ECR will automatically clean up old images based on this policy${NC}"
        echo -e "${YELLOW}   It may take some time for the policy to take effect${NC}"
    else
        echo -e "${RED}❌ Failed to apply lifecycle policy${NC}"
        return 1
    fi
}

get_lifecycle_policy() {
    local repo_name="$1"
    
    echo -e "${BLUE}📋 Current lifecycle policy for: $repo_name${NC}"
    
    if aws ecr-public get-lifecycle-policy \
        --repository-name "$repo_name" \
        --region "$AWS_REGION" \
        --query 'lifecyclePolicyText' \
        --output text 2>/dev/null | jq .; then
        echo ""
    else
        echo -e "${YELLOW}⚠️ No lifecycle policy found${NC}"
    fi
}

delete_lifecycle_policy() {
    local repo_name="$1"
    
    echo -e "${BLUE}🗑️ Deleting lifecycle policy for: $repo_name${NC}"
    
    if aws ecr-public delete-lifecycle-policy \
        --repository-name "$repo_name" \
        --region "$AWS_REGION"; then
        echo -e "${GREEN}✅ Lifecycle policy deleted successfully${NC}"
    else
        echo -e "${RED}❌ Failed to delete lifecycle policy${NC}"
        return 1
    fi
}

# Parse command line arguments
ACTION="setup"
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--region)
            AWS_REGION="$2"
            shift 2
            ;;
        -k|--keep)
            KEEP_COUNT="$2"
            shift 2
            ;;
        --get)
            ACTION="get"
            shift
            ;;
        --delete)
            ACTION="delete"
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        -*)
            echo -e "${RED}❌ Unknown option: $1${NC}"
            print_usage
            exit 1
            ;;
        *)
            REPO_NAME="$1"
            shift
            ;;
    esac
done

# Main execution
if [ -z "$REPO_NAME" ]; then
    echo -e "${RED}❌ Repository name required${NC}"
    print_usage
    exit 1
fi

# Validate keep count
if ! [[ "$KEEP_COUNT" =~ ^[0-9]+$ ]] || [ "$KEEP_COUNT" -lt 1 ]; then
    echo -e "${RED}❌ Keep count must be a positive integer${NC}"
    exit 1
fi

# Check AWS CLI is available
if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI is not installed${NC}"
    exit 1
fi

# Check jq is available
if ! command -v jq &> /dev/null; then
    echo -e "${RED}❌ jq is not installed${NC}"
    exit 1
fi

# Verify AWS credentials
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo -e "${RED}❌ AWS credentials not configured or invalid${NC}"
    exit 1
fi

case $ACTION in
    setup)
        setup_lifecycle_policy "$REPO_NAME"
        ;;
    get)
        get_lifecycle_policy "$REPO_NAME"
        ;;
    delete)
        delete_lifecycle_policy "$REPO_NAME"
        ;;
    *)
        echo -e "${RED}❌ Unknown action: $ACTION${NC}"
        exit 1
        ;;
esac
