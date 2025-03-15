# Stage 1: Get the opentelemetry collector binary from the official image
FROM docker.io/otel/opentelemetry-collector-contrib:latest AS builder

# Stage 2: Use Fedora as the base
FROM fedora:latest

# Install systemd (journalctl is part of the systemd package)
RUN dnf -y update && \
  dnf -y install systemd && \
  dnf clean all

# Copy the collector binary from the builder stage
COPY --from=builder /otelcol-contrib /otelcol-contrib

# Expose any ports your collector uses (modify as needed)
EXPOSE 4317 55680 55679

# Set the entrypoint to run the collector
ENTRYPOINT ["/otelcol-contrib"]
# Default command line arguments (update as necessary)
CMD ["--config=/etc/otel-collector-config.yaml"]
