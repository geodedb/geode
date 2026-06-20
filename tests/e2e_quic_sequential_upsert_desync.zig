// CANARY: REQ=REQ-QUIC-HC-180; FEATURE="Sequential Single-Connection Upsert Liveness"; ASPECT=FirstStreamSchedulerLostWake; STATUS=TESTED; TEST=test-quic-sequential-upsert-desync; OWNER=transport; UPDATED=2026-06-19
//
// Regression for the BUG_STREAM_DESYNC / stream-slot-leak-on-sequential-queries
// wedge (production server 5bdfd62, Go driver v0.1.25).
//
// Symptom: a client issues a BURST of SEQUENTIAL upserts (find then create,
// i.e. read-then-write) on ONE long-lived QUIC connection — the keelhaul
// boot-replay pattern. It makes progress, then WEDGES mid-burst: the FIRST
// stream (stream_id=0, serviced by the cooperative first-stream scheduler)
// desyncs and the client blocks on it forever. Server logs show
// `total=<N> active_streams=1 proto_idle_ms=...` with `total` pinned.
//
// Root cause (server-side, src/server/quic_connection_handler.zig): a lost
// wakeup in the cooperative first-stream scheduler. After a turn parks at
// WouldBlock, the RX-ready notifier (`firstStreamReadyCallback`) and the
// worker's `completeCooperativeTurn` race on the
// `cooperative_running` / `cooperative_needs_reschedule` handshake, and the
// idle-sweep backstop is defeated because the WouldBlock generation snapshot
// is taken BEFORE the read. The owner ends up neither queued, nor running,
// nor re-armed, while the client's next request sits unread.
//
// This is NOT the concurrent PipelineExec path: exactly ONE request is ever
// in flight (the client is synchronous), on ONE connection. The reproduction
// drives a long back-to-back sequence of find+create and asserts the
// connection keeps serving (no stall, slots reclaimed) for 200+ ops.
//
// Before the fix: one op eventually hangs and the per-op read times out, so
// the run fails. After the fix: all ops complete.
//
// Built as an executable (not a `zig test`) for the same reason as
// e2e_quic_high_concurrency.zig: builtin.is_test enables verbose byte dumps in
// the vendored QUIC dependency that turn this into allocator churn.

const std = @import("std");
const builtin = @import("builtin");
const util = @import("proto_test_util.zig");

// Keep the op count comfortably above the "200+ sequential ops" requirement.
// In Debug the binary is slower, so keep it bounded but still well past the
// point where the production wedge reproduced (it pinned around total≈148).
const default_op_count: u32 = if (builtin.mode == .Debug) 250 else 400;

// Per-op execute/read timeout. The wedge manifests as a single op never
// receiving its response; a tight-but-generous timeout turns that hang into a
// fast, deterministic failure instead of letting the harness block forever.
const per_op_timeout_secs: u32 = 8;

// Overall safety net: if the whole run somehow exceeds this, abort loudly.
const overall_deadline_secs: u64 = 180;

fn monoNs() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    const rc = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    if (rc != 0) return 0;
    const sec: u64 = if (ts.sec < 0) 0 else @intCast(ts.sec);
    const nsec: u64 = if (ts.nsec < 0) 0 else @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

fn envU32(name: [*:0]const u8, default_value: u32) u32 {
    const raw = std.c.getenv(name) orelse return default_value;
    const value = std.mem.span(raw);
    if (value.len == 0) return default_value;
    return std.fmt.parseUnsigned(u32, value, 10) catch default_value;
}

fn expectNoQueryError(res: *const util.ExecResult) !void {
    if (res.error_code) |code| {
        std.debug.print("sequential upsert query returned error_code={s}", .{code});
        if (res.error_message) |msg| std.debug.print(" message={s}", .{msg});
        std.debug.print("\n", .{});
        return error.QueryReturnedError;
    }
}

