// SONNY-6436 item 7: the QUIC side of SONNY-6425 item 6.
//
// `geode query --file`: when the server rejects a chunk, the CLI retries its
// statements one at a time over ONE QUIC connection
// (`retryChunkStatementByStatement`). When a retried statement was sent and
// got no answer (the client's --timeout, a dropped connection), its QUIC
// branch returned the transport error, and the caller counted one error and
// went on with the NEXT chunk on a new connection: statements were written
// after one whose outcome is unknown (it may still be running, or have been
// applied), and the statements after it in the chunk were silently lost. The
// gRPC branch stops the run there with the summary (SONNY-6425); the QUIC
// branch now does the same.
//
// The server, the CLI and the wire protocol are real. The file's first
// chunk holds a statement that runs longer than the client's 2 s --timeout,
// padding, and a statement that does not parse (so the server rejects the
// chunk without running any of it); the second chunk CREATEs
// `:Sonny6436After` nodes.
//
// CANARY: REQ=REQ-SONNY-6436-QUIC-RETRY-STOPS; FEATURE="ChunkedExecution"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6436_quic_retry_stops.zig; OWNER=cli; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const test_ports = @import("test_ports.zig");
const h = @import("test_sonny6377_query_no_resend.zig");

const linux = std.os.linux;

/// Nodes the slow statement crosses three times (pad_nodes^3 rows).
const pad_nodes: usize = 260;
const slow_stmt = "MATCH (a:Sonny6436Pad), (b:Sonny6436Pad), (c:Sonny6436Pad) RETURN count(*) AS n;\n";
const after_label = "Sonny6436After";

fn sleepMs(ms: u64) void {
    var req = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&req, null);
}

const exe = geode_test_bin.geode_exe;

fn query(aa: std.mem.Allocator, addr: []const u8, q: []const u8, timeout_s: []const u8) !h.Run {
    return h.runGeode(aa, &.{ exe, "query", "--server", addr, "--insecure", "--no-saved-session", "--format", "json", "-U", h.admin_user, "-P", h.admin_pw, "--timeout", timeout_s, q }, 300_000);
}

/// `count(n)` of `label`, read with the CLI.
fn readCount(aa: std.mem.Allocator, addr: []const u8, label: []const u8) !i64 {
    const q = try std.fmt.allocPrint(aa, "MATCH (n:{s}) RETURN count(n) AS c", .{label});
    const r = try query(aa, addr, q, "120");
    const at = std.mem.indexOf(u8, r.output, "\"c\":") orelse {
        std.debug.print("count read-back exited {d}:\n{s}\n", .{ r.code, r.output });
        return error.ReadBackFailed;
    };
    var i = at + 4;
    while (i < r.output.len and r.output[i] == ' ') i += 1;
    const start = i;
    while (i < r.output.len and std.ascii.isDigit(r.output[i])) i += 1;
    return std.fmt.parseInt(i64, r.output[start..i], 10);
}

/// The file: chunk 1 = the slow statement, padding, a statement that does not
/// parse; then CREATEs past the 32 KiB chunk limit (chunk 2).
fn buildFile(aa: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(aa, slow_stmt);
    const pad = "p" ** 960;
    for (0..27) |i| try buf.print(aa, "RETURN {d} AS i, '{s}' AS pad;\n", .{ i, pad });
    try buf.appendSlice(aa, "CREATE (n:Sonny6436Bad {i: });\n");
    for (0..16) |i| try buf.print(aa, "CREATE (:{s} {{i: {d}, pad: '{s}'}});\n", .{ after_label, i, pad });
    return buf.toOwnedSlice(aa);
}

test "SONNY-6436 item 7: a retried statement whose QUIC request was sent and got no answer stops the run with the summary; no later chunk is sent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try h.freshDir(aa, "sonny6436-quic-retry-stops");
    defer h.removeDir(dir);
    const addr = try util.formatAddr(aa, try test_ports.freeUdpPort());
    var server = try util.spawnServer(testing.allocator, &.{ exe, "serve", "--listen", addr, "--data-dir", dir }, util.TestEnv.standard());
    defer server.deinit();
    try util.waitForServerReady(testing.allocator, addr, 60_000);

    // The slow statement's input.
    var seed: std.ArrayList(u8) = .empty;
    try seed.appendSlice(aa, "CREATE ");
    for (0..pad_nodes) |i| try seed.print(aa, "{s}(:Sonny6436Pad {{i: {d}}})", .{ if (i == 0) "" else ", ", i });
    const seeded = try query(aa, addr, seed.items, "120");
    if (seeded.code != 0) {
        std.debug.print("seeding failed:\n{s}\n", .{seeded.output});
        return error.FixtureSeedFailed;
    }

    const content = try buildFile(aa);
    try testing.expect(content.len > 32 * 1024);
    const path = try std.fmt.allocPrint(aa, "{s}/chunks.gql", .{dir});
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = content });

    const r = try h.runGeode(aa, &.{ exe, "query", "--server", addr, "--insecure", "--no-saved-session", "--format", "json", "-U", h.admin_user, "-P", h.admin_pw, "--timeout", "2", "--file", path }, 300_000);

    if (!h.contains(r.output, "using chunked execution")) {
        std.debug.print("fixture did not chunk:\n{s}\n", .{r.output});
        return error.FixtureDidNotChunk;
    }
    if (!h.contains(r.output, "retrying its")) {
        std.debug.print("fixture: the chunk was not retried statement by statement:\n{s}\n", .{r.output});
        return error.FixtureNoRetry;
    }
    // Guard: the slow statement really outlasted the client's deadline.
    if (!h.contains(r.output, "Timeout") and !h.contains(r.output, "timed out")) {
        std.debug.print("fixture: the slow statement did not time out:\n{s}\n", .{r.output});
        return error.FixtureNoTimeout;
    }

    // Let the server finish the slow statement (and anything queued behind
    // it): a write waits for it, then the count is read until it settles.
    const probe = try query(aa, addr, "CREATE (:Sonny6436Probe {i: 1})", "240");
    if (probe.code != 0) {
        std.debug.print("probe write failed:\n{s}\n", .{probe.output});
        return error.ProbeFailed;
    }
    var after: i64 = -1;
    for (0..3) |_| {
        after = @max(after, try readCount(aa, addr, after_label));
        sleepMs(1_500);
    }

    var violations: usize = 0;
    if (after != 0) {
        std.debug.print("VIOLATION: {d} :{s} node(s) written; the run went on after a statement whose outcome is unknown (expected 0)\n", .{ after, after_label });
        violations += 1;
    }
    if (!h.contains(r.output, "Chunked execution complete")) {
        std.debug.print("VIOLATION: no chunked-execution summary was printed\n", .{});
        violations += 1;
    }
    if (!h.contains(r.output, "were not executed")) {
        std.debug.print("VIOLATION: the run did not say the statements after it were not executed\n", .{});
        violations += 1;
    }
    if (!h.contains(r.output, "may still be executing")) {
        std.debug.print("VIOLATION: the run did not say the statement may still be executing\n", .{});
        violations += 1;
    }
    if (r.code != 4) {
        std.debug.print("VIOLATION: exited {d}; expected 4 (timeout_error, as a chunk that times out)\n", .{r.code});
        violations += 1;
    }
    if (violations > 0) {
        std.debug.print("transcript:\n{s}\n", .{r.output});
        return error.RunContinuedAfterUnknownOutcome;
    }
}
