# Bug: server crash under client connection load — `@memcpy` alias panic in `sendExecuteError` and SIGSEGV in `processInitialDatagramConcurrent`

**Status:** **OPEN** — reported 2026-06-02 from a live deployment. Two
distinct crash signatures, both fatal to the whole server process, observed
on the same node within minutes of each other under ordinary client load.

**Discovered:** 2026-06-02 in `divelife-qa` (single-node geode StatefulSet)
while an application API pod (which opens a small connection pool + runs a
schema-apply sequence on boot) was connecting. A second client (a PDS pod
that opens fewer connections) reconnected and stayed up, so the trigger
correlates with **connection / first-stream concurrency**, not data.

**Build / environment:**

- Image: `geodedb/geode:0.6.13`
- QUIC dep (from the crash frame paths): `quic-0.1.22-gBIqUdjwPAA8_NR-ta30VI2TwpbsUP-xy4FkvjEBlv_G`
- protobuf dep: `protobuf-0.1.3-0e82akQuKgCxd7t6_GuCJhJPSdlBV0gDwSynuN1BZO7i`
- Zig 0.16.0, musl, ReleaseSafe (panics are caught — i.e. running with
  safety checks on; a ReleaseFast build would likely corrupt memory silently
  instead of panicking on the `@memcpy` alias).
- Repo `main` is AHEAD of the deployed image (HEAD `a69cd6ae` re-pins
  `tls v0.1.9` for the GAP-0838 CertificateVerify transcript fix). **It is
  unknown whether either crash below is already fixed on `main`** — this
  report is filed against what `0.6.13` actually does in production so the
  team can confirm fixed-or-not and, if fixed, ensure a release ships.

**Severity:** **Critical.** Each crash is an unrecoverable process exit. On a
single-node deployment it produces a crashloop: the node restarts, a client
re-attempts its connection burst, the server crashes again. Net effect is a
hard QA outage that no amount of *client* retry/restart can clear (verified:
restarting the client only re-triggers the crash; restarting the server
returns it to "ready" for ~seconds until the next client burst).

This is **distinct** from the fixed TLS `pollCrypto` SIGSEGV documented in
`QUIC_TLS_POLLCRYPTO_CRASH.md` (that was `tls-0.1.7` / `quic-0.1.21`; the
frames there are `pollCrypto`). The crashes here are on the newer
`quic-0.1.22` line, and crash A is in Geode's own
`src/server/quic_connection_handler.zig` error-response serialization, not
in the TLS handshake-output path. It may be a regression on `0.1.22`, a
separate latent bug, or already-fixed-on-main — please confirm.

---

## 1. Crash A — `@memcpy arguments alias` panic serializing an execute-error response

The server logs `server ready`, then panics on the **first client message it
answers with an execute-error** (the panic frames go
`processCooperativeFirstStream` → `processFirstStreamPacket` →
`handleClientMessage` → `sendExecuteError` → `writeServerPacket` → protobuf
`writeSubmessage` → `Io/Writer.zig` `write` → `@memcpy`):

```
[startup] server ready (1397ms total)
thread 493 panic: @memcpy arguments alias
/root/.zvm/0.16.0/lib/std/Io/Writer.zig:535:34: 0x13dd7c5 in write (geode)
.../protobuf-0.1.3/.../src/protobuf.zig:353:24: 0x194bf99 in writeSubmessage__anon_669593 (geode)
.../protobuf-0.1.3/.../src/protobuf.zig:350:15: 0x194b8f7 in writeSubmessage__anon_669534 (geode)
.../protobuf-0.1.3/.../src/protobuf.zig:590:36: 0x1947443 in writeValue__anon_669245 (geode)
src/server/quic_connection_handler.zig:1118:24: 0x15f43e4 in writeServerPacket (geode)
src/server/quic_connection_handler.zig:1478:24: 0x15f476a in sendExecuteError (geode)
src/server/quic_connection_handler.zig:5895:45: 0x172e2dd in handleClientMessage (geode)
src/server/quic_connection_handler.zig:2606:28: 0x175aa80 in processFirstStreamPacket (geode)
src/server/quic_connection_handler.zig:3551:49: 0x17589d9 in processCooperativeFirstStream (geode)
.../musl/src/thread/pthread_create.c:207:17: 0x1aa4be2 in start
```

### What it means

`Io/Writer.zig:535` is a `@memcpy(dst, src)` where `dst` and `src` **overlap**
(Zig's `@memcpy` requires non-aliasing operands and panics in safe builds when
they alias). The call comes from protobuf `writeSubmessage` while serializing
the **execute-error** server packet (`sendExecuteError` →
`writeServerPacket`). So the path is:

1. A client sends a query on its first stream.
2. The server decides the query errors and calls `sendExecuteError`.
3. Building that error packet, the protobuf submessage writer copies a buffer
   region onto an overlapping region of itself → `@memcpy` alias → panic →
   process exit.

### Why it matters / likely root cause

`writeSubmessage` for length-delimited protobuf fields commonly does
"reserve length prefix → write body → shift body to make room for the encoded
length". If that shift is implemented as a `@memcpy` (rather than `@memmove` /
`copyBackwards`) into the **same** backing buffer, the operands alias and the
program crashes. Candidate fix sites:

- `protobuf-0.1.3/src/protobuf.zig:350` / `:353` (`writeSubmessage`) — use a
  move that tolerates overlap, or serialize the submessage into a scratch
  buffer first and append.
- `src/server/quic_connection_handler.zig:1118` (`writeServerPacket`) — if it
  hands `writeValue`/`writeSubmessage` a writer whose target buffer overlaps
  the source the submessage reads from, decouple them.

