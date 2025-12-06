FROM docker.io/ubuntu:24.04
WORKDIR /usr/agent
RUN apt-get update && apt-get install -y curl python3-pip python3-venv git && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://get.docker.com | sh
RUN python3 -m pip install --break-system-packages clearml-agent
COPY entrypoint.sh /usr/agent/entrypoint.sh
RUN chmod +x /usr/agent/entrypoint.sh
ENTRYPOINT ["/usr/agent/entrypoint.sh"]
