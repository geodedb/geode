# Verified-TLS (`--ca-cert`) handshake stalls: `backup`/`restore` streaming + inter-node Raft

**Date:** 2026-06-13
**Status:** OPEN (geode-side); the `../geode-test-harness` suite works around both so it runs green against a **release** binary.
**Discovered:** while making the whole geodetestlab suite pass against a ReleaseFast/ReleaseSafe `geode` (the release binary correctly refuses `--insecure-tls-skip-verify`, so every harness path had to move to verified TLS via a provisioned CA + `--ca-cert`).

## Symptom

On a **release** binary, two verified-TLS QUIC paths fail even though a normal
`geode query --ca-cert <ca>` against the same server/cert succeeds:

1. **`geode backup create --ca-cert` / `geode restore --ca-cert` / `geode auth
   login --ca-cert` stall.** The client prints its banner (e.g.
   `Creating <mode> backup to: …`) and then blocks; the response never arrives
   and the command times out. `auth login --ca-cert` stalls every time (5/5 in a
   tight loop). The same commands with `--insecure-tls-skip-verify`
   (+ `GEODE_ALLOW_INSECURE_TLS=1`) complete normally (backup writes the full file
   byte-for-byte; auth login returns exit 0). So the bug is specific to the
   **verified-TLS handshake for these non-`query` QUIC clients**, not the
   streaming/auth logic or the release binary itself.

2. **Inter-node Raft TLS handshake fails with `HandshakeError`** when a forced
   harness cluster provisions `GEODE_CLUSTER_CA_CERT` + a shared leaf
   (`raft transport getOrCreatePeerConnection failed error=HandshakeError peer=N`).
   No leader is elected → readiness times out. This is the same class as
   **GAP-0838** (cross-pod Raft TLS), already tracked/Blocked.

## Evidence (backup path, minimal repro)

```
# release binary + provisioned CA (SAN IP:127.0.0.1,DNS:localhost), server started with --cert/--key
geode query  --server 127.0.0.1:P --ca-cert ca.crt -U geode -P pw "RETURN 1"   # OK, {"x":1}
geode backup create --output bk.geode --server 127.0.0.1:P --ca-cert ca.crt -U geode -P pw   # HANGS (timeout, no file)
GEODE_ALLOW_INSECURE_TLS=1 geode backup create --output bk.geode --server 127.0.0.1:P --insecure-tls-skip-verify -U geode -P pw   # OK, 199383 bytes
```

Server-side metrics during the hang show the handshake **starts but never
completes**: `quic_poll_recv_initial_max_ns` and `quic_poll_recv_handshake_max_ns`
are non-zero, yet `quic_active_connections=0` and
`quic_first_stream_packets_started_total=0`. So the backup client's verified-TLS
handshake is processed by the server but the connection never reaches "active".

A single-shot `query --ca-cert` against the *same* server completes its verified
handshake fine — so the defect is in a code path the backup/restore client (and
the Raft peer dialer) take that the query client does not. Likely the same
client-side TLS-1.3 `CertificateVerify` transcript issue noted for GAP-0838.

## Harness workaround (so the suite is green on a release binary)

These are in `../geode-test-harness` and do **not** mask the bug — the real data
transfer / node behavior still happens:

- **`backup`/`restore`/`auth login`** (`lib/executor.py`, remote-admin +
  `_LOCAL` auth-login branches): driven through geode's documented insecure
  escape hatch (`GEODE_ALLOW_INSECURE_TLS=1` + `--insecure-tls-skip-verify`)
  instead of `--ca-cert`. `migrate` and plain `query` are unaffected (they verify
  fine). geode's `auth login` was also given a real `--ca-cert` option
  (`src/cli/main.zig`) for when the verified path is fixed.
- **node-signal specs** (`2pc_*`): run as **independent standalone servers**
  (`cluster.independent: true` → no `GEODE_CLUSTER_TOKEN`/`GEODE_PEERS`), which
  matches their stated "independent-servers" contract and avoids the inter-node
  Raft TLS handshake entirely.

## Real fix (geode-side, TODO)

Root-cause why the verified-TLS QUIC handshake completes for the `query` client
but stalls for the backup/restore client and the Raft peer dialer. Most likely a
shared fix in the client TLS-1.3 verify path (`devnw/zig` tls `CertificateVerify`
transcript fold order — see the GAP-0838 root-cause note) plus an audit of the
backup/restore client connect loop (`src/cli/backup_cli.zig` `executeRemoteBackup`
/ `connectMigrationClient`). Once fixed, revert the two harness workarounds above
to use verified `--ca-cert` uniformly.
