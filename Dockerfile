# Multi-stage build for geode database
FROM debian:bookworm-slim AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    curl \
    xz-utils \
    ca-certificates \
    git \
    build-essential \
    file \
    && rm -rf /var/lib/apt/lists/*

# Copy and run Zig installation script
COPY scripts/docker/install-zig.sh /tmp/install-zig.sh
ARG ZIG_VERSION=0.15.1
RUN chmod +x /tmp/install-zig.sh && \
    /tmp/install-zig.sh ${ZIG_VERSION} x86_64 linux /opt && \
    rm /tmp/install-zig.sh

# Set working directory
WORKDIR /build

# Copy source code
COPY . .

# Build geode binaries and tools
RUN zig build -Drelease-safe && \
    (zig build tools -Drelease-safe || echo "Warning: Some tools may not have built")

# Runtime stage
FROM debian:bookworm-slim AS runtime

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    openssl \
    && rm -rf /var/lib/apt/lists/* && \
    useradd -m -u 1000 geode && \
    mkdir -p /data /certs /var/log/geode && \
    chown -R geode:geode /data /certs /var/log/geode

# Copy all built binaries from builder
COPY --from=builder /build/zig-out/bin/ /usr/local/bin/

# Note: Mount certificates as volume at runtime instead of copying during build
# Example: docker run -v ./certs:/certs:ro geode:latest

# Switch to non-root user
USER geode
WORKDIR /home/geode

# Expose ports
# 7567 - QUIC (default)
# 7568 - TCP (legacy)
# 9090 - Metrics/Prometheus
EXPOSE 7567/udp 7568/tcp 9090/tcp

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD geodec "RETURN 1 AS health" --server 127.0.0.1:7567 || exit 1

# Default entrypoint and command
ENTRYPOINT ["/usr/local/bin/geoded"]
CMD ["--listen-quic", "0.0.0.0:7567", "--data-dir", "/data", "--log-json"]