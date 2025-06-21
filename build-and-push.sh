#!/bin/bash

# Configuration - GitHub Container Registry (Organization)
REGISTRY="ghcr.io/bleash-dev"  # Replace with your GitHub organization name
IMAGE_NAME="comfyui-docker"
TAG="latest"
FULL_IMAGE_NAME="$REGISTRY/$IMAGE_NAME:$TAG"

echo "🔨 Building Docker image: $FULL_IMAGE_NAME"
echo "📦 This image will be owned by the organization: bleash-dev"

# Check if we're in a git repository and get the current branch
if git rev-parse --git-dir > /dev/null 2>&1; then
    CURRENT_BRANCH=$(git branch --show-current)
    echo "📍 Current branch: $CURRENT_BRANCH"
    
    if [ "$CURRENT_BRANCH" = "main" ]; then
        echo "⚠️  You're on the main branch. Consider pushing to trigger GitHub Actions instead."
        echo "   GitHub Actions will automatically build and push on push to main."
        read -p "Continue with manual build? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "❌ Build cancelled"
            exit 0
        fi
    fi
fi

# Login to GitHub Container Registry
echo "🔐 Logging into GitHub Container Registry..."
echo "📋 You'll need a GitHub Personal Access Token (PAT):"
echo "   1. Go to GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)"
echo "   2. Click 'Generate new token (classic)'"
echo "   3. Select scopes: write:packages, read:packages, delete:packages"
echo "   4. Copy the token and use it as your password when prompted"
echo ""
echo "💡 Username: your-github-username"
echo "💡 Password: paste-your-PAT-token-here"
echo "💡 Make sure your PAT has 'write:packages' permission for the organization"
docker login ghcr.io

# Build the image
docker build -t "$FULL_IMAGE_NAME" .

if [ $? -eq 0 ]; then
    echo "✅ Build successful!"
    echo "🚀 Pushing to registry..."
    
    # Push to registry
    docker push "$FULL_IMAGE_NAME"
    
    if [ $? -eq 0 ]; then
        echo "✅ Push successful!"
        echo ""
        echo "🔒 PRIVATE PACKAGE - Authentication Required"
        echo "   📦 Package URL: https://github.com/orgs/bleash-dev/packages/container/comfyui-docker"
        echo "   🐳 Docker Pull: docker pull $FULL_IMAGE_NAME"
        echo "   🔑 Requires GitHub authentication"
        echo ""
        echo "🎯 How to use this PRIVATE image in RunPod:"
        echo ""
        echo "1️⃣ Create GitHub PAT (Personal Access Token):"
        echo "   - Go to GitHub → Settings → Developer settings → Personal access tokens"
        echo "   - Generate new token (classic) with scope: read:packages"
        echo "   - Copy the token"
        echo ""
        echo "2️⃣ Create RunPod Template:"
        echo "   - Container Image: $FULL_IMAGE_NAME"
        echo "   - Registry Username: your-github-username"
        echo "   - Registry Password: your-pat-token"
        echo "   - Expose HTTP Ports: 8080"
        echo "   - Container Start Command: /start.sh"
        echo ""
        echo "3️⃣ When deploying a pod:"
        echo "   - ✅ Enable 'Network Volume'"
        echo "   - Set Volume Mount Path: /workspace"
        echo "   - This enables full persistence!"
        echo ""
        echo "🧪 Test the image locally (requires auth):"
        echo "   docker login ghcr.io"
        echo "   docker run -p 8080:3000 -p 8888:8888 $FULL_IMAGE_NAME"
        echo ""
        echo "🔍 The startup process:"
        echo "   - Detects RunPod network volume automatically"
        echo "   - Moves virtual environments to persistent storage"
        echo "   - Links all ComfyUI data to network volume"
        echo "   - Installs custom nodes from nodes.txt"
        echo ""
        echo "💡 Pro tip: Push to main branch to trigger automatic builds!"
    else
        echo "❌ Push failed!"
        exit 1
    fi
else
    echo "❌ Build failed!"
    exit 1
fi
