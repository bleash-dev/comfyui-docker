#!/bin/bash
# Test script for load_local_models and resolve_symlinks functions

set -e

# Test configuration
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$TEST_DIR")/scripts"
NETWORK_VOLUME="${NETWORK_VOLUME:-$TEST_DIR/test_volume}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test results tracking
TESTS_PASSED=0
TESTS_FAILED=0
TOTAL_TESTS=0

echo -e "${BLUE}🧪 Testing load_local_models and resolve_symlinks Functions${NC}"
echo "=============================================================="
echo ""

# Setup test environment
setup_test_environment() {
    echo -e "${BLUE}📋 Setting up test environment...${NC}"
    
    # Clean up and create test volume directory
    rm -rf "$NETWORK_VOLUME"
    mkdir -p "$NETWORK_VOLUME/scripts"
    mkdir -p "$NETWORK_VOLUME/ComfyUI/models/checkpoints"
    mkdir -p "$NETWORK_VOLUME/ComfyUI/models/loras"
    mkdir -p "$NETWORK_VOLUME/ComfyUI/models/controlnet"
    
    # Set required environment variables
    export AWS_BUCKET_NAME="test-bucket"
    
    # Generate the model config manager
    cd "$SCRIPTS_DIR"
    bash create_model_config_manager.sh >/dev/null 2>&1
    
    # Source the model config manager
    if [ ! -f "$NETWORK_VOLUME/scripts/model_config_manager.sh" ]; then
        echo -e "${RED}❌ Model config manager script was not created${NC}"
        exit 1
    fi
    
    source "$NETWORK_VOLUME/scripts/model_config_manager.sh"
    
    echo -e "${GREEN}✅ Test environment setup complete${NC}"
    echo ""
}

# Helper function to run a test
run_test() {
    local test_name="$1"
    local test_function="$2"
    
    echo -e "${YELLOW}🔍 Running: $test_name${NC}"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    if $test_function; then
        echo -e "${GREEN}✅ PASS: $test_name${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}❌ FAIL: $test_name${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    echo ""
}

# Test 1: Setup test data with regular and symlinked models
test_setup_test_data() {
    # Create some test model files
    echo "Test checkpoint model 1" > "$NETWORK_VOLUME/ComfyUI/models/checkpoints/model1.safetensors"
    echo "Test checkpoint model 2" > "$NETWORK_VOLUME/ComfyUI/models/checkpoints/model2.safetensors"
    echo "Test lora model 1" > "$NETWORK_VOLUME/ComfyUI/models/loras/lora1.safetensors"
    echo "Test controlnet model 1" > "$NETWORK_VOLUME/ComfyUI/models/controlnet/control1.safetensors"
    
    # Add regular models to config
    local model1_json='{"modelName": "model1", "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/checkpoints/model1.safetensors", "originalS3Path": "models/checkpoints/model1.safetensors", "modelSize": 100, "downloadUrl": "https://example.com/model1.safetensors"}'
    
    local model2_json='{"modelName": "model2", "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/checkpoints/model2.safetensors", "originalS3Path": "models/checkpoints/model2.safetensors", "modelSize": 200, "downloadUrl": "https://example.com/model2.safetensors"}'
    
    local lora1_json='{"modelName": "lora1", "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/loras/lora1.safetensors", "originalS3Path": "models/loras/lora1.safetensors", "modelSize": 50, "downloadUrl": "https://example.com/lora1.safetensors"}'
    
    local control1_json='{"modelName": "control1", "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/controlnet/control1.safetensors", "originalS3Path": "models/controlnet/control1.safetensors", "modelSize": 300, "downloadUrl": "https://example.com/control1.safetensors"}'
    
    # Add symlinked models to config (pointing to model1 and lora1)
    local symlink1_json='{"modelName": "model1_alias", "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/checkpoints/model1_alias.safetensors", "originalS3Path": "models/checkpoints/model1.safetensors", "modelSize": 100, "symLinkedFrom": "models/checkpoints/model1.safetensors"}'
    
    local symlink2_json='{"modelName": "lora1_copy", "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/loras/lora1_copy.safetensors", "originalS3Path": "models/loras/lora1.safetensors", "modelSize": 50, "symLinkedFrom": "models/loras/lora1.safetensors"}'
    
    # Another symlink to model2 in a different group
    local symlink3_json='{"modelName": "model2_in_controlnet", "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/controlnet/model2_in_controlnet.safetensors", "originalS3Path": "models/checkpoints/model2.safetensors", "modelSize": 200, "symLinkedFrom": "models/checkpoints/model2.safetensors"}'
    
    # Create the models in config
    create_or_update_model "checkpoints" "$model1_json" >/dev/null 2>&1
    create_or_update_model "checkpoints" "$model2_json" >/dev/null 2>&1
    create_or_update_model "loras" "$lora1_json" >/dev/null 2>&1
    create_or_update_model "controlnet" "$control1_json" >/dev/null 2>&1
    
    # Add symlinks
    create_or_update_model "checkpoints" "$symlink1_json" >/dev/null 2>&1
    create_or_update_model "loras" "$symlink2_json" >/dev/null 2>&1
    create_or_update_model "controlnet" "$symlink3_json" >/dev/null 2>&1
    
    return 0
}

