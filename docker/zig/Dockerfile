# Zig toolchain image for CI catalog publishing
FROM debian:bookworm-slim

ARG ZIG_VERSION=0.15.2

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
    && tar -xJf /tmp/zig.tar.xz -C /usr/local \
    && ln -sf "/usr/local/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig \
    && rm -f /tmp/zig.tar.xz

RUN zig version

ENTRYPOINT ["zig"]
