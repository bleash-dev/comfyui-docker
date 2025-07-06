# Specify platform to avoid ARM-related issues
FROM --platform=linux/amd64 nvidia/cuda:11.8.0-runtime-ubuntu22.04

# Build arguments for version control
ARG PYTHON_VERSION=3.10
ARG PYTORCH_VERSION=2.4.0
ARG COMFYUI_VERSION=master
ARG UBUNTU_VERSION=22.04

# Environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHON_VERSION=${PYTHON_VERSION} \
    PYTORCH_VERSION=${PYTORCH_VERSION} \
    XPU_TARGET=NVIDIA_GPU \
    PATH="/opt/miniconda3/bin:$PATH"

# Create virtual environment paths (these will be updated at runtime)
ENV VENV_DIR=/opt/venv
ENV COMFYUI_VENV=$VENV_DIR/comfyui

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    python${PYTHON_VERSION} \
    python${PYTHON_VERSION}-venv \
    python3-pip \
    wget \
    nano \
    curl \
    openssh-server \
    libgl1-mesa-glx \
    libglib2.0-0 \
    libxrandr-dev \
    libxinerama-dev \
    libxcursor-dev \
    libnss3\                                     
    libatk1.0-0\                                 
    libatk-bridge2.0-0 \
    libcups2 \                  
    libatspi2.0-0\                               
    libxcomposite1\                              
    libxdamage1\
    libxi-dev \
    libgl1-mesa-dev \
    libglu1-mesa-dev \
    ffmpeg \
    libsm6 \
    libxext6 \
    tree \
    zip \
    unzip \
    ca-certificates \
    inotify-tools \
    jq \
    bc \
    && rm -rf /var/lib/apt/lists/*

# Create symbolic links for python commands
RUN ln -sf /usr/bin/python${PYTHON_VERSION} /usr/bin/python3 && \
    ln -sf /usr/bin/python${PYTHON_VERSION} /usr/bin/python

# Install AWS CLI v2
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf awscliv2.zip aws/

# Set up workspace
WORKDIR /workspace

# Copy scripts directory
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

# Copy the main start script
COPY scripts/start.sh /start.sh
RUN chmod +x /start.sh

# Expose ports
EXPOSE 8080

# Add healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080 || exit 1

# Set default command
CMD ["/bin/bash", "/start.sh"]