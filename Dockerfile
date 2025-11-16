# Multi-stage build for geode database with OpenSSL FIPS and MsQUIC support
# Stage 1: Build OpenSSL 3.3.2 with FIPS module
FROM debian:bookworm-slim AS openssl-builder

RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    build-essential \
    perl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Download and build OpenSSL 3.3.2 with FIPS module
RUN curl -L https://www.openssl.org/source/openssl-3.3.2.tar.gz -o openssl-3.3.2.tar.gz && \
    tar xzf openssl-3.3.2.tar.gz && \
    cd openssl-3.3.2 && \
    ./Configure enable-fips --prefix=/opt/openssl-fips --openssldir=/opt/openssl-fips && \
    make -j$(nproc) && \
    make install && \
    export LD_LIBRARY_PATH=/opt/openssl-fips/lib64:$LD_LIBRARY_PATH && \
    /opt/openssl-fips/bin/openssl fipsinstall \
        -out /opt/openssl-fips/ssl/fipsmodule.cnf \
        -module /opt/openssl-fips/lib64/ossl-modules/fips.so && \
    sed -i 's|# .include fipsmodule.cnf|.include /opt/openssl-fips/ssl/fipsmodule.cnf|' /opt/openssl-fips/ssl/openssl.cnf

# Stage 2: Build MsQUIC
FROM debian:bookworm-slim AS msquic-builder

RUN apt-get update && apt-get install -y \
    git \
    cmake \
    build-essential \
    libssl-dev \
    liblttng-ust-dev \
    libnuma-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Clone and build MsQUIC v2.5.5 (latest stable)
RUN git clone --depth 1 --branch v2.5.5 https://github.com/microsoft/msquic.git && \
    cd msquic && \
    git submodule update --init --recursive && \
    mkdir build && \
    cd build && \
    cmake -G 'Unix Makefiles' -DCMAKE_BUILD_TYPE=Release -DQUIC_BUILD_SHARED=ON .. && \
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
COPY --from=openssl-builder /opt/openssl-fips /opt/openssl-fips

# Copy MsQUIC from msquic-builder stage
COPY --from=msquic-builder /opt/msquic /opt/msquic

# Set environment variables for OpenSSL FIPS and MsQUIC
ENV OPENSSL_ROOT_DIR=/opt/openssl-fips \
    OPENSSL_CONF=/opt/openssl-fips/ssl/openssl.cnf \
    OPENSSL_MODULES=/opt/openssl-fips/lib64/ossl-modules \
    PKG_CONFIG_PATH=/opt/openssl-fips/lib64/pkgconfig:/opt/msquic/lib/pkgconfig:$PKG_CONFIG_PATH \
    LD_LIBRARY_PATH=/opt/openssl-fips/lib64:/opt/msquic/lib:$LD_LIBRARY_PATH \
    PATH=/opt/openssl-fips/bin:$PATH

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
COPY --from=builder /opt/openssl-fips /opt/openssl-fips

# Copy MsQUIC from builder
COPY --from=builder /opt/msquic /opt/msquic

# Set environment variables for runtime
ENV OPENSSL_ROOT_DIR=/opt/openssl-fips \
    OPENSSL_CONF=/opt/openssl-fips/ssl/openssl.cnf \
    OPENSSL_MODULES=/opt/openssl-fips/lib64/ossl-modules \
    LD_LIBRARY_PATH=/opt/openssl-fips/lib64:/opt/msquic/lib:$LD_LIBRARY_PATH \
    PATH=/opt/openssl-fips/bin:$PATH

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
