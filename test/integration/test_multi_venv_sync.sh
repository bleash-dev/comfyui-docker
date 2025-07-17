#!/bin/bash
# Test script for multi-venv sync functionality

echo "🧪 Testing Multi-Venv Sync Functionality..."

# Set up test environment
export NETWORK_VOLUME="/tmp/test_multi_venv_sync_$$"
export AWS_BUCKET_NAME="test-bucket"
export POD_USER_NAME="test-user"
export POD_ID="test-pod-123"
export SCRIPT_DIR="/Users/gilesfokam/workspace/personal/comfyui-docker/scripts"

# Create test directory structure
mkdir -p "$NETWORK_VOLUME/scripts"
mkdir -p "$NETWORK_VOLUME/venv"

echo "📝 Creating test environment..."

# Create multiple mock venvs
create_mock_venv() {
    local venv_name="$1"
    local venv_path="$NETWORK_VOLUME/venv/$venv_name"
    
    mkdir -p "$venv_path/lib/python3.10/site-packages"
    mkdir -p "$venv_path/bin"
    mkdir -p "$venv_path/include"
    
    # Create a mock python executable
    cat > "$venv_path/bin/python" << 'EOF'
#!/bin/bash
echo "Python 3.10.0 (mock)"
EOF
    chmod +x "$venv_path/bin/python"
    
    # Create some mock packages
    for i in {1..5}; do
        mkdir -p "$venv_path/lib/python3.10/site-packages/mock_package_${i}"
        echo "# Mock package $i for $venv_name" > "$venv_path/lib/python3.10/site-packages/mock_package_${i}/__init__.py"
        echo "version = '1.0.$i'" > "$venv_path/lib/python3.10/site-packages/mock_package_${i}/version.py"
    done
    
    # Create some mock files in other directories
    echo "#!/bin/bash" > "$venv_path/bin/activate"
    echo "# Mock activate script for $venv_name" >> "$venv_path/bin/activate"
    chmod +x "$venv_path/bin/activate"
    
    echo "Mock include file for $venv_name" > "$venv_path/include/Python.h"
    
    echo "✅ Created mock venv: $venv_name"
}

# Create multiple test venvs
create_mock_venv "comfyui"
create_mock_venv "jupyter"
create_mock_venv "custom_tools"

# Create necessary scripts
echo "📝 Creating sync scripts..."
bash "$SCRIPT_DIR/create_venv_chunk_manager.sh"
bash "$SCRIPT_DIR/create_sync_lock_manager.sh"
bash "$SCRIPT_DIR/create_api_client.sh"
bash "$SCRIPT_DIR/create_model_sync_integration.sh"

# Source the sync script creation to get the functions
source "$SCRIPT_DIR/create_sync_scripts.sh"

# Test the sync functionality
echo "🔄 Testing sync functionality..."

# Mock AWS S3 commands for testing
export PATH="$NETWORK_VOLUME/scripts:$PATH"
cat > "$NETWORK_VOLUME/scripts/aws" << 'EOF'
#!/bin/bash
# Mock AWS CLI for testing
case "$1" in
    "s3")
        case "$2" in
            "ls")
                echo "Mock S3 listing"
                ;;
            "cp")
                echo "Mock S3 copy: $3 -> $4"
                ;;
            "rm")
                echo "Mock S3 remove: $3"
                ;;
            *)
                echo "Mock AWS S3 command: $*"
                ;;
        esac
        ;;
    *)
        echo "Mock AWS command: $*"
        ;;
esac
EOF
chmod +x "$NETWORK_VOLUME/scripts/aws"

# Test venv discovery
echo "🔍 Testing venv discovery..."
venv_count=$(find "$NETWORK_VOLUME/venv" -mindepth 1 -maxdepth 1 -type d | wc -l)
echo "Found $venv_count venvs:"
for venv_dir in "$NETWORK_VOLUME/venv"/*; do
    if [ -d "$venv_dir" ]; then
        venv_name=$(basename "$venv_dir")
        echo "  - $venv_name"
    fi
done

# Test chunk manager with multiple venvs
echo "🔄 Testing chunk manager with multiple venvs..."
for venv_dir in "$NETWORK_VOLUME/venv"/*; do
    if [ -d "$venv_dir" ]; then
        venv_name=$(basename "$venv_dir")
        echo "Testing $venv_name venv..."
        
        # Test chunking
        chunk_output_dir="$NETWORK_VOLUME/test_chunks_$venv_name"
        mkdir -p "$chunk_output_dir"
        
        if "$NETWORK_VOLUME/scripts/venv_chunk_manager.sh" chunk "$venv_dir" "$chunk_output_dir"; then
            echo "  ✅ Chunking successful for $venv_name"
            
            # Count chunks
            chunk_count=$(ls "$chunk_output_dir"/venv_chunk_*.tar.gz 2>/dev/null | wc -l)
            echo "  📊 Created $chunk_count chunks"
            
            # Test restoration
            restore_output_dir="$NETWORK_VOLUME/test_restore_$venv_name"
            mkdir -p "$restore_output_dir"
            
            if "$NETWORK_VOLUME/scripts/venv_chunk_manager.sh" restore "$chunk_output_dir" "$restore_output_dir"; then
                echo "  ✅ Restoration successful for $venv_name"
                
                # Verify restoration
                if [ -f "$restore_output_dir/bin/python" ]; then
                    echo "  ✅ Python executable restored"
                else
                    echo "  ❌ Python executable missing"
                fi
                
                if [ -d "$restore_output_dir/lib/python3.10/site-packages" ]; then
                    restored_packages=$(find "$restore_output_dir/lib/python3.10/site-packages" -mindepth 1 -maxdepth 1 -type d | wc -l)
                    echo "  📦 $restored_packages packages restored"
                else
                    echo "  ❌ Site-packages directory missing"
                fi
            else
                echo "  ❌ Restoration failed for $venv_name"
            fi
        else
            echo "  ❌ Chunking failed for $venv_name"
        fi
    fi
done

# Test sync script structure
echo "🔄 Testing sync script structure..."
echo "Checking if sync scripts handle multiple venvs correctly..."

# Check if the sync function exists and can handle multiple venvs
if command -v sync_user_shared_data_internal >/dev/null 2>&1; then
    echo "✅ sync_user_shared_data_internal function is available"
else
    echo "❌ sync_user_shared_data_internal function not found"
fi

# Test directory structure after sync
echo "📊 Final directory structure:"
find "$NETWORK_VOLUME" -type d | sort | sed 's|^'"$NETWORK_VOLUME"'|.|'

echo "🧹 Cleaning up test environment..."
rm -rf "$NETWORK_VOLUME"

echo "✅ Multi-venv sync test completed!"
