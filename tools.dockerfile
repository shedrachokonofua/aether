# Stage 1: Get OpenBao binary from official image
FROM ghcr.io/openbao/openbao:2.4.4 AS openbao

# Stage 2: Main toolbox image
FROM alpine:3.23

# Add community repository
RUN echo "@community https://dl-cdn.alpinelinux.org/alpine/v3.23/community" >> /etc/apk/repositories

# Update and install packages including OpenSSH for SSH support
RUN apk update && \
  apk add --no-cache \
  python3 \
  py3-pip \
  py3-boto3 \
  py3-botocore \
  ansible@community \
  sops@community \
  age \
  opentofu@community \
  aws-cli \
  openssh \
  ca-certificates \
  groff \
  less \
  nano \
  yq@community \
  pre-commit@community \
  git \
  curl \
  unzip \
  jq \
  step-cli@community && \
  update-ca-certificates && \
  # Clean up
  rm -rf /var/cache/apk/*

# Install gitleaks from GitHub releases
RUN ARCH=$(uname -m | sed 's/x86_64/x64/' | sed 's/aarch64/arm64/') && \
    curl -sSL "https://github.com/gitleaks/gitleaks/releases/download/v8.18.4/gitleaks_8.18.4_linux_${ARCH}.tar.gz" | tar xz -C /usr/local/bin gitleaks

# Copy OpenBao CLI from official image
COPY --from=openbao /bin/bao /usr/local/bin/bao

# Create and set the workspace directory
RUN mkdir -p /workspaces
WORKDIR /workspaces

# Verify installations
RUN ansible --version && \
  ansible-galaxy --version && \
  tofu version && \
  sops --version && \
  aws --version && \
  age-keygen --version && \
  bao version && \
  ssh -V && \
  step version

CMD ["/bin/sh"]
