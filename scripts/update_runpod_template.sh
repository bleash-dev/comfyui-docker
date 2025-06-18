#!/bin/bash
set -euo pipefail

echo "🚀 Updating RunPod template..."

# Validate required environment variables
required_vars=("RUNPOD_API_KEY" "RUNPOD_TEMPLATE_ID" "DOCKER_IMAGE_TAG" "GITHUB_USERNAME" "GITHUB_PAT")
for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "❌ Required environment variable $var is not set"
        echo "💡 Make sure to set this as a secret in your GitHub repository"
        exit 1
    fi
done

# Use the commit-tagged image if available, fallback to main tag
if [ -n "${DOCKER_METADATA_OUTPUT_TAGS:-}" ]; then
    # Extract the commit-tagged image from the tags
    COMMIT_TAG=$(echo "$DOCKER_METADATA_OUTPUT_TAGS" | grep -E ":[a-z]+-[a-f0-9]+" | head -n1 || echo "$DOCKER_IMAGE_TAG")
    DOCKER_IMAGE_TAG="$COMMIT_TAG"
fi

echo "📋 Template Update Details:"
echo "  Template ID: $RUNPOD_TEMPLATE_ID"
echo "  Docker Image: $DOCKER_IMAGE_TAG"
echo "  Registry Auth: $GITHUB_USERNAME"

# Make the API call to update the template
echo "📤 Sending update request to RunPod API..."

response=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $RUNPOD_API_KEY" \
    -H "Content-Type: application/json" \
    "https://api.runpod.io/graphql" \
    --data-raw '{
        "query": "mutation updateTemplate($input: UpdateTemplateInput!) { updateTemplate(input: $input) { id name containerImage } }",
        "variables": {
            "input": {
                "id": "'$RUNPOD_TEMPLATE_ID'",
                "containerImage": "'$DOCKER_IMAGE_TAG'"
            }
        }
    }')

# Extract HTTP status code
http_code=$(echo "$response" | tail -n1)
response_body=$(echo "$response" | head -n -1)

echo "📊 API Response Code: $http_code"

if [ "$http_code" -eq 200 ]; then
    echo "✅ RunPod template updated successfully!"
    echo "📋 Response: $response_body"
    
    # Parse and display template info if successful
    if echo "$response_body" | grep -q '"updateTemplate"'; then
        echo "🎉 Template update confirmed"
    fi
else
    echo "❌ Failed to update RunPod template"
    echo "📋 Response: $response_body"
    exit 1
fi

echo "🎉 RunPod template update completed!"
