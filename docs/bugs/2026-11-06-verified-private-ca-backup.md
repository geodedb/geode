# Verified private-CA backup consumer

The pinned v0.8.23 image
`geodedb/geode@sha256:48a24f3739bda9017536cdd7b9b0c14474d0cc643d0b202560465d3834b9587a`
identifies source `94d743280e4a77826557310977f1aff8f894ab38`. Its Zig client
v0.3.12 supplied a CA path, while the native QUIC TLS context consumed decoded
DER anchors. A strict backup handshake timed out. Its historical local fallback
could return exit zero without proving a remote backup.

The current main branch already requires explicit `--local` for local backups.
This change preserves that behavior and consumes published Zig client v0.3.13
at `9966a5a91600fc84176139662b22cb63d4b8b19b`, with owned CA material, and
published QUIC v0.1.48 at
`274109bd5a0a268b7e64cd00a406d00a61bd1de2`. `zig fetch` verified both package
hashes recorded in `build.zig.zon`. There is no local replacement or vendored
fork. Preparing version 0.8.24 does not itself publish an image.

`tests/qualify_backup_ca.py` starts two actual candidate server processes using
private temporary directories, random loopback UDP ports and ephemeral
credentials. Their generated certificates provide the trusted and untrusted
CA controls. The actual CLI must receive remote bytes and successfully parse
the captured backup. Wrong and missing CAs must return nonzero, leave no backup
file and never disable verification or fall back to local data. Every owned
server is stopped on success and failure. Credentials and raw diagnostics are
not published.

The new test is part of the existing named
`zig build test-backup-create-remote-failure` target and its existing aggregate
registration. Local qualification on 2026-11-06:

- `zig build test-backup-create-remote-failure -j1 --summary all`: PASS,
  38/38 build steps and all five tests, including the existing refusal and
  explicit local-backup controls.
- Direct qualification: verified remote backup exit 0, 9,434 received bytes,
  backup parser exit 0; wrong CA exit 1; missing CA exit 1. No fallback,
  verification bypass or negative-control output file was observed.
- The native Debug candidate executable has SHA-256
  `e261eaa2c22e34eab1bdf3f4ffca804a274a5478502b263571e9b88bc2a9eb54`.

The first named run failed at fixture server startup; direct execution passed.
The fixture now passes an explicit minimal process environment, including the
PATH needed by certificate generation, through its owned Zig I/O context. The
complete named run above then passed. Optional private diagnostics aid local
debugging without publishing raw server logs.

The aggregate compilation sweep, full CI, protected release image and Lanning's
unfiltered backup/restore integration remain separate delivery checks. This
candidate record does not claim that the final release artifact or complete
aggregate suite has already passed.
