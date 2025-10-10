FROM quay.io/jupyter/pytorch-notebook:cuda12-latest

# Switch to root to make system changes
USER root

# Install essential ML/AI packages for beginners
RUN pip install --no-cache-dir \
    # Hugging Face essentials
    transformers \
    datasets \
    tokenizers \
    safetensors \
    # Data science basics
    pandas \
    numpy \
    matplotlib \
    seaborn \
    plotly \
    scikit-learn \
    # Jupyter enhancements
    ipywidgets \
    # Monitoring training
    tensorboard \
    # PyTorch extras
    torchvision \
    torchaudio

# Switch back to default user
USER ${NB_USER}

# Set Jupyter configuration for no authentication
RUN jupyter lab --generate-config && \
    echo "c.ServerApp.token = ''" >> ~/.jupyter/jupyter_lab_config.py && \
    echo "c.ServerApp.password = ''" >> ~/.jupyter/jupyter_lab_config.py && \
    echo "c.ServerApp.open_browser = False" >> ~/.jupyter/jupyter_lab_config.py && \
    echo "c.ServerApp.allow_origin = '*'" >> ~/.jupyter/jupyter_lab_config.py && \
    echo "c.ServerApp.allow_remote_access = True" >> ~/.jupyter/jupyter_lab_config.py && \
    echo "c.ServerApp.ip = '0.0.0.0'" >> ~/.jupyter/jupyter_lab_config.py && \
    echo "c.ServerApp.disable_check_xsrf = True" >> ~/.jupyter/jupyter_lab_config.py && \
    echo "c.ServerApp.trust_xheaders = True" >> ~/.jupyter/jupyter_lab_config.py && \
    echo "c.ServerApp.allow_credentials = True" >> ~/.jupyter/jupyter_lab_config.py

# Expose the Jupyter port
EXPOSE 8888

# Start JupyterLab
CMD ["jupyter", "lab", "--ip=0.0.0.0", "--port=8888", "--no-browser"]