# Test 2: Test load_local_models function
test_load_local_models() {
    local output_file
    output_file=$(load_local_models)
    
    if [ $? -ne 0 ] || [ ! -f "$output_file" ]; then
        echo "Failed to load local models"
        return 1
    fi
    
    # Check that we got the right number of local models (should be 4, excluding 3 symlinks)
    local model_count
    model_count=$(jq 'length' "$output_file" 2>/dev/null || echo "0")
    
    if [ "$model_count" -ne 4 ]; then
        echo "Expected 4 local models, got $model_count"
        cat "$output_file"
        rm -f "$output_file"
        return 1
    fi
    
    # Check that none of the returned models have symLinkedFrom field
    local symlink_count
    symlink_count=$(jq '[.[] | select(.symLinkedFrom != null and .symLinkedFrom != "")] | length' "$output_file" 2>/dev/null || echo "0")
    
    if [ "$symlink_count" -ne 0 ]; then
        echo "Found $symlink_count symlinked models in local models result (should be 0)"
        rm -f "$output_file"
        return 1
    fi
    
    # Verify we have the expected models
    local model_names
    model_names=$(jq -r '.[].modelName' "$output_file" | sort)
    local expected_names="control1
lora1
model1
model2"
    
    if [ "$model_names" != "$expected_names" ]; then
        echo "Model names don't match expected"
        echo "Expected: $expected_names"
        echo "Got: $model_names"
        rm -f "$output_file"
        return 1
    fi
    
    rm -f "$output_file"
    return 0
}

# Test 3: Test resolve_symlinks with dry run
test_resolve_symlinks_dry_run() {
    # Test resolving symlinks for model1
    if ! resolve_symlinks "models/checkpoints/model1.safetensors" "model1" "true"; then
        echo "Failed to resolve symlinks in dry run mode"
        return 1
    fi
    
    # Check that no actual symlinks were created
    if [ -L "$NETWORK_VOLUME/ComfyUI/models/checkpoints/model1_alias.safetensors" ]; then
        echo "Symlink was created in dry run mode (should not happen)"
        return 1
    fi
    
    return 0
}

