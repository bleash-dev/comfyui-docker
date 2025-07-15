#!/bin/bash
# Testing Framework for ComfyUI Docker Model Management
# Provides utilities for testing model config manager and sync integration

set -euo pipefail

# Test configuration
TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$TEST_ROOT")"
TEST_DATA_DIR="$TEST_ROOT/fixtures"
TEST_MOCKS_DIR="$TEST_ROOT/mocks"
TEST_TEMP_DIR="/tmp/comfyui_test_$$"
TEST_LOG_FILE="/tmp/comfyui_test_$$.log"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_TEST_NAME=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_color() {
    local color="$1"
    shift
    printf "${color}%s${NC}\n" "$*"
}

# Function to log test activities
log_test() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$TEST_LOG_FILE"
}

# Function to setup test environment
setup_test_env() {
    # Create test temp directory
    mkdir -p "$TEST_TEMP_DIR"
    mkdir -p "$TEST_TEMP_DIR/network_volume"
    mkdir -p "$TEST_TEMP_DIR/network_volume/ComfyUI/models"
    mkdir -p "$TEST_TEMP_DIR/network_volume/ComfyUI/models/checkpoints"
    mkdir -p "$TEST_TEMP_DIR/network_volume/ComfyUI/models/loras"
    mkdir -p "$TEST_TEMP_DIR/network_volume/scripts"
    mkdir -p "$TEST_TEMP_DIR/network_volume/.model_config_locks"
    
    # Source .env file if it exists for environment variables
    if [ -f "$PROJECT_ROOT/.env" ]; then
        set -a  # automatically export all variables
        source "$PROJECT_ROOT/.env"
        set +a  # stop automatically exporting
        log_test "INFO" "Sourced .env file for test environment"
    fi
    
    # Set up test environment variables (override .env for testing)
    export NETWORK_VOLUME="$TEST_TEMP_DIR/network_volume"
    export AWS_DEFAULT_REGION="us-east-1"
    export AWS_BUCKET_NAME="global-test-bucket-ws"  # Force test bucket name
    export POD_ID="test-pod-123"
    export POD_USER_NAME="${POD_USER_NAME:-test-user}"
    export API_BASE_URL="http://localhost:3000"
    export WEBHOOK_SECRET_KEY="test-secret-key"
    
    # Copy scripts to test environment
    cp "$PROJECT_ROOT/scripts/create_model_config_manager.sh" "$TEST_TEMP_DIR/"
    cp "$PROJECT_ROOT/scripts/create_model_sync_integration.sh" "$TEST_TEMP_DIR/"
    
    # Execute the creation scripts to generate the actual scripts
    cd "$TEST_TEMP_DIR"
    bash create_model_config_manager.sh
    bash create_model_sync_integration.sh
    cd - > /dev/null
    
    # Copy mock scripts
    cp "$TEST_MOCKS_DIR"/* "$NETWORK_VOLUME/scripts/" 2>/dev/null || true
    
    log_test "INFO" "Test environment setup completed at $TEST_TEMP_DIR"
}

# Function to cleanup test environment
cleanup_test_env() {
    if [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
        log_test "INFO" "Test environment cleaned up"
    fi
    # Also clean up the log file
    if [ -f "$TEST_LOG_FILE" ]; then
        rm -f "$TEST_LOG_FILE"
    fi
}

# Function to start a test
start_test() {
    local test_name="$1"
    CURRENT_TEST_NAME="$test_name"
    TESTS_RUN=$((TESTS_RUN + 1))
    print_color "$BLUE" "[$TESTS_RUN] Running test: $test_name"
    log_test "INFO" "Starting test: $test_name"
}

# Function to assert a condition
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should be equal}"
    
    if [ "$expected" = "$actual" ]; then
        print_color "$GREEN" "  ✓ PASS: $message"
        log_test "PASS" "$CURRENT_TEST_NAME - $message"
        return 0
    else
        print_color "$RED" "  ✗ FAIL: $message"
        print_color "$RED" "    Expected: '$expected'"
        print_color "$RED" "    Actual: '$actual'"
        log_test "FAIL" "$CURRENT_TEST_NAME - $message (Expected: '$expected', Actual: '$actual')"
        return 1
    fi
}

# Function to assert a condition for inequality
assert_not_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should not be equal}"
    
    if [ "$expected" != "$actual" ]; then
        print_color "$GREEN" "  ✓ PASS: $message"
        log_test "PASS" "$CURRENT_TEST_NAME - $message"
        return 0
    else
        print_color "$RED" "  ✗ FAIL: $message"
        print_color "$RED" "    Both values are: '$expected'"
        log_test "FAIL" "$CURRENT_TEST_NAME - $message (Both values are: '$expected')"
        return 1
    fi
}

# Function to assert a file exists
assert_file_exists() {
    local file_path="$1"
    local message="${2:-File should exist: $file_path}"
    
    if [ -f "$file_path" ]; then
        print_color "$GREEN" "  ✓ PASS: $message"
        log_test "PASS" "$CURRENT_TEST_NAME - $message"
        return 0
    else
        print_color "$RED" "  ✗ FAIL: $message"
        log_test "FAIL" "$CURRENT_TEST_NAME - $message"
        return 1
    fi
}

# Function to assert a file does not exist
assert_file_not_exists() {
    local file_path="$1"
    local message="${2:-File should not exist: $file_path}"
    
    if [ ! -f "$file_path" ]; then
        print_color "$GREEN" "  ✓ PASS: $message"
        log_test "PASS" "$CURRENT_TEST_NAME - $message"
        return 0
    else
        print_color "$RED" "  ✗ FAIL: $message"
        log_test "FAIL" "$CURRENT_TEST_NAME - $message"
        return 1
    fi
}

# Function to assert JSON content
assert_json_equals() {
    local expected_json="$1"
    local actual_json="$2"
    local message="${3:-JSON content should match}"
    
    # Normalize JSON (sort keys, compact format)
    local expected_normalized
    local actual_normalized
    
    expected_normalized=$(echo "$expected_json" | jq -S -c '.' 2>/dev/null || echo "$expected_json")
    actual_normalized=$(echo "$actual_json" | jq -S -c '.' 2>/dev/null || echo "$actual_json")
    
    if [ "$expected_normalized" = "$actual_normalized" ]; then
        print_color "$GREEN" "  ✓ PASS: $message"
        log_test "PASS" "$CURRENT_TEST_NAME - $message"
        return 0
    else
        print_color "$RED" "  ✗ FAIL: $message"
        print_color "$RED" "    Expected JSON: $expected_normalized"
        print_color "$RED" "    Actual JSON: $actual_normalized"
        log_test "FAIL" "$CURRENT_TEST_NAME - $message"
        return 1
    fi
}

# Function to assert command success
assert_command_success() {
    local command="$1"
    local message="${2:-Command should succeed: $command}"
    
    if eval "$command" >/dev/null 2>&1; then
        print_color "$GREEN" "  ✓ PASS: $message"
        log_test "PASS" "$CURRENT_TEST_NAME - $message"
        return 0
    else
        print_color "$RED" "  ✗ FAIL: $message"
        log_test "FAIL" "$CURRENT_TEST_NAME - $message"
        return 1
    fi
}

# Function to assert command failure
assert_command_failure() {
    local command="$1"
    local message="${2:-Command should fail: $command}"
    
    if eval "$command" >/dev/null 2>&1; then
        print_color "$RED" "  ✗ FAIL: $message (command succeeded when it should have failed)"
        log_test "FAIL" "$CURRENT_TEST_NAME - $message (command succeeded when it should have failed)"
        return 1
    else
        print_color "$GREEN" "  ✓ PASS: $message"
        log_test "PASS" "$CURRENT_TEST_NAME - $message"
        return 0
    fi
}

# Function to end a test
end_test() {
    local test_result="$1"
    
    if [ "$test_result" -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        print_color "$GREEN" "  Test passed: $CURRENT_TEST_NAME"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        print_color "$RED" "  Test failed: $CURRENT_TEST_NAME"
    fi
    
    log_test "INFO" "Completed test: $CURRENT_TEST_NAME (Result: $test_result)"
    echo ""
}

# Function to create a test model file
create_test_model_file() {
    local file_path="$1"
    local size_bytes="${2:-1024}"
    
    mkdir -p "$(dirname "$file_path")"
    dd if=/dev/zero of="$file_path" bs=1 count="$size_bytes" 2>/dev/null
}

# Function to create test model config JSON
create_test_model_config() {
    local config_file="$1"
    local config_content="${2:-{}}"
    
    mkdir -p "$(dirname "$config_file")"
    echo "$config_content" > "$config_file"
}

# Function to create test model config from fixture
create_test_model_config_from_fixture() {
    local config_file="$1"
    local fixture_name="$2"
    
    mkdir -p "$(dirname "$config_file")"
    
    # Replace placeholders in fixture file
    sed "s|{{NETWORK_VOLUME}}|$NETWORK_VOLUME|g" "$TEST_DATA_DIR/$fixture_name" > "$config_file"
}

# Function to process test fixtures with placeholder replacement
process_test_fixture() {
    local fixture_file="$1"
    local output_file="$2"
    
    if [ ! -f "$fixture_file" ]; then
        echo "Error: Fixture file $fixture_file not found" >&2
        return 1
    fi
    
    # Replace placeholders and copy to output
    sed "s|{{NETWORK_VOLUME}}|$NETWORK_VOLUME|g" "$fixture_file" > "$output_file"
}

# Function to source model config manager for testing
source_model_config_manager() {
    source "$NETWORK_VOLUME/scripts/model_config_manager.sh"
}

# Function to source model sync integration for testing
source_model_sync_integration() {
    source "$NETWORK_VOLUME/scripts/model_sync_integration.sh"
}

# Function to source model download integration for testing
source_model_download_integration() {
    source "$NETWORK_VOLUME/scripts/model_download_integration.sh"
}

# Function to source the API client for testing
source_api_client() {
    # Source the mock API client
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$script_dir/mocks/api_client.sh"
}

# Function to print test summary
print_test_summary() {
    echo ""
    print_color "$BLUE" "=========================================="
    print_color "$BLUE" "Test Summary"
    print_color "$BLUE" "=========================================="
    echo "Total tests run: $TESTS_RUN"
    print_color "$GREEN" "Tests passed: $TESTS_PASSED"
    
    if [ "$TESTS_FAILED" -gt 0 ]; then
        print_color "$RED" "Tests failed: $TESTS_FAILED"
        print_color "$RED" "Overall result: FAILURE"
        return 1
    else
        print_color "$GREEN" "Tests failed: $TESTS_FAILED"
        print_color "$GREEN" "Overall result: SUCCESS"
        return 0
    fi
}

# Function to run a test safely
run_test() {
    local test_function="$1"
    local test_name="$2"
    
    start_test "$test_name"
    
    # Run test in subshell to contain any failures
    local test_result=0
    (
        set -e
        "$test_function"
    ) || test_result=$?
    
    end_test "$test_result"
    return "$test_result"
}

# Trap to cleanup on exit
trap cleanup_test_env EXIT INT TERM

# Export functions for use in test files
export -f setup_test_env cleanup_test_env start_test end_test run_test
export -f assert_equals assert_not_equals assert_file_exists assert_file_not_exists assert_json_equals
export -f assert_command_success assert_command_failure
export -f create_test_model_file create_test_model_config create_test_model_config_from_fixture
export -f process_test_fixture
export -f source_model_config_manager source_model_sync_integration source_model_download_integration source_model_download_integration
export -f print_test_summary log_test print_color
