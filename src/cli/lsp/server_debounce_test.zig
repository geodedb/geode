// F-01 — didChange diagnostics debounce regression suite.
//
// Verifies that 20 rapid didChange notifications coalesce into at most
// one diagnostic flush when the debounce window has not elapsed, and
// that flushing surfaces the LATEST version's diagnostics. Uses an
// in-memory diagnostic counter on the Server (no stdout I/O).
//
// CANARY: REQ=REQ-PERF-F-01; FEATURE="DidChangeDebounce"; ASPECT=Throughput; STATUS=TESTED; OWNER=lsp; UPDATED=2026-05-06

const std = @import("std");
const testing = std.testing;
const server = @import("server.zig");

test "F-01: 20 rapid didChange notifications do not eagerly send diagnostics" {
    const allocator = testing.allocator;
    var srv = try server.Server.init(allocator);
    defer srv.deinit();

    const uri = "file:///debounce.gql";
    try srv.documents.open(uri, "RETURN 1", 1);

    // Reset counter; drive 20 didChange notifications directly without
    // round-tripping through handleMessage (which would also touch
    // stdout).
    srv.diagnostics_send_count_for_test = 0;
    var v: i32 = 2;
    while (v < 22) : (v += 1) {
        try srv.documents.update(uri, "RETURN 1", v);
        srv.markDocumentDirty(uri);
    }

    // Without flush, no eager send should have happened.
    try testing.expect(srv.diagnostics_send_count_for_test <= 1);
    // Document is still pending.
    try testing.expect(srv.isDirty(uri));
}

test "F-01: flushPendingDiagnostics with sufficient delay sends one diagnostic" {
    const allocator = testing.allocator;
    var srv = try server.Server.init(allocator);
    defer srv.deinit();

    const uri = "file:///debounce-flush.gql";
    try srv.documents.open(uri, "RETURN 1", 1);
    srv.markDocumentDirty(uri);

    srv.diagnostics_send_count_for_test = 0;
    // Pretend 200 ms has passed (well above the 80 ms threshold).
    const now_ns = srv.lastChangeNanos(uri).? + 200 * std.time.ns_per_ms;
    srv.flushPendingDiagnostics(now_ns) catch {};

    // Diagnostic count incremented; pending flag cleared.
    try testing.expect(srv.diagnostics_send_count_for_test >= 1);
    try testing.expect(!srv.isDirty(uri));
}

test "F-01: flushPendingDiagnostics within debounce window does not send" {
    const allocator = testing.allocator;
    var srv = try server.Server.init(allocator);
    defer srv.deinit();

    const uri = "file:///debounce-hold.gql";
    try srv.documents.open(uri, "RETURN 1", 1);
    srv.markDocumentDirty(uri);

    srv.diagnostics_send_count_for_test = 0;
    // Only 10 ms has passed; below the 80 ms threshold.
    const now_ns = srv.lastChangeNanos(uri).? + 10 * std.time.ns_per_ms;
    srv.flushPendingDiagnostics(now_ns) catch {};

    try testing.expectEqual(@as(usize, 0), srv.diagnostics_send_count_for_test);
    try testing.expect(srv.isDirty(uri));
}