pub fn main() !void {
    // Match e2e_quic_high_concurrency.zig: the shared smp allocator avoids the
    // is_test allocator churn and is the established pattern for these e2e exes.
    const allocator = std.heap.smp_allocator;

    const op_count = envU32("GEODE_SEQ_UPSERT_OPS", default_op_count);

    // Drive the cooperative first-stream scheduler (default on) with a SMALL
    // worker pool and a tight mutation-admission window. Fewer workers widen
    // the completeCooperativeTurn vs firstStreamReadyCallback race window, and
    // a tight admission cap exercises the serial-mutation park/re-arm path —
    // both implicated in the lost-wake wedge. These are server defaults the
    // production deployment also uses; we only narrow them to make the
    // (otherwise rare-in-time but deterministic-in-mechanism) wedge reliably
    // surface within a few hundred ops.
    const server_env = [_][]const u8{
        "GEODE_QUIC_COOPERATIVE_FIRST_STREAMS=1",
        "GEODE_QUIC_COOPERATIVE_FIRST_STREAM_WORKERS=2",
        "GEODE_QUIC_POLL_WORKERS=1",
        "GEODE_QUIC_MUTATION_ADMISSION_CAP=1",
        "GEODE_QUIC_CONNECTION_WORKERS=2",
    };

    var server = util.spawnServerRandom(allocator, &server_env) catch |err| {
        std.debug.print("sequential upsert desync: server spawn failed: {}\n", .{err});
        // A spawn failure (e.g. no openssl in env) is an environment problem,
        // not a regression; skip rather than fail the suite.
        std.process.exit(0);
    };
    defer server.deinit();

    const addr = server.getAddr();
    std.debug.print("sequential upsert desync: connecting to {s} ops={d}\n", .{ addr, op_count });

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();

    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    // Use a dedicated label so this run is independent of any other state.
    const run_start_ns = monoNs();
    const overall_deadline_ns = run_start_ns +| overall_deadline_secs * std.time.ns_per_s;

    var i: u32 = 0;
    while (i < op_count) : (i += 1) {
        if (monoNs() > overall_deadline_ns) {
            std.debug.print(
                "sequential upsert desync: WEDGED — overall deadline exceeded at op {d}/{d} (per-connection proto_reader stalled)\n",
                .{ i, op_count },
            );
            return error.SequentialUpsertWedged;
        }

        // FIND (read): the keelhaul replay first looks up the node by id.
        const find_query = try std.fmt.allocPrint(
            allocator,
            "MATCH (n:SeqUpsert {{ id: {d} }}) RETURN n",
            .{i},
        );
        defer allocator.free(find_query);

        var find_res = client.executeAndCollectWithTimeout(
            allocator,
            find_query,
            util.emptyParams(),
            128,
            per_op_timeout_secs,
        ) catch |err| {
            std.debug.print(
                "sequential upsert desync: WEDGED on FIND op {d}/{d}: {s} " ++
                    "(stream desync — client blocked waiting for response on stream_id=0)\n",
                .{ i, op_count, @errorName(err) },
            );
            return err;
        };
        find_res.deinit(allocator);

        // CREATE (write): the replay then inserts the node. Read-then-write on
        // the same connection is the exact pattern that wedges.
        const create_query = try std.fmt.allocPrint(
            allocator,
            "CREATE (n:SeqUpsert {{ id: {d}, seq: {d} }})",
            .{ i, i },
        );
        defer allocator.free(create_query);

        var create_res = client.executeAndCollectWithTimeout(
            allocator,
            create_query,
            util.emptyParams(),
            128,
            per_op_timeout_secs,
        ) catch |err| {
            std.debug.print(
                "sequential upsert desync: WEDGED on CREATE op {d}/{d}: {s} " ++
                    "(stream desync — client blocked waiting for response on stream_id=0)\n",
                .{ i, op_count, @errorName(err) },
            );
            return err;
        };
        defer create_res.deinit(allocator);
        try expectNoQueryError(&create_res);

        if (i != 0 and i % 50 == 0) {
            std.debug.print("sequential upsert desync: progress {d}/{d} ops ok\n", .{ i, op_count });
        }
    }

    // Final liveness probe: after the burst, a plain count must still be
    // served on the SAME connection — proves the per-connection proto_reader
    // is still delivering and stream slots were reclaimed.
    var count_res = client.executeAndCollectWithTimeout(
        allocator,
        "MATCH (n:SeqUpsert) RETURN count(n) AS c",
        util.emptyParams(),
        128,
        per_op_timeout_secs,
    ) catch |err| {
        std.debug.print(
            "sequential upsert desync: WEDGED on final liveness probe after {d} ops: {s}\n",
            .{ op_count, @errorName(err) },
        );
        return err;
    };
    defer count_res.deinit(allocator);
    try expectNoQueryError(&count_res);

    const elapsed_ms = (monoNs() -| run_start_ns) / std.time.ns_per_ms;
    std.debug.print(
        "sequential upsert desync: PASS — {d} sequential find+create ops on one connection, no desync ({d} ms)\n",
        .{ op_count, elapsed_ms },
    );
}