# Test 4: Test resolve_symlinks with actual creation
test_resolve_symlinks_actual() {
    # Test resolving symlinks for model1
    if ! resolve_symlinks "models/checkpoints/model1.safetensors" "model1" "false"; then
        echo "Failed to resolve symlinks"
        return 1
    fi
    
    # Check that the symlink was created
    if [ ! -L "$NETWORK_VOLUME/ComfyUI/models/checkpoints/model1_alias.safetensors" ]; then
        echo "Expected symlink was not created: model1_alias.safetensors"
        return 1
    fi
    
    # Check that the symlink points to the right file
    local target
    target=$(readlink "$NETWORK_VOLUME/ComfyUI/models/checkpoints/model1_alias.safetensors")
    local expected_target="$NETWORK_VOLUME/ComfyUI/models/checkpoints/model1.safetensors"
    
    if [ "$target" != "$expected_target" ]; then
        echo "Symlink target incorrect: expected '$expected_target', got '$target'"
        return 1
    fi
    
    # Check that the symlink content matches the original
    local original_content symlink_content
    original_content=$(cat "$NETWORK_VOLUME/ComfyUI/models/checkpoints/model1.safetensors")
    symlink_content=$(cat "$NETWORK_VOLUME/ComfyUI/models/checkpoints/model1_alias.safetensors")
    
    if [ "$original_content" != "$symlink_content" ]; then
        echo "Symlink content doesn't match original"
        return 1
    fi
    
    return 0
}

# Test 5: Test resolve_symlinks for multiple symlinks to same target
test_resolve_multiple_symlinks() {
    # Resolve symlinks for model2 (should create symlink in controlnet group)
    if ! resolve_symlinks "models/checkpoints/model2.safetensors" "model2" "false"; then
        echo "Failed to resolve symlinks for model2"
        return 1
    fi
    
    # Check that the cross-group symlink was created
    if [ ! -L "$NETWORK_VOLUME/ComfyUI/models/controlnet/model2_in_controlnet.safetensors" ]; then
        echo "Expected cross-group symlink was not created: model2_in_controlnet.safetensors"
        return 1
    fi
    
    # Verify the symlink points to the correct target
    local target
    target=$(readlink "$NETWORK_VOLUME/ComfyUI/models/controlnet/model2_in_controlnet.safetensors")
    local expected_target="$NETWORK_VOLUME/ComfyUI/models/checkpoints/model2.safetensors"
    
    if [ "$target" != "$expected_target" ]; then
        echo "Cross-group symlink target incorrect: expected '$expected_target', got '$target'"
        return 1
    fi
    
    return 0
}

# Test 6: Test resolve_symlinks by model name only
test_resolve_by_model_name() {
    # Resolve symlinks for lora1 by model name only
    if ! resolve_symlinks "" "lora1" "false"; then
        echo "Failed to resolve symlinks by model name only"
        return 1
    fi
    
    # Check that the lora symlink was created
    if [ ! -L "$NETWORK_VOLUME/ComfyUI/models/loras/lora1_copy.safetensors" ]; then
        echo "Expected lora symlink was not created: lora1_copy.safetensors"
        return 1
    fi
    
    # Verify symlink content
    local original_content symlink_content
    original_content=$(cat "$NETWORK_VOLUME/ComfyUI/models/loras/lora1.safetensors")
    symlink_content=$(cat "$NETWORK_VOLUME/ComfyUI/models/loras/lora1_copy.safetensors")
    
    if [ "$original_content" != "$symlink_content" ]; then
        echo "Lora symlink content doesn't match original"
        return 1
    fi
    
    return 0
}

# Test 7: Test error handling for missing targets
test_error_handling() {
    # Create a symlink config for a non-existent target
    local bad_symlink_json='{"modelName": "bad_symlink", "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/checkpoints/bad_symlink.safetensors", "originalS3Path": "models/checkpoints/nonexistent.safetensors", "modelSize": 100, "symLinkedFrom": "models/checkpoints/nonexistent.safetensors"}'
    
    create_or_update_model "checkpoints" "$bad_symlink_json" >/dev/null 2>&1
    
    # Try to resolve symlinks - should handle missing target gracefully
    if resolve_symlinks "models/checkpoints/nonexistent.safetensors" "" "false" >/dev/null 2>&1; then
        # Check that no symlink was created
        if [ -L "$NETWORK_VOLUME/ComfyUI/models/checkpoints/bad_symlink.safetensors" ]; then
            echo "Symlink was created for non-existent target (should not happen)"
            return 1
        fi
        return 0
    else
        # It's okay if it returns error code - what matters is that it doesn't crash
        # and doesn't create bad symlinks
        if [ -L "$NETWORK_VOLUME/ComfyUI/models/checkpoints/bad_symlink.safetensors" ]; then
            echo "Bad symlink was created"
            return 1
        fi
        return 0
    fi
}

