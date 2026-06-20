# BUG_STREAM_DESYNC — sequential single-connection request/response wedge

Status: **root-caused; fix is in the vendored `quic` dependency (cascade required)**
Branch: `bug-stream-desync-sequential`
Date: 2026-06-19

## Symptom (production, server 5bdfd62 / Go driver geodedb.com/geode v0.1.25)

A client issues a BURST of SEQUENTIAL upserts (find then create — read-then-write)
on ONE long-lived QUIC connection (keelhaul replaying an event log at boot). It
makes progress, then WEDGES mid-burst; the client blocks forever on the
in-flight request. Server logs:

```
total=148 active_streams=1 proto_idle_ms=136645
per-connection proto_reader stall: stream_id=0 peer=... idle_ms=136645
  (every stream on this connection idle past threshold; client likely gone —
   connection will be reaped on its own timeout)
```

`total` (messages delivered) pins, `active_streams=1`, and the per-connection
`proto_reader` idle time climbs without bound on `stream_id=0`.

## Reproduction

`tests/e2e_quic_sequential_upsert_desync.zig` (build step
`test-quic-sequential-upsert-desync`).

It spawns a real geode server, opens ONE QUIC connection, seeds ONE node, then
issues a long back-to-back sequence of `MATCH (n:SeqUpsert {id:0}) RETURN n`
(read) followed by `MATCH (n:SeqUpsert {id:0}) SET n.seq = <i>` (write) — the
keelhaul read-then-write pattern. The node set is fixed at one node so the
per-op SERVER work is constant; any per-op growth is therefore transport-layer,
not storage `O(n)`.

It is built as an executable (not a `zig test`) for the same reason as
`tests/e2e_quic_high_concurrency.zig`: `builtin.is_test` turns on verbose byte
dumps in the vendored QUIC dependency.

It is intentionally NOT wired into the default `test_e2e_step` because it is a
known-failing regression pending the quic-dependency fix below (see build.zig).

### Observed behavior (deterministic)

On current code the per-op latency grows roughly linearly with the per-connection
request count and the connection eventually wedges:

```
op 0   ~17 ms
op 50  ~170 ms
op 100 ~600 ms
op 150 ~150 ms..1200 ms (variance)
op ~146-166  per-op latency exceeds the 8s timeout / overall deadline -> WEDGE
```

The server-side runtime metrics during the slow regime localize the cost to the
single QUIC poll worker's inbound-packet frame processing:

```
quic_poll_cycle_max_ns                ~ 80-98 ms   (and growing)
quic_poll_recv_short_frame_process_max_ns ~ 66-79 ms (the dominant chunk)
quic_first_stream_packet_process_max_ns ~ 0.67 ms   (application handling is fine)
quic_stream_write_elapsed_max_ns       ~ 0.37 ms    (response write is fine)
```

A `perf` profile of the server in the slow regime shows the CPU is dominated by
`Wyhash` + `HashMap(u64,…).getOrPut`, `recovery.*`, and thread-pool idle/futex —
i.e. QUIC recovery/congestion bookkeeping and waiting, NOT application logic or
storage.

This is the same phenomenon as the production hard wedge: per-connection
sustained-load degradation that grows until per-op latency exceeds the QUIC idle
timeout, at which point the `proto_reader` is permanently idle and the connection
is reaped.

## Root cause — vendored `quic` dependency (NOT geode)

The defect is entirely within the pinned `quic` dependency
(`build.zig.zon` → `.quic` = v0.1.31, `02cee4a`), in its loss-recovery /
congestion bookkeeping on the receive (ACK-processing) path. The hot path is the
single QUIC poll worker's per-inbound-packet frame processing
(`src/quic/endpoint/incoming/module_b2.zig processFrames` →
`frame_handler.handleAck` → `connection/methods_b.zig onAckReceivedSpace` →
`recovery/recovery.zig onAckReceivedWithEcn`).

Concretely, `recovery/recovery.zig` keeps a per-space `sent: ArrayList(SentPacket)`
and scans it multiple times per received ACK (unprocessed-count scan, loss
detection, and `sent_index` rebuild in `compact()`). The list is only compacted
of `acked`/`declared_lost` entries and only hard-capped at 4096. Two concrete
contributors were confirmed:

1. **Non-ack-eliciting (ACK-only) packets are tracked in `sent`.**
   `Recovery.onPacketSent` appends EVERY sent packet, including the ACK-only
   packet the server emits in response to each received request. Per
   RFC 9002 §A.1 only ack-eliciting packets need tracking; ACK-only packets are
   never individually acknowledged by the peer and are never retransmitted, so
   they can never become `acked` and (being below the packet-loss threshold most
   of the time) are never `declared_lost`. They therefore accumulate in `sent`
   (~1 per request) until the 4096 cap, and every ACK re-scans the growing list.

