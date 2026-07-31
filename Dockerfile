# Multi-stage build for geode database
# Uses vendored zig-quic and ztls, requires OpenSSL for crypto operations

# Stage 1: Build Geode
FROM debian:bookworm-slim AS builder
# Issue #442: Use bash with pipefail to catch errors in piped commands
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ARG needs to be declared at the beginning of the stage
ARG TARGETARCH

# Install build dependencies
# Note: libvulkan-dev and glslang-tools removed - GPU acceleration is optional and not available in containers
# Versions pinned to the current debian:bookworm-slim apt candidates (checked via
# `apt-cache policy` against this base image) for reproducible, SAST-clean builds.
# These are build-stage-only packages (discarded after the build stage), so a
# stale pin only risks a future build-time apt error, not a shipped-image CVE;
# Renovate can bump these pins when newer point releases roll out.
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl=7.88.1-10+deb12u15 \
    xz-utils=5.4.1-1+deb12u1 \
    ca-certificates=20230311+deb12u1 \
    git=1:2.39.5-0+deb12u3 \
    build-essential=12.9 \
    file=1:5.44-3 \
    libssl-dev=3.0.20-1~deb12u2 \
    && rm -rf /var/lib/apt/lists/*

# Copy pre-downloaded Zig archives for both architectures (avoids entropy issues in Docker build)
# Only the archive matching TARGETARCH needs to exist; the other COPY is allowed to fail via
# the glob pattern which gracefully handles missing files.
ARG ZIG_VERSION=0.15.2
COPY docker/zig/zig-x86_64-linux-${ZIG_VERSION}.tar.xz* /tmp/
COPY docker/zig/zig-aarch64-linux-${ZIG_VERSION}.tar.xz* /tmp/

# Select the correct archive based on target architecture and install Zig
RUN if [ "$TARGETARCH" = "arm64" ]; then \
        ZIG_ARCH="aarch64"; \
    else \
        ZIG_ARCH="x86_64"; \
    fi && \
    ZIG_ARCHIVE="/tmp/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" && \
    if [ ! -f "$ZIG_ARCHIVE" ]; then \
        echo "ERROR: Zig archive not found: $ZIG_ARCHIVE" && \
        echo "Please download it to docker/zig/ first:" && \
        echo "  curl -LO https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" && \
        exit 1; \
    fi && \
    echo "Installing Zig ${ZIG_VERSION} for ${ZIG_ARCH}-linux..." && \
    tar -xf "$ZIG_ARCHIVE" -C /opt && \
    ln -s /opt/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}/zig /usr/local/bin/zig && \
    rm -f /tmp/zig-*-linux-*.tar.xz && \
    zig version && \
    echo "Zig installed successfully!"

# Set working directory
WORKDIR /build

# Pre-populate Zig package cache (Zig's git fetcher fails inside Docker)
COPY docker/zig-packages/ /root/.cache/zig/p/

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

# Install runtime dependencies. `apt-get upgrade` patches pre-installed base
# packages (perl-base, zlib1g, util-linux, ncurses, etc.) regardless of how
# stale the debian:bookworm-slim layer in the local build cache is -- those
# packages aren't in our own install list but still ship in the image and
# accumulate CVEs between base-image refreshes otherwise.
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    iproute2 \
    && rm -rf /var/lib/apt/lists/* && \
    useradd -m -u 1000 geode && \
    mkdir -p /data /certs /var/log/geode && \
    chown -R geode:geode /data /certs /var/log/geode

# Copy all built binaries from builder
COPY --from=builder /build/zig-out/bin/ /usr/local/bin/

# Copy shared health check script (issue #549: single source of truth)
COPY docker/health-check.sh /usr/local/bin/health-check.sh
RUN chmod +x /usr/local/bin/health-check.sh

# Note: Mount certificates as volume at runtime instead of copying during build
# Example: docker run -v ./certs:/certs:ro geode:latest

# Switch to non-root user
USER geode
WORKDIR /home/geode

# Set default log level (can be overridden with -e LOG_LEVEL=debug)
ENV LOG_LEVEL=error

# QUIC Performance Optimizations:
# GSO (Generic Segmentation Offload) is enabled by default on Linux 4.18+
# To disable GSO (not recommended), set: -e QUIC_GO_DISABLE_GSO=true
#
# For optimal QUIC throughput, increase UDP buffer sizes when running:
#   docker run --sysctl net.core.rmem_max=7340032 --sysctl net.core.wmem_max=7340032 ...
# Or configure host sysctl settings:
#   sysctl -w net.core.rmem_max=7340032
#   sysctl -w net.core.wmem_max=7340032

# Enable the out-of-band liveness endpoint the HEALTHCHECK probes:
# GET http://127.0.0.1:$GEODE_METRICS_PORT/health (bound to loopback unless
# GEODE_METRICS_BIND says otherwise). The server only starts that listener when
# GEODE_METRICS_PORT is set, and docker/health-check.sh needs it so the probe
# stays off the authenticated QUIC query path.
ENV GEODE_METRICS_PORT=9091

# Expose ports (QUIC + gRPC + metrics)
EXPOSE 3141/udp 50051/tcp 9091/tcp

# Health check using shared script (see docker/health-check.sh)
# SEC-22: --insecure is acceptable (localhost only, see docker/health-check.sh)
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD /usr/local/bin/health-check.sh

# Default entrypoint and command
ENTRYPOINT ["/usr/local/bin/geode", "serve"]
CMD ["--data-dir", "/data", "--enable-auth"]
