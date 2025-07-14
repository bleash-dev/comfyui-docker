#!/bin/bash
# Create API client and model configuration management scripts

# Get the target directory from the first argument
TARGET_DIR="${1:-$NETWORK_VOLUME/scripts}"
mkdir -p "$TARGET_DIR"

echo "📝 Creating API client and model configuration management scripts..."

# Create the HTTP API client with HMAC authentication
cat > "$TARGET_DIR/api_client.sh" << 'EOF'
#!/bin/bash
# HTTP API Client with HMAC authentication for ComfyUI pod communication

# API configuration
API_BASE_URL="${API_BASE_URL:-https://your-api.com}"
WEBHOOK_SECRET_KEY="${WEBHOOK_SECRET_KEY:-}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-30}"

# Logging
API_CLIENT_LOG="$NETWORK_VOLUME/.api_client.log"

# Ensure log file exists
mkdir -p "$(dirname "$API_CLIENT_LOG")"
touch "$API_CLIENT_LOG"

# Function to log API client activities
log_api_activity() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] API Client: $message" | tee -a "$API_CLIENT_LOG" >&2
}

# Function to generate HMAC signature
generate_hmac_signature() {
    local payload="$1"

    if [ -z "$WEBHOOK_SECRET_KEY" ]; then
        log_api_activity "WARN" "WEBHOOK_SECRET_KEY environment variable is not set"
        return 1
    fi

    if ! command -v openssl >/dev/null 2>&1; then
        log_api_activity "ERROR" "openssl command not found"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        log_api_activity "ERROR" "jq is required to compact JSON for HMAC"
        return 1
    fi

    local compact_json
    compact_json=$(echo "$payload" | jq -c .)
    
    echo -n "$compact_json" | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET_KEY" | awk '{print $2}'
}

# Function to make authenticated API requests
make_api_request() {
    local method="$1"
    local endpoint="$2"
    local payload="$3"
    local response_file="$4"
    
    # Default response file if not provided
    if [ -z "$response_file" ]; then
        response_file=$(mktemp)
    fi
    
    # Build full URL
    local full_url="${API_BASE_URL}${endpoint}"
    
    # Prepare headers
    local headers=()
    headers+=("-H" "Content-Type: application/json")
    headers+=("-H" "User-Agent: ComfyUI-Pod-Client/1.0")
    
    # Add timestamp to payload if it's JSON
    if [ -n "$payload" ] && echo "$payload" | jq empty 2>/dev/null; then
        # Add timestamp to existing JSON
        payload=$(echo "$payload" | jq ". + {\"timestamp\": $(date +%s)}")
    elif [ -n "$payload" ]; then
        # Wrap non-JSON payload in JSON with timestamp
        payload="{\"data\": \"$payload\", \"timestamp\": $(date +%s)}"
    else
        # Create minimal JSON with timestamp
        payload="{\"timestamp\": $(date +%s)}"
    fi
    
    # Generate HMAC signature if secret key is available
    if [ -n "$WEBHOOK_SECRET_KEY" ]; then
        local signature
        signature=$(generate_hmac_signature "$payload")
        if [ $? -eq 0 ] && [ -n "$signature" ]; then
            headers+=("-H" "X-Signature: $signature")
            log_api_activity "DEBUG" "HMAC signature generated for request"
        else
            log_api_activity "WARN" "Failed to generate HMAC signature"
        fi
    fi
    
    log_api_activity "INFO" "Making $method request to $endpoint"
    log_api_activity "DEBUG" "Request payload: $payload"
    
    # Make the request
    local http_code
    local curl_exit_code
    
    if [ "$method" = "GET" ]; then
        http_code=$(curl -s -w "%{http_code}" \
            "${headers[@]}" \
            --max-time "$REQUEST_TIMEOUT" \
            --connect-timeout 10 \
            -o "$response_file" \
            "$full_url")
        curl_exit_code=$?
    else
        http_code=$(curl -s -w "%{http_code}" \
            -X "$method" \
            "${headers[@]}" \
            --max-time "$REQUEST_TIMEOUT" \
            --connect-timeout 10 \
            --data-raw "$payload" \
            -o "$response_file" \
            "$full_url")
        curl_exit_code=$?
    fi
    
    # Check curl execution
    if [ $curl_exit_code -ne 0 ]; then
        log_api_activity "ERROR" "Curl failed with exit code $curl_exit_code for $endpoint"
        echo "CURL_ERROR:$curl_exit_code" >&2
        return 1
    fi
    
    # Log response
    log_api_activity "INFO" "$method $endpoint completed with HTTP $http_code"
    if [ -f "$response_file" ] && [ -s "$response_file" ]; then
        log_api_activity "DEBUG" "Response: $(cat "$response_file")"
    fi
    
    # Return HTTP status code - ensure only this goes to stdout
    # Use printf to avoid any potential newline issues
    printf "%s\n" "$http_code"
    return 0
}