# Test 8: Integration test - verify all symlinks work together
test_integration() {
    # Load local models again and verify count hasn't changed
    local output_file
    output_file=$(load_local_models)
    
    if [ $? -ne 0 ] || [ ! -f "$output_file" ]; then
        echo "Failed to load local models in integration test"
        return 1
    fi
    
    local model_count
    model_count=$(jq 'length' "$output_file" 2>/dev/null || echo "0")
    
    # Should still be 4 local models (symlinks don't count)
    if [ "$model_count" -ne 4 ]; then
        echo "Local model count changed unexpectedly: expected 4, got $model_count"
        rm -f "$output_file"
        return 1
    fi
    
    rm -f "$output_file"
    
    # Verify all created symlinks still exist and work
    local symlinks=(
        "$NETWORK_VOLUME/ComfyUI/models/checkpoints/model1_alias.safetensors"
        "$NETWORK_VOLUME/ComfyUI/models/controlnet/model2_in_controlnet.safetensors"
        "$NETWORK_VOLUME/ComfyUI/models/loras/lora1_copy.safetensors"
    )
    
    for symlink in "${symlinks[@]}"; do
        if [ ! -L "$symlink" ]; then
            echo "Symlink missing: $symlink"
            return 1
        fi
        
        if [ ! -f "$symlink" ]; then
            echo "Symlink broken: $symlink"
            return 1
        fi
    done
    
    return 0
}

# Cleanup function
cleanup_test_environment() {
    echo -e "${BLUE}🧹 Cleaning up test environment...${NC}"
    rm -rf "$NETWORK_VOLUME"
    echo -e "${GREEN}✅ Cleanup complete${NC}"
}

# Print test results summary
print_test_summary() {
    echo ""
    echo "=============================================================="
    echo -e "${BLUE}📊 Test Results Summary${NC}"
    echo "=============================================================="
    echo -e "Total Tests: $TOTAL_TESTS"
    echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
    
    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${RED}Failed: $TESTS_FAILED${NC}"
        echo ""
        echo -e "${GREEN}🎉 All tests passed! load_local_models and resolve_symlinks functions work correctly.${NC}"
        return 0
    else
        echo -e "${RED}Failed: $TESTS_FAILED${NC}"
        echo ""
        echo -e "${RED}❌ Some tests failed. Functions may need fixes.${NC}"
        return 1
    fi
}

# Main test execution
main() {
    echo "Starting local models and symlinks function tests..."
    echo "Test directory: $TEST_DIR"
    echo "Scripts directory: $SCRIPTS_DIR"
    echo "Network volume: $NETWORK_VOLUME"
    echo ""
    
    # Setup
    setup_test_environment
    
    # Run all tests
    run_test "Setup Test Data" test_setup_test_data
    run_test "Load Local Models Function" test_load_local_models
    run_test "Resolve Symlinks Dry Run" test_resolve_symlinks_dry_run
    run_test "Resolve Symlinks Actual Creation" test_resolve_symlinks_actual
    run_test "Resolve Multiple Symlinks" test_resolve_multiple_symlinks
    run_test "Resolve Symlinks by Model Name" test_resolve_by_model_name
    run_test "Error Handling for Missing Targets" test_error_handling
    run_test "Integration Test" test_integration
    
    # Cleanup
    cleanup_test_environment
    
    # Print summary and exit with appropriate code
    if print_test_summary; then
        exit 0
    else
        exit 1
    fi
}

# Run the tests
main "$@"
