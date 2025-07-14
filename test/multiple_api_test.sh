#!/bin/bash
# Test multiple concurrent API calls to reproduce contamination issue

source "$(dirname "$0")/test_framework.sh"

# Test multiple API calls to see if they contaminate each other
test_multiple_api_calls_contamination() {
    # Set up test environment
    export NETWORK_VOLUME="/tmp/multi_api_test_$$"
    mkdir -p "$NETWORK_VOLUME/scripts"
    
    # Generate the API client script
    source /Users/gilesfokam/workspace/personal/comfyui-docker/scripts/create_api_client.sh
    source "$NETWORK_VOLUME/scripts/api_client.sh"
    
    # Set up environment
    export POD_ID="42a0519e-2093-451c-9cc3-2cf4ac014890"
    export POD_USER_NAME="94d8d4d8-f071-7095-a150-7cae48d8568c"
    export WEBHOOK_SECRET_KEY="test-secret"
    
    # Mock curl to simulate realistic API responses with some delay
    curl() {
        local args=("$@")
        local response_file=""
        local found_output=false
        local endpoint=""
        
        # Find the response file and endpoint
        for i in "${!args[@]}"; do
            if [ "${args[$i]}" = "-o" ] && [ $((i+1)) -lt ${#args[@]} ]; then
                response_file="${args[$((i+1))]}"
            fi
            # Get the endpoint from the URL
            if [[ "${args[$i]}" == *"/pods/"* ]]; then
                endpoint="${args[$i]}"
            fi
        done
        
        # Simulate network delay
        sleep 0.1
        
        # Create appropriate response based on endpoint
        if [ -n "$response_file" ]; then
            if [[ "$endpoint" == *"/sync-progress"* ]]; then
                cat > "$response_file" << 'EOF'
{"success":true,"message":"Sync progress logged successfully","data":{"podId":"42a0519e-2093-451c-9cc3-2cf4ac014890","sync_type":"global_shared","status":"PROGRESS","percentage":10,"timestamp":"2025-07-13T23:52:51.175Z"},"requestId":"b0932b9c-9473-41f6-933a-d41107e70cef"}
EOF
            elif [[ "$endpoint" == *"/can-sync-model"* ]]; then
                cat > "$response_file" << 'EOF'
{"success":true,"data":{"canSync":false,"reason":"Model already exists at this exact path","action":"reject","existingModel":{"originalS3Path":"pod_sessions/global_shared/models/checkpoints/v1-5-pruned-emaonly-fp16.safetensors","modelName":"v1-5-pruned-emaonly-fp16.safetensors","modelSize":2132696762,"directoryGroup":"checkpoints","uploadedAt":"2025-07-09T21:50:03.000Z","lastUpdated":"2025-07-13T13:11:58.246Z"}},"requestId":"ea53080e-3830-4839-a90d-4fad83b2d7fe"}
EOF
            else
                echo '{"success": true}' > "$response_file"
            fi
        fi
        
        # Return HTTP 200
        echo "200"
    }
    
    log_test "INFO" "Testing multiple concurrent API calls..."
    
    # Test 1: Sequential API calls (like in your real scenario)
    log_test "INFO" "=== Test 1: Sequential API calls ==="
    
    local results=()
    local pids=()
    
    # Make multiple API calls in quick succession (simulating real usage)
    for i in {1..5}; do
        (
            case $((i % 3)) in
                1)
                    result=$(notify_sync_progress "global_shared" "PROGRESS" $((i * 10)))
                    echo "SYNC_PROGRESS_$i:$result:$?"
                    ;;
                2)
                    response_file=$(mktemp)
                    result=$(check_model_sync_permission "s3://bucket/model_$i.safetensors" "https://example.com/model_$i.safetensors" "checkpoints" "1024" "$response_file")
                    echo "MODEL_SYNC_$i:$result:$?"
                    rm -f "$response_file"
                    ;;
                0)
                    response_file=$(mktemp)
                    result=$(make_api_request "POST" "/test_$i" "{\"test\": $i}" "$response_file")
                    echo "GENERIC_$i:$result:$?"
                    rm -f "$response_file"
                    ;;
            esac
        ) &
        pids+=($!)
    done
    
    # Wait for all background processes and collect results
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    
    log_test "INFO" "=== Test 2: Rapid fire API calls ==="
    
    # Test 2: Rapid fire calls without delay
    local contamination_detected=false
    
    for i in {1..10}; do
        local stdout_file=$(mktemp)
        local stderr_file=$(mktemp)
        
        # Capture output separately
        notify_sync_progress "test_$i" "PROGRESS" "$i" > "$stdout_file" 2> "$stderr_file" &
        local pid=$!
        
        # Don't wait - start next call immediately
        if [ $((i % 3)) -eq 0 ]; then
            wait "$pid"
            
            # Check for contamination
            local stdout_content=$(cat "$stdout_file")
            local stderr_content=$(cat "$stderr_file")
            
            # Look for unexpected content in stdout or contaminated HTTP codes
            if [[ "$stdout_content" =~ \[.*\] ]] || [[ "$stdout_content" =~ [^0-9] ]]; then
                log_test "ERROR" "Contamination detected in call $i:"
                log_test "ERROR" "  Stdout: '$stdout_content'"
                contamination_detected=true
            fi
        fi
        
        rm -f "$stdout_file" "$stderr_file"
    done
    
    if [ "$contamination_detected" = "true" ]; then
        log_test "ERROR" "❌ HTTP code contamination detected in multiple API calls"
        return 1
    else
        log_test "INFO" "✅ No contamination detected in multiple API calls"
    fi
    
    # Test 3: Simulate the exact scenario from your logs
    log_test "INFO" "=== Test 3: Simulating exact log scenario ==="
    
    # First call: model sync check
    local model_sync_result
    local response_file=$(mktemp)
    model_sync_result=$(check_model_sync_permission \
        "s3://viral-comm-api-user-sessions-dev/pod_sessions/global_shared/models/checkpoints/v1-5-pruned-emaonly-fp16.safetensors" \
        "s3://viral-comm-api-user-sessions-dev/pod_sessions/global_shared/models/checkpoints/v1-5-pruned-emaonly-fp16.safetensors" \
        "checkpoints" \
        "2132696762" \
        "$response_file")
    
    log_test "INFO" "Model sync result: '$model_sync_result'"
    
    # Second call: sync progress (this is where contamination happened in your logs)
    sleep 0.1  # Small delay like in real usage
    local progress_result
    progress_result=$(notify_sync_progress "global_shared" "PROGRESS" 10)
    local progress_exit_code=$?
    
    log_test "INFO" "Progress result: '$progress_result' (exit code: $progress_exit_code)"
    
    # Check if the progress result is contaminated
    if [[ "$progress_result" =~ [^0-9] ]] || [ -z "$progress_result" ]; then
        log_test "ERROR" "❌ Progress call contaminated: '$progress_result'"
        return 1
    else
        log_test "INFO" "✅ Progress call clean: '$progress_result'"
    fi
    
    rm -f "$response_file"
    
    # Clean up
    rm -rf "$NETWORK_VOLUME"
    
    return 0
}

