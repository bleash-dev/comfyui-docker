#!/bin/bash
# Main test runner for ComfyUI Docker Model Management System

set -euo pipefail

# Get the directory where this script is located
TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$TEST_ROOT")"

# Source the test framework
source "$TEST_ROOT/test_framework.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored banner
print_banner() {
    local color="$1"
    local title="$2"
    local width=60
    local padding=$(( (width - ${#title}) / 2 ))
    
    printf "${color}"
    printf '=%.0s' $(seq 1 $width)
    printf '\n'
    printf '%*s%s%*s\n' $padding "" "$title" $padding ""
    printf '=%.0s' $(seq 1 $width)
    printf "${NC}\n\n"
}

# Function to run unit tests
run_unit_tests() {
    print_banner "$CYAN" "UNIT TESTS"
    
    local unit_test_dir="$TEST_ROOT/unit"
    local unit_tests_passed=0
    local unit_tests_failed=0
    
    # Check if unit test directory exists
    if [ ! -d "$unit_test_dir" ]; then
        print_color "$YELLOW" "No unit tests directory found: $unit_test_dir"
        return 0
    fi
    
    # Run all unit test files
    for test_file in "$unit_test_dir"/test_*.sh; do
        if [ -f "$test_file" ]; then
            local test_name=$(basename "$test_file" .sh)
            print_color "$BLUE" "Running $test_name..."
            
            if bash "$test_file"; then
                unit_tests_passed=$((unit_tests_passed + 1))
                print_color "$GREEN" "✓ $test_name PASSED"
            else
                unit_tests_failed=$((unit_tests_failed + 1))
                print_color "$RED" "✗ $test_name FAILED"
            fi
            echo ""
        fi
    done
    
    # Print unit test summary
    print_color "$BLUE" "Unit Test Summary:"
    print_color "$GREEN" "  Passed: $unit_tests_passed"
    print_color "$RED" "  Failed: $unit_tests_failed"
    echo ""
    
    return $unit_tests_failed
}

# Function to run integration tests
run_integration_tests() {
    print_banner "$CYAN" "INTEGRATION TESTS"
    
    local integration_test_dir="$TEST_ROOT/integration"
    local integration_tests_passed=0
    local integration_tests_failed=0
    
    # Check if integration test directory exists
    if [ ! -d "$integration_test_dir" ]; then
        print_color "$YELLOW" "No integration tests directory found: $integration_test_dir"
        return 0
    fi
    
    # Run all integration test files
    for test_file in "$integration_test_dir"/test_*.sh; do
        if [ -f "$test_file" ]; then
            local test_name=$(basename "$test_file" .sh)
            print_color "$BLUE" "Running $test_name..."
            
            if bash "$test_file"; then
                integration_tests_passed=$((integration_tests_passed + 1))
                print_color "$GREEN" "✓ $test_name PASSED"
            else
                integration_tests_failed=$((integration_tests_failed + 1))
                print_color "$RED" "✗ $test_name FAILED"
            fi
            echo ""
        fi
    done
    
    # Print integration test summary
    print_color "$BLUE" "Integration Test Summary:"
    print_color "$GREEN" "  Passed: $integration_tests_passed"
    print_color "$RED" "  Failed: $integration_tests_failed"
    echo ""
    
    return $integration_tests_failed
}

# Function to check prerequisites
check_prerequisites() {
    print_color "$BLUE" "Checking prerequisites..."
    
    local missing_tools=()
    
    # Check for required tools
    if ! command -v jq >/dev/null 2>&1; then
        missing_tools+=("jq")
    fi
    
    if ! command -v md5sum >/dev/null 2>&1 && ! command -v md5 >/dev/null 2>&1; then
        missing_tools+=("md5sum or md5")
    fi
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_color "$RED" "Missing required tools:"
        for tool in "${missing_tools[@]}"; do
            print_color "$RED" "  - $tool"
        done
        echo ""
        print_color "$YELLOW" "Please install the missing tools and try again."
        return 1
    fi
    
    print_color "$GREEN" "✓ All prerequisites met"
    echo ""
    return 0
}

# Function to print usage
print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -u, --unit           Run only unit tests"
    echo "  -i, --integration    Run only integration tests"
    echo "  -v, --verbose        Enable verbose output"
    echo "  -c, --clean          Clean up test artifacts before running"
    echo "  -h, --help           Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                   Run all tests"
    echo "  $0 -u                Run only unit tests"
    echo "  $0 -i                Run only integration tests"
    echo "  $0 -v                Run all tests with verbose output"
    echo "  $0 -c -u             Clean and run unit tests"
}

# Function to clean test artifacts
clean_test_artifacts() {
    print_color "$BLUE" "Cleaning test artifacts..."
    
    # Remove any existing test temp directories
    rm -rf /tmp/comfyui_test_*
    
    # Clean up any test logs
    rm -f "$TEST_ROOT"/*.log
    
    print_color "$GREEN" "✓ Test artifacts cleaned"
    echo ""
}

# Function to generate test report
generate_test_report() {
    local total_passed="$1"
    local total_failed="$2"
    local total_tests=$((total_passed + total_failed))
    
    print_banner "$BLUE" "FINAL TEST REPORT"
    
    echo "Test Execution Summary:"
    echo "  Total Tests: $total_tests"
    print_color "$GREEN" "  Tests Passed: $total_passed"
    print_color "$RED" "  Tests Failed: $total_failed"
    
    if [ "$total_failed" -eq 0 ]; then
        print_color "$GREEN" "  Overall Result: SUCCESS 🎉"
        echo ""
        print_color "$GREEN" "All tests passed! The model management system is working correctly."
    else
        print_color "$RED" "  Overall Result: FAILURE ❌"
        echo ""
        print_color "$RED" "Some tests failed. Please review the output above for details."
        
        # Provide helpful information
        echo ""
        print_color "$YELLOW" "Troubleshooting tips:"
        print_color "$YELLOW" "1. Check that all required dependencies are installed"
        print_color "$YELLOW" "2. Ensure you have sufficient disk space in /tmp"
        print_color "$YELLOW" "3. Verify that the scripts directory contains the latest versions"
        print_color "$YELLOW" "4. Run with -v flag for more detailed output"
    fi
    
    echo ""
    
    # Return appropriate exit code
    return $total_failed
}

# Main function
main() {
    local run_unit_tests=true
    local run_integration_tests=true
    local verbose=false
    local clean=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--unit)
                run_unit_tests=true
                run_integration_tests=false
                shift
                ;;
            -i|--integration)
                run_unit_tests=false
                run_integration_tests=true
                shift
                ;;
            -v|--verbose)
                verbose=true
                shift
                ;;
            -c|--clean)
                clean=true
                shift
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                print_color "$RED" "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
    
    # Print header
    print_banner "$BLUE" "ComfyUI Docker Model Management Tests"
    
    # Check prerequisites
    if ! check_prerequisites; then
        exit 1
    fi
    
    # Clean artifacts if requested
    if [ "$clean" = true ]; then
        clean_test_artifacts
    fi
    
    # Set verbose mode
    if [ "$verbose" = true ]; then
        set -x
    fi
    
    # Track overall results
    local total_passed=0
    local total_failed=0
    
    # Run unit tests
    if [ "$run_unit_tests" = true ]; then
        if run_unit_tests; then
            unit_failed=0
        else
            unit_failed=$?
        fi
        total_failed=$((total_failed + unit_failed))
        
        # Count actual unit test passes (this is a simplification)
        if [ "$unit_failed" -eq 0 ]; then
            total_passed=$((total_passed + 1))
        fi
    fi
    
    # Run integration tests
    if [ "$run_integration_tests" = true ]; then
        if run_integration_tests; then
            integration_failed=0
        else
            integration_failed=$?
        fi
        total_failed=$((total_failed + integration_failed))
        
        # Count actual integration test passes (this is a simplification)
        if [ "$integration_failed" -eq 0 ]; then
            total_passed=$((total_passed + 1))
        fi
    fi
    
    # Generate final report
    generate_test_report "$total_passed" "$total_failed"
}

# Run main function with all arguments
main "$@"
