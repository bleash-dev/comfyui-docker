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

# Create virtual environment paths
ENV VENV_DIR=/opt/venv
ENV COMFYUI_VENV=$VENV_DIR/comfyui
ENV JUPYTER_VENV=$VENV_DIR/jupyter
ENV PATH="$COMFYUI_VENV/bin:$JUPYTER_VENV/bin:$PATH"

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    python${PYTHON_VERSION} \
    python${PYTHON_VERSION}-venv \
    python3-pip \
    wget \
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
    && rm -rf /var/lib/apt/lists/*

# Create virtual environments
RUN python${PYTHON_VERSION} -m venv $COMFYUI_VENV && \
    python${PYTHON_VERSION} -m venv $JUPYTER_VENV

# Set up workspace
WORKDIR /workspace

# Install JupyterLab in its own virtual environment
RUN . $JUPYTER_VENV/bin/activate && \
    pip install --no-cache-dir jupyterlab notebook numpy pandas && \
    jupyter notebook --generate-config && \
    echo "c.NotebookApp.token = ''" >> ~/.jupyter/jupyter_notebook_config.py && \
    echo "c.NotebookApp.password = ''" >> ~/.jupyter/jupyter_notebook_config.py && \
    deactivate

# Set up ComfyUI
WORKDIR /workspace/ComfyUI

# Install ComfyUI and dependencies in its virtual environment
RUN . $COMFYUI_VENV/bin/activate && \
    git clone https://github.com/comfyanonymous/ComfyUI . && \
    if [ "$COMFYUI_VERSION" != "master" ]; then git checkout $COMFYUI_VERSION; fi && \
    pip install --no-cache-dir -r requirements.txt && \
    pip install --no-cache-dir torch==${PYTORCH_VERSION} torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 && \
    deactivate

# Create directory structure
RUN mkdir -p models input output custom_nodes

# Copy scripts directory
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

# Copy the main start script
COPY scripts/start.sh /start.sh
RUN chmod +x /start.sh

# Copy ComfyUI to temp location for potential network volume setup
RUN cp -r /workspace/ComfyUI /tmp/ComfyUI

# Expose ports
EXPOSE 3000 8888

# Add healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:3000 || exit 1

# Set default command
CMD ["/start.sh"]