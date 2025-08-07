    # Set environment variables
    export ENVIRONMENT="dev"
    export REGION="${REGION:-us-east-1}"
    export S3_PREFIX="s3://viral-comm-api-ec2-deployments-dev/comfyui-ami/${ENVIRONMENT}"

    echo "🚀 Starting ComfyUI AMI setup at $(date)"
    echo "Environment: $ENVIRONMENT"
    echo "S3 Prefix: $S3_PREFIX"
    echo "SETUP_STARTING" > /tmp/ami_progress.txt

    # Download scripts from S3
    echo "📥 Downloading scripts from S3..."
    mkdir -p /scripts
    cd /scripts
    aws s3 sync "$S3_PREFIX/" . --region "$REGION"
    chmod +x *.sh 2>/dev/null || true
    chmod +x *.py 2>/dev/null || true

    # Run prepare_ami.sh
    echo "⚙️ Running prepare_ami.sh..."
    echo "RUNNING_PREPARE_AMI" > /tmp/ami_progress.txt
    /scripts/prepare_ami.sh

    # Success signal
    echo "✅ AMI setup completed at $(date)"
    echo "AMI_SETUP_COMPLETE" > /tmp/ami_ready.txt
