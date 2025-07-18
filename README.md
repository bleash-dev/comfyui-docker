# 🎨 ComfyUI Docker Template for RunPod

<div align="center">

<img src="https://pbs.twimg.com/profile_images/1802828693888475136/yuNS4xXR_200x200.jpg" alt="ComfyUI Logo" style="width: 100px; height: 100px; border-radius: 50%;">

### Seamless ComfyUI Deployment on RunPod

[![Sponsored by Dreamshot.io](https://img.shields.io/badge/Sponsored_by-Dreamshot.io-blue?style=for-the-badge)](https://dreamshot.io)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=for-the-badge&logo=docker&logoColor=white)](https://www.docker.com/)

</div>

## 🚀 Quick Start

Get your ComfyUI instance running on RunPod in minutes with this template!

1. Log into your [RunPod account](https://runpod.io?ref=template)
2. Go to the Templates section
3. Click "Add Template"
4. Use the following settings:
   ```
   Container Image: javierjrueda/comfyui-runpod:latest
   Container Disk: 5GB
   ```
5. Click "Deploy"

That's it! Your ComfyUI instance will be automatically set up with all dependencies installed.

## 🌟 Features

- 🔥 **Zero Configuration Required**: All dependencies are automatically installed
- 🔄 **Network Storage Support**: Seamlessly integrate with RunPod's network storage
- 🛠️ **Pre-configured Environment**: Python, CUDA, and all necessary libraries included
- 📁 **Organized Directory Structure**:
  ```
  /workspace/
  └── Comfyui/
      ├── models/
      ├── input/
      ├── output/
      ├── custom_nodes/
      └── [ComfyUI files]
  ```
- 🔌 **Dual Interface**: Access via both Web UI and JupyterLab

## 💾 Using Network Storage

The template automatically detects and configures RunPod network storage. When enabled, it creates the following structure:

```
/runpod-volume/
├── Comfyui/
│   ├── models/         # Store your models
│   ├── input/          # Input images and files
│   ├── output/         # Generated outputs
│   └── custom_nodes/   # Custom node installations
├── venv/
│   ├── comfyui/        # ComfyUI virtual environment
│   └── [other-venvs]/  # Additional virtual environments
└── scripts/            # Sync and management scripts
```

### 🔧 Virtual Environment Management

The template includes advanced virtual environment management:
- **Multi-venv Support**: Supports multiple Python virtual environments
- **Chunked Optimization**: Large venvs are split into optimized chunks for faster sync
- **Automatic Backup**: All venvs are automatically backed up to S3
- **Smart Restoration**: Venvs are intelligently restored from chunked backups on startup
- **Backwards Compatibility**: Seamlessly migrates from legacy single-venv structure

### Creating Additional Virtual Environments

You can create additional virtual environments alongside the default ComfyUI venv:

```bash
# Create a new venv for data science tools
python3 -m venv /runpod-volume/venv/data_science

# Activate and install packages
source /runpod-volume/venv/data_science/bin/activate
pip install pandas numpy scikit-learn

# Create a specialized venv for image processing
python3 -m venv /runpod-volume/venv/image_processing
source /runpod-volume/venv/image_processing/bin/activate
pip install opencv-python pillow imageio

# All venvs will be automatically backed up and restored
```

The sync system will automatically detect and manage all venvs in the `/venv/` directory, using optimized chunked uploads for faster sync times.

## 🔗 Port Configuration

- **ComfyUI Web Interface**: Port 3000
- **JupyterLab**: Port 8888

## 🤝 Contributing

We welcome contributions! Feel free to:
- Submit bug reports
- Suggest new features
- Create pull requests

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Sponsored by [Dreamshot.io](https://dreamshot.io)

## 📞 Support

Need help? Here are your options:
- Create an issue in this repository
- Contact Dreamshot.io support

---

<div align="center">
Made with ❤️ by javierjrueda

[🌟 Star this repo](https://github.com/yourusername/comfyui-runpod-template) | [🐛 Report bug](https://github.com/yourusername/comfyui-runpod-template/issues) | [🤝 Contribute](https://github.com/yourusername/comfyui-runpod-template/pulls)
</div>