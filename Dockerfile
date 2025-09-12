FROM debian:bookworm-slim AS zig
ARG ZIG_VERSION=0.15.1
# sha256 of zig-x86_64-linux-0.15.1.tar.xz (fill in for integrity pinning)
ARG ZIG_SHA256=placeholder
RUN apt-get update && apt-get install -y curl xz-utils ca-certificates git build-essential && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
	curl -L -o /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz"; \
	if [ "$ZIG_SHA256" != "placeholder" ]; then echo "$ZIG_SHA256  /tmp/zig.tar.xz" | sha256sum -c -; fi; \
	tar -xf /tmp/zig.tar.xz -C /opt; \
	mv /opt/zig-* /opt/zig; \
	ln -s /opt/zig/zig /usr/local/bin/zig; \
	zig version
WORKDIR /workspace
COPY . .
RUN zig build -Doptimize=ReleaseSafe

FROM debian:bookworm-slim AS runtime
RUN useradd -m geode
WORKDIR /home/geode
COPY --from=zig /workspace/zig-out/bin/geoded /usr/local/bin/geoded
COPY --from=zig /workspace/zig-out/bin/geodec /usr/local/bin/geodec
USER geode
EXPOSE 7687
ENTRYPOINT ["/usr/local/bin/geoded"]
CMD ["--result-format","json"]