FROM alpine:3.21

# Add community repository
RUN echo "@community https://dl-cdn.alpinelinux.org/alpine/v3.21/community" >> /etc/apk/repositories

# Update and install packages including OpenSSH for SSH support
RUN apk update && \
  apk add --no-cache \
  python3 \
  py3-pip \
  ansible@community \
  sops@community \
  age \
  opentofu@community \
  aws-cli \
  openssh \
  ca-certificates \
  groff \
  less && \
  update-ca-certificates && \
  # Clean up
  rm -rf /var/cache/apk/*

# Create and set the workspace directory
RUN mkdir -p /workspaces
WORKDIR /workspaces

# Verify installations, including SSH version
RUN ansible --version && \
  ansible-galaxy --version && \
  tofu version && \
  sops --version && \
  aws --version && \
  age-keygen --version && \
  ssh -V

CMD ["/bin/sh"]