# Test with stderr/stdout redirection like in your environment
test_multiple_api_calls_with_redirection() {
    log_test "INFO" "Testing API calls with various shell redirections..."
    
    # Set up test environment
    export NETWORK_VOLUME="/tmp/redir_test_$$"
    mkdir -p "$NETWORK_VOLUME/scripts"
    
    # Generate the API client script
    source /Users/gilesfokam/workspace/personal/comfyui-docker/scripts/create_api_client.sh
    source "$NETWORK_VOLUME/scripts/api_client.sh"
    
    export POD_ID="test-pod"
    export POD_USER_NAME="test-user"
    
    # Simple mock
    curl() {
        echo '{"success": true}' > "$response_file" 2>/dev/null
        echo "200"
    }
    
    # Test various redirection scenarios
    local scenarios=(
        "no_redirect"
        "stderr_to_null"
        "stdout_to_null"
        "both_to_null"
    )
    
    for scenario in "${scenarios[@]}"; do
        log_test "INFO" "Testing scenario: $scenario"
        
        local result=""
        local response_file=$(mktemp)
        
        case "$scenario" in
            "no_redirect")
                result=$(make_api_request "POST" "/test" '{}' "$response_file")
                ;;
            "stderr_to_null")
                result=$(make_api_request "POST" "/test" '{}' "$response_file" 2>/dev/null)
                ;;
            "stdout_to_null")
                result=$(make_api_request "POST" "/test" '{}' "$response_file" >/dev/null)
                ;;
            "both_to_null")
                result=$(make_api_request "POST" "/test" '{}' "$response_file" >/dev/null 2>&1)
                ;;
        esac
        
        log_test "INFO" "  Result: '$result'"
        
        if [ "$scenario" != "stdout_to_null" ] && [ "$scenario" != "both_to_null" ]; then
            if [ "$result" = "200" ]; then
                log_test "INFO" "  ✅ Clean result for $scenario"
            else
                log_test "ERROR" "  ❌ Contaminated result for $scenario: '$result'"
            fi
        fi
        
        rm -f "$response_file"
    done
    
    # Clean up
    rm -rf "$NETWORK_VOLUME"
    
    return 0
}

# Run tests
main() {
    print_color "$BLUE" "Testing Multiple API Calls for Contamination"
    print_color "$BLUE" "============================================"
    
    run_test test_multiple_api_calls_contamination "Multiple API Calls Contamination"
    run_test test_multiple_api_calls_with_redirection "API Calls with Shell Redirection"
    
    print_test_summary
}

# Run tests if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
