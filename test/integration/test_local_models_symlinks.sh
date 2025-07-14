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
NC='\033[0m'

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
    
    # Clean up any existing test volume
    rm -rf "$NETWORK_VOLUME"
    mkdir -p "$NETWORK_VOLUME/scripts"
    mkdir -p "$NETWORK_VOLUME/ComfyUI/models/checkpoints"
    mkdir -p "$NETWORK_VOLUME/ComfyUI/models/loras"
    mkdir -p "$NETWORK_VOLUME/ComfyUI/models/embeddings"
    
    # Set environment variables
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

# Test 1: Setup test data with mixed model types
test_setup_mixed_data() {
    echo "Setting up test data with local models and symlinks..."
    
    # Create some test files
    echo "test data 1" > "$NETWORK_VOLUME/ComfyUI/models/checkpoints/local_model_1.safetensors"
    echo "test data 2" > "$NETWORK_VOLUME/ComfyUI/models/loras/target_model.safetensors"
    echo "test data 3" > "$NETWORK_VOLUME/ComfyUI/models/embeddings/embedding_1.safetensors"
    
    # Add local models (no symLinkedFrom field)
    local model1_json='{
        "modelName": "local_model_1",
        "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/checkpoints/local_model_1.safetensors",
        "originalS3Path": "models/checkpoints/local_model_1.safetensors",
        "modelSize": 1024,
        "downloadUrl": "https://example.com/local_model_1.safetensors"
    }'
    
    local model2_json='{
        "modelName": "target_model",
        "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/loras/target_model.safetensors",
        "originalS3Path": "models/loras/target_model.safetensors",
        "modelSize": 2048,
        "downloadUrl": "https://example.com/target_model.safetensors"
    }'
    
    local model3_json='{
        "modelName": "embedding_1",
        "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/embeddings/embedding_1.safetensors",
        "originalS3Path": "models/embeddings/embedding_1.safetensors",
        "modelSize": 512,
        "downloadUrl": "https://example.com/embedding_1.safetensors"
    }'
    
    # Add symlinked models (with symLinkedFrom field)
    local symlink1_json='{
        "modelName": "symlink_to_target",
        "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/checkpoints/symlink_to_target.safetensors",
        "originalS3Path": "models/loras/target_model.safetensors",
        "symLinkedFrom": "models/loras/target_model.safetensors",
        "modelSize": 2048
    }'
    
    local symlink2_json='{
        "modelName": "another_symlink",
        "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/embeddings/another_symlink.safetensors",
        "originalS3Path": "models/loras/target_model.safetensors",
        "symLinkedFrom": "models/loras/target_model.safetensors",
        "modelSize": 2048
    }'
    
    # Create the models in config
    create_or_update_model "checkpoints" "$model1_json" || return 1
    create_or_update_model "loras" "$model2_json" || return 1
    create_or_update_model "embeddings" "$model3_json" || return 1
    create_or_update_model "checkpoints" "$symlink1_json" || return 1
    create_or_update_model "embeddings" "$symlink2_json" || return 1
    
    echo "Test data setup complete: 3 local models, 2 symlinks"
    return 0
}

# Test 2: Test load_local_models function
test_load_local_models() {
    local output_file
    output_file=$(mktemp)
    
    echo "Testing load_local_models function..."
    
    # Load local models
    local result_file
    result_file=$(load_local_models "$output_file")
    
    if [ $? -ne 0 ] || [ ! -f "$result_file" ]; then
        echo "Failed to load local models"
        rm -f "$output_file"
        return 1
    fi
    
    # Check the results
    local model_count
    model_count=$(jq 'length' "$result_file" 2>/dev/null || echo "0")
    
    if [ "$model_count" -ne 3 ]; then
        echo "Expected 3 local models, got $model_count"
        echo "Results:"
        cat "$result_file"
        rm -f "$result_file"
        return 1
    fi
    
    # Verify that no symlinks are included
    local symlink_count
    symlink_count=$(jq '[.[] | select(.symLinkedFrom != null and .symLinkedFrom != "")] | length' "$result_file" 2>/dev/null || echo "0")
    
    if [ "$symlink_count" -ne 0 ]; then
        echo "Found $symlink_count symlinks in local models (should be 0)"
        rm -f "$result_file"
        return 1
    fi
    
    # Verify model names
    local model_names
    model_names=$(jq -r '[.[].modelName] | sort | join(",")' "$result_file" 2>/dev/null)
    local expected_names="embedding_1,local_model_1,target_model"
    
    if [ "$model_names" != "$expected_names" ]; then
        echo "Expected model names: $expected_names"
        echo "Got model names: $model_names"
        rm -f "$result_file"
        return 1
    fi
    
    # Verify directoryGroup is correctly set
    local groups_valid=true
    while IFS= read -r model; do
        local model_name directory_group
        model_name=$(echo "$model" | jq -r '.modelName')
        directory_group=$(echo "$model" | jq -r '.directoryGroup')
        
        case "$model_name" in
            "local_model_1"|"symlink_to_target")
                if [ "$directory_group" != "checkpoints" ]; then
                    echo "Wrong directoryGroup for $model_name: expected checkpoints, got $directory_group"
                    groups_valid=false
                fi
                ;;
            "target_model")
                if [ "$directory_group" != "loras" ]; then
                    echo "Wrong directoryGroup for $model_name: expected loras, got $directory_group"
                    groups_valid=false
                fi
                ;;
            "embedding_1"|"another_symlink")
                if [ "$directory_group" != "embeddings" ]; then
                    echo "Wrong directoryGroup for $model_name: expected embeddings, got $directory_group"
                    groups_valid=false
                fi
                ;;
        esac
    done < <(jq -c '.[]' "$result_file" 2>/dev/null)
    
    rm -f "$result_file"
    
    if [ "$groups_valid" = "false" ]; then
        return 1
    fi
    
    echo "Successfully loaded $model_count local models (excluding symlinks)"
    return 0
}