The trigger is benign client behavior: **any query that the server answers
with an execute-error crashes the server** as soon as the error response is
serialized. (In this incident the client's boot sequence included
`CREATE INDEX ON :DiveVersion(...)` schema statements and worker dequeue
queries; whichever the server chose to error on, serializing that error
took the process down — the application then sees
`failed to receive HELLO response: context deadline exceeded` / a 30s
statement timeout, never a clean error.)

---

## 2. Crash B — SIGSEGV in `processInitialDatagramConcurrent` → `onPacketSent`

A separate restart on the same node exited **139 (SIGSEGV)** in the QUIC
endpoint's concurrent initial-datagram path:

```
exitCode 139 (SIGSEGV), reason "Error"
.../quic-0.1.22/.../src/quic/recovery/recovery.zig:271:44: 0x12e1bd7 in onPacketSent (geode)
.../quic-0.1.22/.../src/quic/connection/methods_c.zig:201:38: 0x1388bfb in onPacketSent (geode)
.../quic-0.1.22/.../src/quic/endpoint/handshake_integration.zig:992:22: 0x12bc0d7 in sendHandshakePing (geode)
.../quic-0.1.22/.../src/quic/endpoint/incoming.zig:958:51: 0x1385f9a in processInitialResolved (geode)
.../quic-0.1.22/.../src/quic/endpoint.zig:1140:40: 0x138367b in processInitialDatagramConcurrent (geode)
.../quic-0.1.22/.../src/quic/endpoint.zig:1782:66: 0x12bebc0 in pollWithStats (geode)
src/transport/quic.zig:620:47: 0x195bc8f in pollOnce (geode)
src/transport/thread_pool.zig:337:32: 0x159d424 in runSubmittedTask (geode)
.../musl/src/thread/pthread_create.c:207:17: 0x1aa4be2 in start
```

### What it means

`processInitialDatagramConcurrent` processes inbound QUIC **Initial** packets
concurrently across poll workers. The fault is in `onPacketSent` in the loss
recovery (`recovery.zig:271`) reached via `sendHandshakePing` during
`processInitialResolved`. A null/dangling/freed recovery or connection state
dereferenced from a concurrent initial-datagram handler is the classic shape.

This is the **same class** as the fixed `pollCrypto` race
(`QUIC_TLS_POLLCRYPTO_CRASH.md`) — concurrent endpoint poll workers touching
per-connection handshake state — but on a **different code path**
(`processInitialDatagramConcurrent` / `recovery.onPacketSent`, not
`pollCrypto`) and a **different dep version** (`quic-0.1.22`). The pollCrypto
fix serialized deferred per-connection TLS handshake retries; if the
initial-datagram-concurrent path has its own handshake-send (`sendHandshakePing`

- `onPacketSent`) that is *not* behind that per-connection serializer, it can
race the same way.

---

## 3. Trigger & blast radius

- **Trigger:** a client opening connections (and/or issuing a query the server
  errors on) — specifically a *burst* of QUIC Initials (multiple connections
  handshaking at once, e.g. an application's connection pool + worker conns at
  boot) for crash B, and any execute-error response for crash A.
- **A lower-fanout client survives:** the PDS pod (fewer simultaneous conns)
  reconnected and stayed `1/1`; the API pod (pool + worker conns + healthz
  conn, all handshaking together, plus a schema-apply that can error) tripped
  both crashes and could never complete boot.
- **No client-side mitigation fully works:** retry/restart just re-sends the
  triggering burst. The only observed "stable" state was a server that had
  been up long enough to be *wedged but not yet crashed* — new connections
  hung rather than crashing it, but existing connections kept working.

## 4. Reproduction sketch (for the geode team)

1. Start `geode 0.6.13` single node, TLS on, QUIC `:3141`.
2. **Crash A:** from a client, send a query the server will answer with an
   execute-error (e.g. a malformed/duplicate DDL or a statement that fails
   evaluation) on the connection's first stream. Expect the panic in
   `sendExecuteError` → protobuf `writeSubmessage`.
3. **Crash B:** open ~6–8 QUIC connections concurrently (a pool warming up)
   so multiple Initials are processed by `processInitialDatagramConcurrent`
   at once. Expect intermittent SIGSEGV in `recovery.onPacketSent`.

A safe (ReleaseSafe) build turns both into clean panics with these frames; a
release-fast build may instead corrupt memory silently.

## 5. Suggested investigation

- **Crash A (deterministic, highest priority):** audit
  `protobuf.zig` `writeSubmessage` length-prefix backpatch for an in-place
  `@memcpy` over overlapping ranges → switch to an overlap-safe move, or
  serialize submessages into a scratch buffer. Confirm `writeServerPacket` /
  `sendExecuteError` don't alias the read/write buffers. This is the one a
  single errored query reliably hits.
- **Crash B:** route `processInitialDatagramConcurrent`'s handshake-send
  (`sendHandshakePing` → `recovery.onPacketSent`) through the same
  per-connection serialization the `pollCrypto` fix introduced
  (`QUIC_TLS_POLLCRYPTO_CRASH.md` §0, `REQ-QUIC-HC-168`), or otherwise
  guard per-connection recovery state against concurrent initial-datagram
  workers.
- Confirm fixed-or-not on `main` (HEAD `a69cd6ae`); if fixed, cut/pin a
  release so deployments off `0.6.13` get it.

## 6. Cross-references

- `QUIC_TLS_POLLCRYPTO_CRASH.md` — the prior, **fixed** concurrent-handshake
  SIGSEGV (`pollCrypto`, `quic-0.1.21`); same failure *class*, different path
  and version. Crash B here looks like a sibling on `0.1.22`.
- GAP-0838 (cluster TLS / `tests/test_gap0838_cluster_tls_noloopback.zig`,
  `tls v0.1.9` re-pin at HEAD) — the active QUIC/TLS hardening line this
  belongs near.
