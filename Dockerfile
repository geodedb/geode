# Multi-stage build for geode database
FROM debian:bookworm-slim AS builder

# ARG needs to be declared at the beginning of the stage
ARG TARGETARCH

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
    if [ "$TARGETARCH" = "arm64" ]; then \
        ARCH="aarch64"; \
    else \
        ARCH="x86_64"; \
    fi && \
    /tmp/install-zig.sh ${ZIG_VERSION} $ARCH linux /opt && \
    rm /tmp/install-zig.sh

# Set working directory
WORKDIR /build

# Copy build configuration files first (for better caching)
COPY build.zig ./

# Create empty src directory to satisfy build.zig
RUN mkdir -p src && touch src/main.zig

# Now copy the actual source code
COPY . .

# Build geode binaries and tools
RUN if [ "$TARGETARCH" = "arm64" ]; then \
        export ZIG_TARGET="aarch64-linux-gnu"; \
    else \
        export ZIG_TARGET="x86_64-linux-gnu"; \
    fi && \
    zig build -Doptimize=ReleaseSafe -Dtarget=$ZIG_TARGET && \
    (zig build tools -Doptimize=ReleaseSafe -Dtarget=$ZIG_TARGET || echo "Warning: Some tools may not have built")

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

# Expose ports (QUIC-only + metrics)
EXPOSE 7567/udp 9090/tcp

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["geode", "query", "RETURN 1 AS health", "--server", "127.0.0.1:7567"]

# Default entrypoint and command
ENTRYPOINT ["/usr/local/bin/geode", "serve"]
CMD ["--data-dir", "/data", "--log-level", "info"]