# Test 3: Test resolve_symlinks with dry run
test_resolve_symlinks_dry_run() {
    echo "Testing resolve_symlinks function with dry run..."
    
    # Test resolving symlinks for target_model
    if ! resolve_symlinks "models/loras/target_model.safetensors" "target_model" "true"; then
        echo "Failed to resolve symlinks in dry run mode"
        return 1
    fi
    
    # Verify that no actual symlinks were created
    if [ -L "$NETWORK_VOLUME/ComfyUI/models/checkpoints/symlink_to_target.safetensors" ]; then
        echo "Symlink was created in dry run mode (should not happen)"
        return 1
    fi
    
    if [ -L "$NETWORK_VOLUME/ComfyUI/models/embeddings/another_symlink.safetensors" ]; then
        echo "Symlink was created in dry run mode (should not happen)"
        return 1
    fi
    
    echo "Dry run completed successfully (no symlinks created)"
    return 0
}

# Test 4: Test resolve_symlinks with actual creation
test_resolve_symlinks_create() {
    echo "Testing resolve_symlinks function with actual symlink creation..."
    
    # Test resolving symlinks for target_model
    if ! resolve_symlinks "models/loras/target_model.safetensors" "target_model" "false"; then
        echo "Failed to resolve and create symlinks"
        return 1
    fi
    
    # Verify that symlinks were created and point to the correct target
    local target_file="$NETWORK_VOLUME/ComfyUI/models/loras/target_model.safetensors"
    local symlink1="$NETWORK_VOLUME/ComfyUI/models/checkpoints/symlink_to_target.safetensors"
    local symlink2="$NETWORK_VOLUME/ComfyUI/models/embeddings/another_symlink.safetensors"
    
    if [ ! -L "$symlink1" ]; then
        echo "Symlink was not created: $symlink1"
        return 1
    fi
    
    if [ ! -L "$symlink2" ]; then
        echo "Symlink was not created: $symlink2"
        return 1
    fi
    
    # Verify symlink targets
    local symlink1_target symlink2_target
    symlink1_target=$(readlink "$symlink1")
    symlink2_target=$(readlink "$symlink2")
    
    if [ "$symlink1_target" != "$target_file" ]; then
        echo "Symlink1 target incorrect: expected $target_file, got $symlink1_target"
        return 1
    fi
    
    if [ "$symlink2_target" != "$target_file" ]; then
        echo "Symlink2 target incorrect: expected $target_file, got $symlink2_target"
        return 1
    fi
    
    # Verify symlinks work by reading through them
    local content1 content2 target_content
    content1=$(cat "$symlink1" 2>/dev/null || echo "")
    content2=$(cat "$symlink2" 2>/dev/null || echo "")
    target_content=$(cat "$target_file" 2>/dev/null || echo "")
    
    if [ "$content1" != "$target_content" ] || [ "$content2" != "$target_content" ]; then
        echo "Symlink content doesn't match target content"
        return 1
    fi
    
    echo "Successfully created 2 symlinks pointing to target model"
    return 0
}

