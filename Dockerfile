# Multi-stage build for geode database
# Uses vendored zig-quic and ztls, requires OpenSSL for crypto operations

# Stage 1: Build Geode
FROM debian:bookworm-slim AS builder

# ARG needs to be declared at the beginning of the stage
ARG TARGETARCH

# Install build dependencies
# Note: libvulkan-dev and glslang-tools removed - GPU acceleration is optional and not available in containers
RUN apt-get update && apt-get install -y \
    curl \
    xz-utils \
    ca-certificates \
    git \
    build-essential \
    file \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy pre-downloaded Zig archive (avoids entropy issues in Docker build)
COPY docker/zig/zig-x86_64-linux-0.15.1.tar.xz /tmp/zig.tar.xz
ARG ZIG_VERSION=0.15.1
RUN if [ "$TARGETARCH" = "arm64" ]; then \
        ARCH="aarch64"; \
    else \
        ARCH="x86_64"; \
    fi && \
    echo "Installing Zig ${ZIG_VERSION} for ${ARCH}-linux..." && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    ln -s /opt/zig-${ARCH}-linux-${ZIG_VERSION}/zig /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz && \
    zig version && \
    echo "Zig installed successfully!"

# Set working directory
WORKDIR /build

# Copy all source code (includes vendored quic and ztls)
COPY . .

# Build geode binaries
RUN echo "Building with Zig $(zig version)..." && \
    zig build -Doptimize=ReleaseSafe --summary all && \
    test -f /build/zig-out/bin/geode && \
    echo "✓ Build successful - geode binary created" && \
    (zig build tools -Doptimize=ReleaseSafe --summary all 2>&1 || \
     echo "Note: Some tools may not have built")

# Stage 2: Runtime stage (minimal)
FROM debian:bookworm-slim AS runtime

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    iproute2 \
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

# Set default log level (can be overridden with -e LOG_LEVEL=debug)
ENV LOG_LEVEL=error

# Expose ports (QUIC-only + metrics)
EXPOSE 3141/udp 9091/tcp

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["geode", "query", "RETURN 1 AS health", "--server", "127.0.0.1:3141", "--insecure"]

# Default entrypoint and command
ENTRYPOINT ["/usr/local/bin/geode", "serve"]
CMD ["--data-dir", "/data"]
