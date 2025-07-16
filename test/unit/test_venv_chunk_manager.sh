#!/bin/bash
# Test script for Virtual Environment Chunk Manager

echo "🧪 Testing Virtual Environment Chunk Manager..."

# Set up environment variables needed for script creation
export NETWORK_VOLUME="/tmp/test_network_volume"
export SCRIPT_DIR="/Users/gilesfokam/workspace/personal/comfyui-docker/scripts"

# Create the network volume directory structure
mkdir -p "$NETWORK_VOLUME/scripts"

# Create the chunk manager script
echo "📝 Creating venv chunk manager script for testing..."
bash "$SCRIPT_DIR/create_venv_chunk_manager.sh"

# Source the created chunk manager
source "$NETWORK_VOLUME/scripts/venv_chunk_manager.sh"

# Create a test environment
TEST_DIR="/tmp/venv_chunk_test_$$"
mkdir -p "$TEST_DIR"

# Create a mock venv structure
MOCK_VENV="$TEST_DIR/mock_venv"
MOCK_SITE_PACKAGES="$MOCK_VENV/lib/python3.10/site-packages"
mkdir -p "$MOCK_SITE_PACKAGES"

echo "📦 Creating mock packages for testing..."

# Create some mock packages
for i in {1..25}; do
    mkdir -p "$MOCK_SITE_PACKAGES/package_${i}"
    echo "# Mock package $i" > "$MOCK_SITE_PACKAGES/package_${i}/__init__.py"
    echo "version = '1.0.$i'" > "$MOCK_SITE_PACKAGES/package_${i}/version.py"
done

# Add some larger packages with subdirectories
for i in {26..30}; do
    mkdir -p "$MOCK_SITE_PACKAGES/large_package_${i}/submodule"
    echo "# Large mock package $i" > "$MOCK_SITE_PACKAGES/large_package_${i}/__init__.py"
    echo "# Submodule" > "$MOCK_SITE_PACKAGES/large_package_${i}/submodule/__init__.py"
    # Add some "data" files
    for j in {1..5}; do
        echo "mock data file $j" > "$MOCK_SITE_PACKAGES/large_package_${i}/data_${j}.txt"
    done
done

echo "✅ Created mock venv with $(find "$MOCK_SITE_PACKAGES" -mindepth 1 -maxdepth 1 | wc -l) packages"

# Test chunking
CHUNKS_DIR="$TEST_DIR/chunks"
echo "🔄 Testing venv chunking..."

# Set environment variables for the chunk manager
export PYTHON_VERSION="3.10"
export VENV_CHUNK_SIZE_MB="1"  # Small chunks for testing
export VENV_MAX_PARALLEL="2"   # Reduce parallelism for testing

if "$NETWORK_VOLUME/scripts/venv_chunk_manager.sh" chunk "$MOCK_VENV" "$CHUNKS_DIR"; then
    echo "✅ Venv chunking successful"
    
    # Count created chunks
    CHUNK_COUNT=$(ls "$CHUNKS_DIR"/venv_chunk_*.tar.gz 2>/dev/null | wc -l)
    echo "📊 Created $CHUNK_COUNT chunks"
    
    if [ "$CHUNK_COUNT" -gt 0 ]; then
        # Test verification
        echo "� Testing chunk verification..."
        if [ -f "$CHUNKS_DIR/venv_chunks.checksums" ]; then
            if "$NETWORK_VOLUME/scripts/venv_chunk_manager.sh" verify "$CHUNKS_DIR" "$CHUNKS_DIR/venv_chunks.checksums"; then
                echo "✅ Chunk verification successful"
            else
                echo "❌ Chunk verification failed"
            fi
        else
            echo "⚠️ No checksum file found, skipping verification"
        fi
        
        # Test restoration
        echo "📦 Testing chunk restoration..."
        RESTORE_VENV="$TEST_DIR/restored_venv"
        mkdir -p "$RESTORE_VENV/lib/python3.10"
        
        if "$NETWORK_VOLUME/scripts/venv_chunk_manager.sh" restore "$CHUNKS_DIR" "$RESTORE_VENV"; then
            echo "✅ Chunk restoration successful"
            
            # Verify restoration
            ORIGINAL_COUNT=30  # We know we created 30 packages
            RESTORED_SITE_PACKAGES="$RESTORE_VENV/lib/python3.10/site-packages"
            if [ -d "$RESTORED_SITE_PACKAGES" ]; then
                RESTORED_COUNT=$(find "$RESTORED_SITE_PACKAGES" -mindepth 1 -maxdepth 1 | wc -l)
                
                if [ "$ORIGINAL_COUNT" -eq "$RESTORED_COUNT" ]; then
                    echo "✅ Package count verification passed: $ORIGINAL_COUNT packages"
                else
                    echo "❌ Package count mismatch: Original=$ORIGINAL_COUNT, Restored=$RESTORED_COUNT"
                fi
            else
                echo "❌ Restored site-packages directory not found"
            fi
        else
            echo "❌ Chunk restoration failed"
        fi
    else
        echo "❌ No chunks were created"
    fi
else
    echo "❌ Venv chunking failed"
fi

# Cleanup
echo "🧹 Cleaning up test environment..."
rm -rf "$TEST_DIR"

echo "🧪 Venv chunk manager test completed"