# Test 5: Test resolve_symlinks with non-existent target
test_resolve_symlinks_missing_target() {
    echo "Testing resolve_symlinks with missing target..."
    
    # Add a symlink config that points to a non-existent target
    local missing_symlink_json='{
        "modelName": "broken_symlink",
        "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/checkpoints/broken_symlink.safetensors",
        "originalS3Path": "models/nonexistent/missing_model.safetensors",
        "symLinkedFrom": "models/nonexistent/missing_model.safetensors",
        "modelSize": 1024
    }'
    
    create_or_update_model "checkpoints" "$missing_symlink_json" || return 1
    
    # Try to resolve symlinks for the missing target
    # This should handle the missing target gracefully
    if resolve_symlinks "models/nonexistent/missing_model.safetensors" "missing_model" "false"; then
        # Check that the broken symlink was not created
        if [ -L "$NETWORK_VOLUME/ComfyUI/models/checkpoints/broken_symlink.safetensors" ]; then
            echo "Symlink was created despite missing target"
            return 1
        fi
        echo "Correctly handled missing target (no symlink created)"
        return 0
    else
        echo "Function returned error for missing target (acceptable behavior)"
        return 0
    fi
}

# Test 6: Test resolve_symlinks with search by model name only
test_resolve_symlinks_by_name() {
    echo "Testing resolve_symlinks by model name only..."
    
    # Remove existing symlinks first
    rm -f "$NETWORK_VOLUME/ComfyUI/models/checkpoints/symlink_to_target.safetensors"
    rm -f "$NETWORK_VOLUME/ComfyUI/models/embeddings/another_symlink.safetensors"
    
    # Test resolving symlinks by model name only
    if ! resolve_symlinks "" "target_model" "false"; then
        echo "Failed to resolve symlinks by model name"
        return 1
    fi
    
    # Verify symlinks were created
    if [ ! -L "$NETWORK_VOLUME/ComfyUI/models/checkpoints/symlink_to_target.safetensors" ]; then
        echo "Symlink was not created when searching by model name"
        return 1
    fi
    
    if [ ! -L "$NETWORK_VOLUME/ComfyUI/models/embeddings/another_symlink.safetensors" ]; then
        echo "Symlink was not created when searching by model name"
        return 1
    fi
    
    echo "Successfully resolved symlinks by model name"
    return 0
}

# Test 7: Test load_local_models with no local models
test_load_local_models_empty() {
    echo "Testing load_local_models with no local models..."
    
    # Create a fresh config with only symlinks
    initialize_model_config
    echo '{}' > "$MODEL_CONFIG_FILE"
    
    # Add only symlinks
    local symlink_json='{
        "modelName": "only_symlink",
        "localPath": "'$NETWORK_VOLUME'/ComfyUI/models/checkpoints/only_symlink.safetensors",
        "originalS3Path": "models/loras/target_model.safetensors",
        "symLinkedFrom": "models/loras/target_model.safetensors",
        "modelSize": 2048
    }'
    
    create_or_update_model "checkpoints" "$symlink_json" || return 1
    
    # Load local models
    local output_file
    output_file=$(mktemp)
    
    local result_file
    result_file=$(load_local_models "$output_file")
    
    if [ $? -ne 0 ] || [ ! -f "$result_file" ]; then
        echo "Function failed when no local models exist"
        rm -f "$output_file"
        return 1
    fi
    
    # Check that no models were returned
    local model_count
    model_count=$(jq 'length' "$result_file" 2>/dev/null || echo "0")
    
    if [ "$model_count" -ne 0 ]; then
        echo "Expected 0 local models, got $model_count"
        cat "$result_file"
        rm -f "$result_file"
        return 1
    fi
    
    rm -f "$result_file"
    echo "Correctly returned 0 local models when only symlinks exist"
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
        echo -e "${GREEN}🎉 All tests passed! load_local_models and resolve_symlinks functions are working correctly.${NC}"
        return 0
    else
        echo -e "${RED}Failed: $TESTS_FAILED${NC}"
        echo ""
        echo -e "${RED}❌ Some tests failed.${NC}"
        return 1
    fi
}

# Main test execution
main() {
    echo "Starting load_local_models and resolve_symlinks test suite..."
    echo "Test directory: $TEST_DIR"
    echo "Scripts directory: $SCRIPTS_DIR"
    echo "Network volume: $NETWORK_VOLUME"
    echo ""
    
    # Setup
    setup_test_environment
    
    # Run all tests
    run_test "Setup Mixed Test Data" test_setup_mixed_data
    run_test "Load Local Models Function" test_load_local_models
    run_test "Resolve Symlinks (Dry Run)" test_resolve_symlinks_dry_run
    run_test "Resolve Symlinks (Create)" test_resolve_symlinks_create
    run_test "Resolve Symlinks (Missing Target)" test_resolve_symlinks_missing_target
    run_test "Resolve Symlinks (By Name Only)" test_resolve_symlinks_by_name
    run_test "Load Local Models (Empty)" test_load_local_models_empty
    
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