2. **`connection/methods_b.zig` `app_stream_retx`** (a `HashMap(u64,
   StreamTxPacket)` of sent STREAM packets) is iterated in full by
   `retransmitLostStreamPackets` on EVERY ACK, and entries are removed only on an
   exact-PN ACK match (the expansion is capped at 256 PNs in
   `onAckReceivedSpace`) or on retransmit — so cumulatively-acked-but-not-
   enumerated packets can leak.

The net effect is `O(n)` per-ACK work that grows with the number of
request/response cycles on a single long-lived connection, i.e. `O(n^2)`
cumulative, executed serially on the single QUIC poll worker. As it grows the
per-connection `proto_reader` is starved of poll cycles, its idle time climbs,
and the connection eventually wedges/reaps — the reported symptom.

### Candidate quic-lib fix (apply in the `quic` repo, then release + cascade)

In `src/quic/recovery/recovery.zig`, `Recovery.onPacketSent`: only append
ack-eliciting packets to `sent`/`sent_index` (RFC 9002 §A.1):

```zig
if (ack_eliciting) {
    try self.spaces[idx].sent.append(alloc, .{ .pn = pn, .time_ns = now_ns, .size = bytes, .ack_eliciting = ack_eliciting });
    try self.spaces[idx].sent_index.put(pn, self.spaces[idx].sent.items.len - 1);
    if (self.spaces[idx].sent.items.len > max_sent_packets) {
        self.spaces[idx].compact();
        self.spaces[idx].enforceCapacity(&self.cc);
    }
}
```

This was VERIFIED to bound `recovery.sent` to ~0 in the reproduction (server
`sent.len` dropped from ~1300-and-growing to 0). It is NECESSARY but, on its own,
NOT SUFFICIENT: the reproduction still degrades, indicating at least one more
accumulator in the dependency's congestion/recovery/pacing interaction (the
`app_stream_retx` full-map scan in `retransmitLostStreamPackets`, and/or a
congestion-control / PTO / pacing feedback effect). A complete fix should:

- restrict `sent` tracking to ack-eliciting packets (above);
- prune `app_stream_retx` cumulatively (drop entries with `pn <= largest_acked`
  after `retransmitLostStreamPackets`, keeping a small reorder margin), instead
  of only on exact-PN ACK match;
- replace the per-ACK full-`sent` linear scans with index/cursor-based processing
  so ACK handling is bounded by the in-flight window, not the connection's total
  sent history;
- be validated against the quic library's own RFC 9002 recovery test suite
  (`tests/integration/rfc9002_recovery.zig`, `tests/unit/recovery/test_recovery.zig`).

### Cascade (DO NOT perform here)

Fixing this requires:

1. Land the fix in `gitlab.com/devnw/zig/quic` and cut a new tag (e.g. v0.1.32).
2. Bump the `.quic` pin (url+ref+hash) in geode `build.zig.zon`.
3. Per the diamond-deps convention, bump the matching quic pin in
   `geode-client-zig` in lockstep (else `detect-diamond-deps` /
   "file exists in modules 'quic' and 'quic0'" blocks the commit), and the
   `quic-zig`/`geode-client-zig` sibling pins as required.

This branch deliberately does NOT perform the cascade; it provides the
deterministic reproduction and the root-cause/fix identification.

## Server-side (geode) angle investigated and ruled out

The cooperative first-stream scheduler
(`src/server/quic_connection_handler.zig`: `processCooperativeFirstStream`,
`completeCooperativeTurn`, `firstStreamReadyCallback`, the
`cooperative_running`/`cooperative_needs_reschedule`/`cooperative_generation_seen`
state machine) was examined in detail as a candidate (lost-wakeup / stale
generation snapshot). It was ruled out: the reproduction degrades and wedges
IDENTICALLY with the cooperative scheduler DISABLED
(`GEODE_QUIC_COOPERATIVE_FIRST_STREAMS=0`, which routes the first stream through
the legacy persistent loop), and even a PING-only loop (no query, no mutation, no
graph access) on a reused connection exhibits the same unbounded per-op growth.
The accumulation is therefore in the shared per-connection QUIC transport path,
i.e. the vendored dependency, not in geode's request handling.

## Residual risk

- The candidate quic-lib fix (ack-eliciting-only `sent` tracking) is verified to
  remove one accumulator but does not, by itself, fully resolve the reproduction;
  the complete fix needs the additional dependency-side work listed above plus
  validation against the quic recovery test suite.
- The reproduction's absolute timing (op count at which it wedges) depends on host
  load; the QUALITATIVE signal (per-op latency grows without bound on one
  connection) is deterministic.
