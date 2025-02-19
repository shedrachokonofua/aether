FROM alpine:edge

# Add community repository
RUN echo "@community https://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories

# Update and install packages
RUN apk update && \
  apk add --no-cache \
  python3 \
  py3-pip \
  ansible@community \
  ansible-galaxy@community \
  sops@community \
  age \
  opentofu@community \
  aws-cli \
  ca-certificates \
  groff \
  less \
  && \
  update-ca-certificates && \
  # Clean up
  rm -rf /var/cache/apk/*

# Create and set the workspace directory
RUN mkdir -p /workspaces
WORKDIR /workspaces

# Verify installations
RUN ansible --version && \
  ansible-galaxy --version && \
  tofu version && \
  sops --version && \
  aws --version && \
  age-keygen --version

CMD ["/bin/sh"]
