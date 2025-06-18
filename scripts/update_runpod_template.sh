#!/bin/bash
set -euo pipefail

echo "🚀 Updating RunPod template..."

# Validate required environment variables
required_vars=("RUNPOD_API_KEY" "RUNPOD_TEMPLATE_ID" "DOCKER_IMAGE_TAG")
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

# Make the API call to update the template
echo "📤 Fetching existing template data..."

# First, get the existing template
fetch_response=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $RUNPOD_API_KEY" \
    -H "Content-Type: application/json" \
    "https://api.runpod.io/graphql" \
    --data-raw '{
        "query": "query { myself { templates { id name imageName containerDiskInGb dockerArgs env { key value } volumeInGb readme } } }"
    }')

fetch_http_code=$(echo "$fetch_response" | tail -n1)
fetch_body=$(echo "$fetch_response" | head -n -1)

if [ "$fetch_http_code" -ne 200 ]; then
    echo "❌ Failed to fetch template data"
    echo "📋 Response: $fetch_body"
    exit 1
fi

# Extract template data using jq or basic parsing
echo "📋 Parsing existing template data..."
template_data=$(echo "$fetch_body" | grep -o '"templates":\[.*\]' | head -n1)

# For now, use default values - you may want to parse the actual template data
echo "📤 Sending update request to RunPod API..."

response=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $RUNPOD_API_KEY" \
    -H "Content-Type: application/json" \
    "https://api.runpod.io/graphql" \
    --data-raw '{
        "query": "mutation saveTemplate($input: SaveTemplateInput!) { saveTemplate(input: $input) { id name imageName } }",
        "variables": {
            "input": {
                "id": "'$RUNPOD_TEMPLATE_ID'",
                "imageName": "'$DOCKER_IMAGE_TAG'",
                "name": "ComfyUI Docker Template",
                "containerDiskInGb": 10,
                "dockerArgs": "",
                "env": [],
                "volumeInGb": 20,
                "readme": "Updated ComfyUI Docker template"
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
    if echo "$response_body" | grep -q '"saveTemplate"'; then
        echo "🎉 Template update confirmed"
    fi
else
    echo "❌ Failed to update RunPod template"
    echo "📋 Response: $response_body"
    exit 1
fi

echo "🎉 RunPod template update completed!"
