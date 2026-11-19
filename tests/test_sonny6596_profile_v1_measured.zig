//! SONNY-6596 item 2: a version-1 PROFILE payload reports what the
//! execution measured, nothing invented.
//!
//! The version-1 payload answers a PROFILE the planned read runtime does not
//! serve (a data change, a UNION, a tenant-bound session). It was a fixed
//! model: a `PROFILE CREATE` listed NodeScan, Expand and Project operators,
//! a UNION UnionLeft / UnionTails / UnionDedup / SetOpUnion, each with
//! `time_ns = 10 * (i + 1)`, `cpu_time_ns = 5 * (i + 1)`, 64 bytes
//! allocated, made-up planner estimates, and a UNION's `input_rows` as the
//! part count times the output rows. None of it came from the execution.
//!
//! Now the legacy executor's statement is one `LegacyExecute` operator (the
//! name the version-2 trace uses for the same thing) with the wall-clock
//! time measured around it and the rows it returned; what was not measured
//! (CPU time, bytes, estimates, a UNION's input rows) is 0 or absent.
//! Checked over QUIC and gRPC against a real `geode serve`.
//!
//! CANARY: REQ=REQ-SONNY-6596-PROFILE-V1-MEASURED; FEATURE="PROFILE"; ASPECT=NoSyntheticOperators; STATUS=TESTED; TEST=tests/test_sonny6596_profile_v1_measured.zig; OWNER=engine; UPDATED=2026-11-15

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const geode = @import("geode");
const util = @import("proto_test_util.zig");
const grpc_query_transport = geode.grpc_query_transport;
const query_runner = geode.query_runner;

const Case = struct { query: []const u8, rows: i64, union_mode: ?[]const u8 = null };

const cases = [_]Case{
    .{ .query = "PROFILE CREATE (:P6596 {k: 1})", .rows = 0 },
    .{ .query = "PROFILE RETURN 1 AS x UNION RETURN 2 AS x", .rows = 2, .union_mode = "DISTINCT" },
    .{ .query = "PROFILE RETURN 1 AS x UNION ALL RETURN 1 AS x", .rows = 2, .union_mode = "ALL" },
};

fn intOf(v: std.json.Value) i64 {
    return switch (v) {
        .integer => |i| i,
        else => -1,
    };
}

/// The number of ways `json`, a version-1 payload for `c`, departs from the
/// measured shape; each is printed.
fn failuresOf(c: Case, transport: []const u8, json: []const u8) !usize {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    var failures: usize = 0;
    const version = intOf(root.get("profile_version").?);
    if (version != 1) {
        std.debug.print("{s} [{s}]: expected a version-1 payload: {s}\n", .{ c.query, transport, json });
        return 1;
    }
    const ops = root.get("ops").?.array.items;
    var sum_time: i64 = 0;
    if (ops.len != 1) {
        std.debug.print("{s} [{s}]: expected one LegacyExecute operator, got {d}\n", .{ c.query, transport, ops.len });
        failures += 1;
    }
    for (ops) |op| {
        const o = op.object;
        const name = o.get("op").?.string;
        if (!std.mem.eql(u8, name, "LegacyExecute")) {
            std.debug.print("{s} [{s}]: operator {s} was not run\n", .{ c.query, transport, name });
            failures += 1;
        }
        const t = intOf(o.get("time_ns").?);
        sum_time += t;
        if (t <= 0) failures += 1;
        if (intOf(o.get("rows").?) != c.rows) failures += 1;
        // Not measured: CPU time, bytes, estimates.
        for ([_][]const u8{ "cpu_time_ns", "bytes_out", "bytes_alloc", "estimate_bytes", "estimate_vs_actual", "percent_peak", "net_after_op" }) |k| {
            if (o.get(k)) |v| if (intOf(v) != 0) {
                std.debug.print("{s} [{s}]: {s} {s} = {d} was not measured\n", .{ c.query, transport, name, k, intOf(v) });
                failures += 1;
            };
        }
    }
    if (intOf(root.get("total_time_ns").?) != sum_time) failures += 1;
    if (root.get("planner_estimates") != null) {
        std.debug.print("{s} [{s}]: planner_estimates without a planner\n", .{ c.query, transport });
        failures += 1;
    }
    const memory = root.get("memory").?.object;
    for ([_][]const u8{ "net_bytes", "peak_bytes", "total_alloc_bytes" }) |k| {
        if (intOf(memory.get(k).?) != 0) failures += 1;
    }
    if (c.union_mode) |mode| {
        const setop = root.get("setop").?.object;
        if (!std.mem.eql(u8, setop.get("mode").?.string, mode)) failures += 1;
        if (intOf(setop.get("output_rows").?) != c.rows) failures += 1;
        // The parts' rows are not counted.
        if (intOf(setop.get("input_rows").?) != 0) {
            std.debug.print("{s} [{s}]: setop input_rows {d} was not measured\n", .{ c.query, transport, intOf(setop.get("input_rows").?) });
            failures += 1;
        }
    }
    if (failures > 0) std.debug.print("{s} [{s}]: {s}\n", .{ c.query, transport, json });
    return failures;
}

test "SONNY-6596: a version-1 PROFILE reports the measured execution, no invented operators or figures (QUIC and gRPC)" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    const quic_port = try util.getRandomPort();
    var grpc_port = try util.getRandomTcpPort();
    while (grpc_port == quic_port) grpc_port = try util.getRandomTcpPort();
    const quic_addr = try util.formatAddr(a, quic_port);
    defer a.free(quic_addr);
    const grpc_addr = try util.formatAddr(a, grpc_port);
    defer a.free(grpc_addr);

    var handle = try util.spawnServer(a, &.{ geode_test_bin.geode_exe, "serve", "--listen", quic_addr, "--listen-grpc", grpc_addr }, util.TestEnv.grpcPlaintext());
    defer handle.deinit();
    try util.waitForServerReady(a, quic_addr, 10000);

    var quic = try util.QuicProtoClient.connect(a, quic_addr);
    defer quic.deinit();
    var hq = try quic.hello(a, util.defaultUsername(), util.defaultPassword());
    hq.deinit(a);

    var failures: usize = 0;
    for (cases) |c| {
        const json = try quic.executeProfileJson(a, c.query);
        defer a.free(json);
        failures += try failuresOf(c, "quic", json);

        if (!util.grpc_plaintext_served) continue; // SONNY-6782: Debug-only plaintext gRPC
        var grpc = try util.GrpcProtoClient.connect(a, grpc_addr);
        defer grpc.deinit();
        var hg = try grpc.hello(a, util.defaultUsername(), util.defaultPassword());
        hg.deinit(a);
        var adapter = grpc_query_transport.StreamingQueryAdapter{ .stream = grpc.stream, .stream_ids = &grpc.stream_ids };
        var transport = adapter.asTransport();
        var result = try query_runner.collectQueryWithTransport(a, &transport, .{
            .session_id = grpc.session_id,
            .query_text = c.query,
            .format = "json",
            .timeout_secs = 10,
            .page_size = 100,
            .params = util.emptyParams(),
        });
        defer result.deinit();
        if (result.has_error) {
            std.debug.print("{s} [grpc]: {s} {s}\n", .{ c.query, result.error_status, result.error_message });
            return error.QueryFailed;
        }
        failures += try failuresOf(c, "grpc", result.result_payload orelse return error.MissingProfile);
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
