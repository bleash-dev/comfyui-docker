# Specify platform to avoid ARM-related issues
FROM --platform=linux/amd64 nvidia/cuda:11.8.0-runtime-ubuntu22.04

# Build arguments for version control
ARG PYTHON_VERSION=3.10
ARG PYTORCH_VERSION=2.4.0
ARG COMFYUI_VERSION=master

# Environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHON_VERSION=${PYTHON_VERSION} \
    PYTORCH_VERSION=${PYTORCH_VERSION} \
    XPU_TARGET=NVIDIA_GPU

# Create virtual environment paths (these will be updated at runtime)
ENV VENV_DIR=/opt/venv
ENV COMFYUI_VENV=$VENV_DIR/comfyui
ENV JUPYTER_VENV=$VENV_DIR/jupyter

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    python${PYTHON_VERSION} \
    python${PYTHON_VERSION}-venv \
    python3-pip \
    wget \
    nano \
    curl \
    libgl1-mesa-glx \
    libglib2.0-0 \
    libxrandr-dev \
    libxinerama-dev \
    libxcursor-dev \
    libxi-dev \
    libgl1-mesa-dev \
    libglu1-mesa-dev \
    ffmpeg \
    libsm6 \
    libxext6 \
    tree \
    # fuse3 \
    # libfuse3-3 \
    # libfuse3-dev \
    # fuse \
    # unzip \
    # ca-certificates \
    # inotify-tools \
    && rm -rf /var/lib/apt/lists/*

# Configure FUSE for non-root access
RUN echo "user_allow_other" >> /etc/fuse.conf && \
    chmod a+r /etc/fuse.conf && \
    groupadd -f fuse && \
    usermod -a -G fuse root

# Install rclone
RUN curl -O https://downloads.rclone.org/rclone-current-linux-amd64.zip && \
    unzip rclone-current-linux-amd64.zip && \
    cd rclone-*-linux-amd64 && \
    cp rclone /usr/bin/ && \
    chown root:root /usr/bin/rclone && \
    chmod 755 /usr/bin/rclone && \
    cd .. && \
    rm -rf rclone-*

# Create FUSE mount points and set permissions
RUN mkdir -p /tmp/fuse_mounts && \
    chmod 777 /tmp/fuse_mounts

# Set up workspace
WORKDIR /workspace

# Copy scripts directory
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

# Copy the main start script
COPY scripts/start.sh /start.sh
RUN chmod +x /start.sh

# Expose ports
EXPOSE 3000 8888

# Add healthcheck that also verifies FUSE availability
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:3000 || exit 1

# Set default command - explicitly use bash with FUSE support
CMD ["/bin/bash", "/start.sh"]