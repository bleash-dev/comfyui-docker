#!/bin/bash
# ECR Cleanup Script
# Clean up old Docker images from AWS ECR Public repositories

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration
AWS_REGION="us-east-1"
PUBLIC_REGISTRY_ALIAS="p1c2v8t9"  # Update this to your ECR public registry alias
KEEP_COUNT=3  # Number of recent images to keep
DRY_RUN=false

print_usage() {
    echo "Usage: $0 [options] [repository-name]"
    echo ""
    echo "Options:"
    echo "  -r, --region REGION     AWS region (default: us-east-1)"
    echo "  -a, --alias ALIAS       ECR public registry alias (default: p1c2v8t9)"
    echo "  -k, --keep COUNT        Number of recent images to keep (default: 5)"
    echo "  -d, --dry-run           Show what would be deleted without actually deleting"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 comfyui-docker                    # Clean up comfyui-docker repository"
    echo "  $0 --keep 10 comfyui-docker         # Keep 10 most recent images"
    echo "  $0 --dry-run comfyui-docker         # Preview what would be deleted"
    echo "  $0 --list                           # List all repositories"
}

list_repositories() {
    echo -e "${BLUE}📋 ECR Public Repositories:${NC}"
    aws ecr-public describe-repositories \
        --region "$AWS_REGION" \
        --query 'repositories[*].[repositoryName,createdAt,repositoryUri]' \
        --output table || echo "Failed to list repositories"
}

cleanup_repository() {
    local repo_name="$1"
    
    echo -e "${BLUE}🧹 Cleaning up ECR repository: $repo_name${NC}"
    echo "  Region: $AWS_REGION"
    echo "  Keep count: $KEEP_COUNT"
    echo "  Dry run: $DRY_RUN"
    echo ""
    
    # Get all images in the repository, sorted by pushed date (oldest first)
    echo -e "${BLUE}📋 Getting list of images...${NC}"
    IMAGES=$(aws ecr-public describe-images \
        --repository-name "$repo_name" \
        --region "$AWS_REGION" \
        --query 'sort_by(imageDetails, &imagePushedAt)' \
        --output json 2>/dev/null || echo '[]')
    
    if [ "$IMAGES" = "[]" ]; then
        echo -e "${YELLOW}⚠️ No images found or repository doesn't exist${NC}"
        return 1
    fi
    
    # Count total images
    TOTAL_IMAGES=$(echo "$IMAGES" | jq length)
    echo -e "${GREEN}📊 Total images found: $TOTAL_IMAGES${NC}"
    
    if [ "$TOTAL_IMAGES" -le "$KEEP_COUNT" ]; then
        echo -e "${GREEN}✅ Only $TOTAL_IMAGES images found, keeping all (threshold: $KEEP_COUNT)${NC}"
        return 0
    fi
    
    # Calculate how many to delete
    DELETE_COUNT=$((TOTAL_IMAGES - KEEP_COUNT))
    echo -e "${YELLOW}🗑️ Will delete $DELETE_COUNT old images, keeping newest $KEEP_COUNT${NC}"
    
    # Show what would be deleted
    echo -e "${BLUE}📋 Images to delete (oldest first):${NC}"
    echo "$IMAGES" | jq -r ".[0:$DELETE_COUNT][] | \"  • \(.imageTags // [\"<untagged>\"] | join(\", \")) - pushed: \(.imagePushedAt) - digest: \(.imageDigest[0:12])...\""
    
    if [ "$DRY_RUN" = "true" ]; then
        echo -e "${YELLOW}🔍 DRY RUN: No images were actually deleted${NC}"
        return 0
    fi
    
    # Ask for confirmation unless in automated mode
    if [ -t 0 ]; then
        echo ""
        read -p "Are you sure you want to delete these $DELETE_COUNT images? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${BLUE}ℹ️ Operation cancelled${NC}"
            return 0
        fi
    fi
    
    # Get the oldest images to delete
    IMAGES_TO_DELETE=$(echo "$IMAGES" | jq -r ".[0:$DELETE_COUNT][] | .imageDigest")
    
    if [ -z "$IMAGES_TO_DELETE" ]; then
        echo -e "${GREEN}✅ No images to delete${NC}"
        return 0
    fi
    
    # Delete old images
    echo -e "${BLUE}🗑️ Deleting old images...${NC}"
    DELETED_COUNT=0
    FAILED_COUNT=0
    
    for digest in $IMAGES_TO_DELETE; do
        echo "  Deleting image with digest: ${digest:0:12}..."
        if aws ecr-public batch-delete-image \
            --repository-name "$repo_name" \
            --region "$AWS_REGION" \
            --image-ids imageDigest="$digest" >/dev/null 2>&1; then
            ((DELETED_COUNT++))
            echo -e "    ${GREEN}✅ Deleted${NC}"
        else
            ((FAILED_COUNT++))
            echo -e "    ${RED}❌ Failed${NC}"
        fi
    done
    
    echo ""
    echo -e "${GREEN}✅ ECR cleanup completed${NC}"
    echo "  Deleted: $DELETED_COUNT images"
    if [ "$FAILED_COUNT" -gt 0 ]; then
        echo -e "  ${YELLOW}Failed: $FAILED_COUNT images${NC}"
    fi
}

