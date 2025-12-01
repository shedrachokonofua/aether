# GPU Workstation

This playbook is for configuring the GPU workstation virtual machine. The GPU workstation hosts GPU-accelerated AI/ML services for local inference, image generation, document processing, and MLOps. It is a fedora vm that hosts the following applications deployed as podman quadlets:

- Ollama: Local LLM inference with GPU acceleration
- ComfyUI: Stable Diffusion UI for AI image generation
- SwarmUI: Simplified Stable Diffusion WebUI with ComfyUI backend API integration
- Docling: Document parsing and conversion service
- JupyterLab: Interactive notebook environment with GPU support for ML/AI development
- ClearML: Full MLOps platform for experiment tracking, model training, and serving

This playbook also installs and configures NVIDIA GPU drivers, container runtime support, and CDI configuration for GPU passthrough to containers.

## Usage

```bash
task configure:home:gpu-workstation
```

## Sub-Playbooks

### Setup NVIDIA Drivers

Installs NVIDIA drivers, container toolkit, and configures GPU devices for container access.

```bash
task ansible:playbook -- ./ansible/playbooks/gpu_workstation/nvidia.yml
```

### Deploy Ollama

Deploys Ollama with GPU support and pulls default LLM models.

```bash
task ansible:playbook -- ./ansible/playbooks/gpu_workstation/ollama.yml
```

### Deploy ComfyUI

Deploys ComfyUI for stable diffusion and AI image generation workflows.

```bash
task ansible:playbook -- ./ansible/playbooks/gpu_workstation/comfyui.yml
```

### Deploy Docling

Deploys Docling service for document parsing and conversion with GPU acceleration.

```bash
task ansible:playbook -- ./ansible/playbooks/gpu_workstation/docling.yml
```

### Deploy JupyterLab

Deploys JupyterLab with PyTorch, CUDA support, and GPU acceleration for interactive ML/AI development.

```bash
task ansible:playbook -- ./ansible/playbooks/gpu_workstation/jupyter/site.yml
```

### Deploy SwarmUI

Deploys SwarmUI, a simplified Stable Diffusion WebUI with ComfyUI backend API integration.

```bash
task ansible:playbook -- ./ansible/playbooks/gpu_workstation/swarmui.yml
```

To update SwarmUI, simply rerun the playbook - it will pull the latest changes and rebuild the container.

### Deploy ClearML

Deploys ClearML MLOps platform with GPU-enabled agent for experiment tracking, training orchestration, and model serving.

```bash
task ansible:playbook -- ./ansible/playbooks/gpu_workstation/clearml.yml
```
