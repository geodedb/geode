# Multi-stage build for geode database with OpenSSL and MsQUIC support
# Stage 1: Build OpenSSL 3.3.2 (standard, no FIPS)
FROM debian:bookworm-slim AS openssl-builder

RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    build-essential \
    perl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Download and build OpenSSL 3.3.2 (standard build)
RUN curl -L https://www.openssl.org/source/openssl-3.3.2.tar.gz -o openssl-3.3.2.tar.gz && \
    tar xzf openssl-3.3.2.tar.gz && \
    cd openssl-3.3.2 && \
    ./Configure --prefix=/opt/openssl --openssldir=/opt/openssl/ssl && \
    make -j$(nproc) && \
    make install

# Stage 2: Build MsQUIC with standard OpenSSL
FROM debian:bookworm-slim AS msquic-builder

RUN apt-get update && apt-get install -y \
    git \
    cmake \
    build-essential \
    liblttng-ust-dev \
    libnuma-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Copy OpenSSL from openssl-builder
COPY --from=openssl-builder /opt/openssl /opt/openssl

# Set OpenSSL environment for MsQUIC build
ENV PKG_CONFIG_PATH=/opt/openssl/lib64/pkgconfig:$PKG_CONFIG_PATH \
    LD_LIBRARY_PATH=/opt/openssl/lib64:$LD_LIBRARY_PATH \
    PATH=/opt/openssl/bin:$PATH \
    OPENSSL_ROOT_DIR=/opt/openssl

WORKDIR /build

# Clone and build MsQUIC v2.5.4 with OpenSSL3 and logging enabled
RUN git clone --depth 1 --branch v2.5.4 https://github.com/microsoft/msquic.git && \
    cd msquic && \
    git submodule update --init --recursive && \
    mkdir build && \
    cd build && \
    cmake -G 'Unix Makefiles' \
        -DCMAKE_BUILD_TYPE=Release \
        -DQUIC_BUILD_SHARED=ON \
        -DQUIC_TLS_LIB=openssl \
        -DQUIC_ENABLE_LOGGING=ON \
        -DOPENSSL_ROOT_DIR=/opt/openssl \
        -DCMAKE_PREFIX_PATH=/opt/openssl \
        .. && \
    cmake --build . --config Release -j$(nproc) && \
    cmake --install . --prefix /opt/msquic

# Stage 3: Build Geode with all dependencies
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
    libvulkan-dev \
    glslang-tools \
    cmake \
    pkg-config \
    liblttng-ust-dev \
    libnuma-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy OpenSSL FIPS from openssl-builder stage
COPY --from=openssl-builder /opt/openssl /opt/openssl

# Copy MsQUIC from msquic-builder stage
COPY --from=msquic-builder /opt/msquic /opt/msquic

# Set environment variables for OpenSSL FIPS and MsQUIC
ENV OPENSSL_ROOT_DIR=/opt/openssl \
    OPENSSL_CONF=/opt/openssl/ssl/openssl.cnf \
    OPENSSL_MODULES=/opt/openssl/lib64/ossl-modules \
    PKG_CONFIG_PATH=/opt/openssl/lib64/pkgconfig:/opt/msquic/lib/pkgconfig:$PKG_CONFIG_PATH \
    LD_LIBRARY_PATH=/opt/openssl/lib64:/opt/msquic/lib:$LD_LIBRARY_PATH \
    PATH=/opt/openssl/bin:$PATH

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

# Copy all source code (don't use dummy files - causes conflicts)
COPY . .

# Build geode binaries and tools with library search paths
RUN echo "Building with Zig $(zig version)..." && \
    zig build -Doptimize=ReleaseSafe \
      --search-prefix /opt/msquic \
      --search-prefix /opt/openssl \
      --summary all 2>&1 | tee /tmp/build.log && \
    echo "✓ Build successful!" && \
    (zig build tools -Doptimize=ReleaseSafe --summary all 2>&1 || \
     echo "Note: Some tools may not have built")

# Stage 4: Runtime stage with FIPS and MsQUIC support
FROM debian:bookworm-slim AS runtime

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    liblttng-ust1 \
    libnuma1 \
    && rm -rf /var/lib/apt/lists/* && \
    useradd -m -u 1000 geode && \
    mkdir -p /data /certs /var/log/geode && \
    chown -R geode:geode /data /certs /var/log/geode

# Copy OpenSSL FIPS from builder
COPY --from=builder /opt/openssl /opt/openssl

# Copy MsQUIC from builder
COPY --from=builder /opt/msquic /opt/msquic

# Register MsQUIC and OpenSSL libraries with ldconfig
RUN echo "/opt/msquic/lib" > /etc/ld.so.conf.d/msquic.conf && \
    echo "/opt/openssl/lib64" > /etc/ld.so.conf.d/openssl-fips.conf && \
    ldconfig

# Set environment variables for runtime
ENV OPENSSL_ROOT_DIR=/opt/openssl \
    OPENSSL_CONF=/opt/openssl/ssl/openssl.cnf \
    OPENSSL_MODULES=/opt/openssl/lib64/ossl-modules \
    LD_LIBRARY_PATH=/opt/openssl/lib64:/opt/msquic/lib:$LD_LIBRARY_PATH \
    PATH=/opt/openssl/bin:$PATH

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
EXPOSE 8443/udp 9090/tcp

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["geode", "query", "RETURN 1 AS health", "--server", "127.0.0.1:8443"]

# Default entrypoint and command
ENTRYPOINT ["/usr/local/bin/geode", "serve"]
CMD ["--data-dir", "/data"]