get_repository_stats() {
    local repo_name="$1"
    
    echo -e "${BLUE}📊 Repository Statistics: $repo_name${NC}"
    
    # Get repository info
    REPO_INFO=$(aws ecr-public describe-repositories \
        --repository-names "$repo_name" \
        --region "$AWS_REGION" \
        --query 'repositories[0]' \
        --output json 2>/dev/null || echo '{}')
    
    if [ "$REPO_INFO" = "{}" ]; then
        echo -e "${RED}❌ Repository not found${NC}"
        return 1
    fi
    
    # Get images
    IMAGES=$(aws ecr-public describe-images \
        --repository-name "$repo_name" \
        --region "$AWS_REGION" \
        --query 'imageDetails' \
        --output json 2>/dev/null || echo '[]')
    
    TOTAL_IMAGES=$(echo "$IMAGES" | jq length)
    TOTAL_SIZE=$(echo "$IMAGES" | jq '[.[].imageSizeInBytes] | add // 0')
    TOTAL_SIZE_MB=$((TOTAL_SIZE / 1024 / 1024))
    
    echo "  Repository URI: $(echo "$REPO_INFO" | jq -r '.repositoryUri')"
    echo "  Created: $(echo "$REPO_INFO" | jq -r '.createdAt')"
    echo "  Total images: $TOTAL_IMAGES"
    echo "  Total size: ${TOTAL_SIZE_MB} MB"
    
    if [ "$TOTAL_IMAGES" -gt 0 ]; then
        echo ""
        echo -e "${BLUE}📋 Recent images:${NC}"
        echo "$IMAGES" | jq -r 'sort_by(.imagePushedAt) | reverse | .[0:5][] | "  • \(.imageTags // ["<untagged>"] | join(", ")) - \(.imagePushedAt) - \((.imageSizeInBytes / 1024 / 1024 | floor))MB"'
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--region)
            AWS_REGION="$2"
            shift 2
            ;;
        -a|--alias)
            PUBLIC_REGISTRY_ALIAS="$2"
            shift 2
            ;;
        -k|--keep)
            KEEP_COUNT="$2"
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        --list)
            list_repositories
            exit 0
            ;;
        --stats)
            if [ -n "$2" ] && [[ "$2" != -* ]]; then
                get_repository_stats "$2"
                shift 2
            else
                echo -e "${RED}❌ Repository name required for --stats${NC}"
                exit 1
            fi
            exit 0
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

cleanup_repository "$REPO_NAME"
