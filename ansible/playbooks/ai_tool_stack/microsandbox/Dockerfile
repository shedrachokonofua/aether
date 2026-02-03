ARG DEBIAN_VERSION=13.2-slim
FROM debian:${DEBIAN_VERSION}

ARG DEBIAN_FRONTEND=noninteractive
ARG MICROSANDBOX_VERSION
ARG TARGETARCH

RUN apt update && \
    apt install -y --no-install-recommends \
    ca-certificates \
    curl \
    perl && \
    apt clean && \
    rm -rf /var/lib/apt/lists/*

# Install microsandbox using the official install script
RUN VERSION="${MICROSANDBOX_VERSION:-}" && \
    curl -fsSL https://raw.githubusercontent.com/zerocore-ai/microsandbox/refs/heads/main/scripts/install_microsandbox.sh | sh && \
    ln -sf /root/.local/bin/msb /usr/local/bin/msb && \
    ln -sf /root/.local/bin/server /usr/local/bin/server

# Setup directories for root user
RUN mkdir -p /root/.local/bin /root/.local/lib /root/.microsandbox

# Set up environment variables
ENV PATH="/root/.local/bin:/usr/local/bin:${PATH}"
ENV LD_LIBRARY_PATH="/root/.local/lib:/usr/local/lib:${LD_LIBRARY_PATH}"
ENV HOME="/root"

WORKDIR /workspace

# Pre-pull common sandbox images
ARG MICROSANDBOX_AUTO_PULL_IMAGES=true
RUN if [ "${MICROSANDBOX_AUTO_PULL_IMAGES}" = "true" ]; then \
        msb pull microsandbox/python && \
        msb pull microsandbox/node; \
    fi

VOLUME [ "/root/.microsandbox/namespaces" ]

ENTRYPOINT ["/usr/local/bin/msb"]
CMD ["server", "start", "--host", "0.0.0.0", "--port", "5555"]