# Function to send sync progress notification
notify_sync_progress() {
    local sync_type="$1"
    local status="$2"      # PROGRESS | DONE | FAILED
    local percentage="$3"  # 0-100
    
    if [ -z "$POD_ID" ] || [ -z "$POD_USER_NAME" ]; then
        log_api_activity "ERROR" "POD_ID or POD_USER_NAME not set for sync progress notification"
        return 1
    fi
    
    local payload
    payload=$(jq -n \
        --arg userId "$POD_USER_NAME" \
        --arg sync_type "$sync_type" \
        --arg status "$status" \
        --argjson percentage "${percentage:-0}" \
        '{
            userId: $userId,
            sync_type: $sync_type,
            status: $status,
            percentage: $percentage
        }')
    
    local response_file
    response_file=$(mktemp)
    
    local http_code
    http_code=$(make_api_request "POST" "/pods/$POD_ID/sync-progress" "$payload" "$response_file")
    
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        log_api_activity "INFO" "Sync progress notification sent successfully: $sync_type $status $percentage%"
        rm -f "$response_file"
        return 0
    else
        log_api_activity "ERROR" "Failed to send sync progress notification: HTTP $http_code"
        rm -f "$response_file"
        return 1
    fi
}

# Function to check if model can be synced
check_model_sync_permission() {
    local s3_path="$1"
    local download_url="$2"
    local destination_group="$3"
    local model_size="$4"
    local response_file="$5"
    
    if [ -z "$POD_ID" ] || [ -z "$POD_USER_NAME" ]; then
        log_api_activity "ERROR" "POD_ID or POD_USER_NAME not set for model sync check"
        return 1
    fi
    
    # Default response file if not provided
    if [ -z "$response_file" ]; then
        response_file=$(mktemp)
    fi
    
    local payload
    payload=$(jq -n \
        --arg s3Path "$s3_path" \
        --arg downloadUrl "$download_url" \
        --arg destinationGroup "$destination_group" \
        --argjson size "${model_size:-0}" \
        --arg podId "$POD_ID" \
        --arg userId "$POD_USER_NAME" \
        '{
            s3Path: $s3Path,
            downloadUrl: $downloadUrl,
            destinationGroup: $destinationGroup,
            size: $size,
            podId: $podId,
            userId: $userId
        }')
    
    local http_code
    http_code=$(make_api_request "POST" "/pods/can-sync-model" "$payload" "$response_file")
    
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        log_api_activity "INFO" "Model sync permission check successful for $destination_group"
        # Response file contains the API response for caller to process
        echo "$http_code"
        return 0
    else
        log_api_activity "ERROR" "Failed to check model sync permission: HTTP $http_code"
        echo "$http_code"
        return 1
    fi
}

# Function to test API connectivity
test_api_connectivity() {
    log_api_activity "INFO" "Testing API connectivity to $API_BASE_URL"
    
    local response_file
    response_file=$(mktemp)
    
    # Try a simple health check or ping endpoint
    local http_code
    http_code=$(make_api_request "GET" "/health" "" "$response_file")
    
    rm -f "$response_file"
    
    if [[ "$http_code" =~ ^[2-4][0-9][0-9]$ ]]; then
        log_api_activity "INFO" "API connectivity test successful (HTTP $http_code)"
        return 0
    else
        log_api_activity "ERROR" "API connectivity test failed (HTTP $http_code)"
        return 1
    fi
}

# Allow script to be sourced or called directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Called directly, show usage
    echo "🌐 ComfyUI API Client"
    echo "===================="
    echo ""
    echo "This script provides HTTP API client functions with HMAC authentication."
    echo "Source this script in other scripts to use the functions:"
    echo ""
    echo "Functions available:"
    echo "  make_api_request <method> <endpoint> <payload> [response_file]"
    echo "  notify_sync_progress <sync_type> <status> <percentage>"
    echo "  check_model_sync_permission <s3_path> <download_url> <destination_group> <size> [response_file]"
    echo "  test_api_connectivity"
    echo ""
    echo "Environment variables:"
    echo "  API_BASE_URL: Base URL for API (default: https://your-api.com)"
    echo "  WEBHOOK_SECRET_KEY: Secret key for HMAC signatures"
    echo "  POD_ID: Pod identifier"
    echo "  POD_USER_NAME: Pod user name"
    echo ""
    echo "Example usage:"
    echo "  source \"\$NETWORK_VOLUME/scripts/api_client.sh\""
    echo "  notify_sync_progress \"user_data\" \"PROGRESS\" 50"
    echo ""
    echo "Current configuration:"
    echo "  API Base URL: $API_BASE_URL"
    echo "  Pod ID: ${POD_ID:-'Not set'}"
    echo "  Pod User: ${POD_USER_NAME:-'Not set'}"
    echo "  Secret Key: ${WEBHOOK_SECRET_KEY:+'Set (hidden)' || 'Not set'}"
    echo ""
    echo "Testing API connectivity..."
    test_api_connectivity
fi
EOF

chmod +x "$TARGET_DIR/api_client.sh"

echo "✅ API client created at $TARGET_DIR/api_client.sh"
