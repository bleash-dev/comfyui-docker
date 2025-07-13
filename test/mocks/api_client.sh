#!/bin/bash
# Mock API Client for Testing
# Simulates API responses for model sync testing

# Configuration
API_CLIENT_LOG="$NETWORK_VOLUME/.api_client.log"
MOCK_RESPONSES_DIR="$NETWORK_VOLUME/.mock_responses"

# Ensure directories exist
mkdir -p "$(dirname "$API_CLIENT_LOG")"
mkdir -p "$MOCK_RESPONSES_DIR"
touch "$API_CLIENT_LOG"

# Function to log API activities (mock)
log_api_client() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] API Client (MOCK): $message" | tee -a "$API_CLIENT_LOG" >&2
}

# Mock function to check model sync permission
check_model_sync_permission() {
    local s3_path="$1"
    local download_url="$2"
    local destination_group="$3"
    local model_size="$4"
    local response_file="$5"
    
    log_api_client "INFO" "MOCK: Checking sync permission for $s3_path"
    
    # Create different mock responses based on parameters
    local mock_response=""
    local http_code=200
    
    # Check for test scenarios
    if [[ "$download_url" == *"reject"* ]]; then
        # Simulate rejection
        mock_response='{
            "success": true,
            "data": {
                "canSync": false,
                "action": "reject",
                "reason": "Model already exists at this exact path",
                "existingModel": null
            }
        }'
    elif [[ "$download_url" == *"replace"* ]]; then
        # Simulate replace scenario - extract relative path from s3_path
        local relative_path="${s3_path#s3://global-test-bucket-ws/}"
        mock_response='{
            "success": true,
            "data": {
                "canSync": true,
                "action": "replace",
                "reason": "Newer version available",
                "existingModel": {
                    "originalS3Path": "'$relative_path'",
                    "modelSize": '$((model_size - 100))'
                }
            }
        }'
    elif [[ "$download_url" == *"existing"* ]]; then
        # Simulate existing model scenario - return S3-relative path
        # Since duplicates shouldn't occur within the same group,
        # this simulates a model that exists in a DIFFERENT group
        local s3_relative_path="different-group/existing-model.safetensors"
        mock_response='{
            "success": true,
            "data": {
                "canSync": false,
                "action": "link",
                "reason": "Model already exists with same content in different group",
                "existingModel": {
                    "originalS3Path": "'$s3_relative_path'",
                    "modelSize": '$model_size'
                }
            }
        }'
    elif [[ "$download_url" == *"error"* ]]; then
        # Simulate error
        http_code=500
        mock_response='{
            "success": false,
            "error": "Internal server error"
        }'
    else
        # Default: allow upload
        mock_response='{
            "success": true,
            "data": {
                "canSync": true,
                "action": "upload",
                "reason": "New model, upload allowed",
                "existingModel": null
            }
        }'
    fi
    
    echo "$mock_response" > "$response_file"
    echo "$http_code"
    return 0
}

# Mock function to notify sync progress
notify_sync_progress() {
    local sync_type="$1"
    local status="$2"
    local percentage="$3"
    
    log_api_client "INFO" "MOCK: Progress notification - Type: $sync_type, Status: $status, Progress: $percentage%"
    
    # Simulate successful notification
    return 0
}

# Mock function to generate HMAC signature
generate_hmac_signature() {
    local method="$1"
    local path="$2"
    local body="$3"
    local secret_key="$4"
    
    # Return a mock signature
    echo "mock_signature_$(echo -n "${method}${path}${body}" | md5sum | cut -d' ' -f1)"
}

# Mock function to make API request
make_api_request() {
    local method="$1"
    local endpoint="$2"
    local body="$3"
    local response_file="$4"
    
    log_api_client "INFO" "MOCK: API Request - $method $endpoint"
    
    # Create a generic success response
    echo '{"success": true, "message": "Mock response"}' > "$response_file"
    echo "200"
    return 0
}

# Export functions for testing
export -f check_model_sync_permission notify_sync_progress generate_hmac_signature make_api_request log_api_client
