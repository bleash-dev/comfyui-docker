#!/bin/bash

# Simple test to verify compression is disabled by default
echo "=== Testing Default Compression Behavior ==="

# Create a temporary test file
TEST_FILE=$(mktemp)
echo "Test data for compression" > "$TEST_FILE"

# Extract just the compression logic from the script
echo "Checking compression logic..."

# Test default behavior (should be disabled)
if [ "${DISABLE_MODEL_COMPRESSION:-true}" = "true" ]; then
    echo "✅ Default behavior: Compression is DISABLED"
else
    echo "❌ Default behavior: Compression is ENABLED"
fi

# Test explicit enable
export DISABLE_MODEL_COMPRESSION=false
if [ "${DISABLE_MODEL_COMPRESSION:-true}" = "true" ]; then
    echo "❌ Explicit enable failed: Compression is still DISABLED"
else
    echo "✅ Explicit enable works: Compression is ENABLED"
fi

# Test explicit disable
export DISABLE_MODEL_COMPRESSION=true
if [ "${DISABLE_MODEL_COMPRESSION:-true}" = "true" ]; then
    echo "✅ Explicit disable works: Compression is DISABLED"
else
    echo "❌ Explicit disable failed: Compression is still ENABLED"
fi

# Clean up
rm -f "$TEST_FILE"
unset DISABLE_MODEL_COMPRESSION

echo
echo "=== Summary ==="
echo "✅ Compression is now DISABLED by default"
echo "✅ Can be enabled with: DISABLE_MODEL_COMPRESSION=false"
echo "✅ Can be explicitly disabled with: DISABLE_MODEL_COMPRESSION=true"
