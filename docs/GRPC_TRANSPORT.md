# gRPC Transport — Availability and Runtime Requirements

Geode serves two transports:

- **QUIC** (`geode serve --listen <addr>`) — always available on every published
  binary. No external runtime dependency.
- **gRPC over HTTP/2** (`geode serve --listen-grpc <addr>`) — requires OpenSSL
  3.x, both at build time (to compile `src/transport/grpc_tls.zig`'s OpenSSL
  binding) and at run time (`libssl.so.3`).

## Listen address

`--listen-grpc` takes `<ipv4>:<port>`, `localhost:<port>` or a port alone, and
the listener binds exactly that address (SONNY-1336; before it the address
reached only a log line and the vendored grpc-zig bound `127.0.0.1`, so a
published container port reached nothing):

| `--listen-grpc` | Binds |
|---|---|
| `0.0.0.0:50051` | every IPv4 interface |
| `127.0.0.1:50051` / `localhost:50051` | loopback only |
| `50051` | the `--listen` (QUIC) address when it is IPv4 (`localhost` is `127.0.0.1`), or `0.0.0.0` when there is no `--listen` or it is a port alone (QUIC's own port-only default). When `--listen` is IPv6 or a host name it is refused (SONNY-6494): gRPC cannot bind that address, and `0.0.0.0` would listen more widely than QUIC |

The gRPC listener binds **IPv4 only**: grpc-zig's `GrpcServer.initWithBind`
parses an IPv4 literal. An IPv6 address (`[::]:50051`), a host name, or a
missing or out-of-range port is refused at startup with exit status 2 and a
message naming `--listen-grpc`; it is never replaced by another address.
`GRPC_ZIG_BIND_ADDR` no longer decides the bind (setting it, as older driver
harnesses did, is harmless). On startup the server prints a JSON banner on
stderr with the address and port bound, for example
`{"component":"transport","transport":"grpc","address":"0.0.0.0","port":50051,"status":"listening"}`.
The listener is TLS-only outside Debug builds (see Fail-closed behaviour below).

## RPCs

The listener serves exactly the RPCs `service GeodeService` in
`src/proto/geode.proto` declares (the clients ship that file and generate
their stubs from it): `Handshake`, `Execute`, `Ping`, `Begin`, `Commit`,
`Rollback`, `GetCdcDiagnostics`, `ControlCdc`, `Savepoint`, `RollbackTo`,
`Backup`, `Restore` and `UploadBackup`, each at
`/geode.GeodeService/<name>`. Any other path answers grpc-status 12
(UNIMPLEMENTED). The list the server registers is
`src/transport/grpc_service_methods.zig`;
`zig build test-sonny6593-grpc-service-contract` checks it against the
.proto and probes a running server.

Before SONNY-6593 the server also served `Savepoint`, `RollbackTo`,
`Backup`, `Restore` and `UploadBackup`, which the .proto did not declare
(they are declared now, with the request and response messages the QUIC
transport already used, so existing clients are unaffected), and
`CdcDiag` / `CdcCtrl`, undeclared aliases of `GetCdcDiagnostics` /
`ControlCdc` that no client used (no longer served).

## Runtime requirement (new)

Prior to this change every cross-compiled release binary shipped **without**
OpenSSL: Zig does not search host system library paths for a non-native target,
so `ssl`/`crypto` resolved to "searched paths: none" and the build fell back to
`grpc_tls.zig`'s stub. The listener then refused to start with
`error.TlsRequired`, and nothing in the shipped artifact said why.

The Linux glibc and musl release tarballs now link `libssl.so.3`. **Install your
distribution's OpenSSL 3 runtime before starting a gRPC listener:**

| Platform | Package |
|---|---|
| Debian / Ubuntu | `libssl3` |
| Alpine | `libssl3` |
| RHEL / Fedora | `openssl-libs` |

The `.deb` / `.rpm` / `.apk` packages and the Docker images
(`Dockerfile.release` installs `libssl3`) already cover this. Only raw-tarball
users need to act.

The glibc tarballs additionally require **glibc 2.38 or newer**. Without that
floor the link fails against the Debian `libssl.so` with
`undefined version: pthread_*@GLIBC_2.34`.

## Availability by target

Authoritative source: `target_capabilities` in `release/target_manifest.json`,
enforced against the target list by `tools/release_target_manifest.py`.

| Target | QUIC | gRPC |
|---|---|---|
| `x86_64-linux-gnu` | yes | yes — needs `libssl.so.3`, glibc >= 2.38 |
| `aarch64-linux-gnu` | yes | yes — needs `libssl.so.3`, glibc >= 2.38 |
| `x86_64-linux-musl` | yes | yes — needs `libssl.so.3` |
| `aarch64-linux-musl` | yes | yes — needs `libssl.so.3` |
| `riscv64-linux-gnu` | yes | **no** — QUIC only; gRPC transport unavailable (Zig toolchain limitation) |
| `x86_64-macos` | yes | **no** in the cross-built tarball |
| `aarch64-macos` | yes | **no** in the cross-built tarball |

### Why riscv64 has no gRPC

A hard toolchain blocker, not a packaging gap. Under Zig 0.16 **any** `@cImport`
of libc headers for `riscv64-linux` fails with an "unsupported FLEN" error, so
the `@cInclude("openssl/ssl.h")` in `grpc_tls.zig` cannot be compiled for that
target no matter which OpenSSL prefix is supplied. It needs an upstream Zig fix.
`-Dopenssl-sysroot` deliberately no-ops there, and the build prints the standard
"building WITHOUT OpenSSL" warning.

### Why macOS has no gRPC in the tarballs

The published macOS archives are cross-built on Linux, and provisioning OpenSSL
for a cross-compiled macOS target (Homebrew bottles) is untested. Rather than
guess, it is left off and reported honestly. This is tracked as follow-up work.
The Homebrew formula declares an `openssl@3` dependency, and a **native** macOS
build with OpenSSL present links it normally.

## Fail-closed behaviour

Where gRPC TLS is not compiled in, `serve --listen-grpc` exits with
`error.TlsRequired`. It never silently downgrades to plaintext. The
Debug-only `GEODE_GRPC_ALLOW_PLAINTEXT_FALLBACK=1` escape hatch exists for tests
and is ignored outside Debug builds.

## Building with gRPC TLS yourself

`scripts/ci/fetch-openssl-prefix.sh` materializes a per-target OpenSSL prefix
from the distro's own prebuilt packages (Debian trixie for glibc, Alpine v3.22
for musl), with pinned versions and sha256 checksums:

```bash
# One prefix per target, laid out as <root>/<zig-triple>/{include,lib}
scripts/ci/fetch-openssl-prefix.sh aarch64-linux-gnu /tmp/openssl/aarch64-linux-gnu

# build.zig derives <root>/<triple> from the resolved target, applies the
# GLIBC_2.38 floor for linux-gnu, and turns -Denable-openssl on.
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-gnu \
    -Dopenssl-sysroot=/tmp/openssl

# Verify:
readelf -d zig-out/bin/geode | grep libssl
#   0x0000000000000001 (NEEDED)  Shared library: [libssl.so.3]
```

A native build needs none of this — `-Denable-openssl` auto-detects on native
non-Windows targets.

The release pipeline does exactly the above: `.goreleaser.yaml` provisions the
four prefixes in its `before:` hooks and passes `-Dopenssl-sysroot=dist/openssl`
to the `geode` build. The `test-cross-build` CI gate mirrors it and asserts the
`NEEDED libssl.so.3` entry is present, so a regression to a TLS-less binary
fails the pipeline instead of shipping.
