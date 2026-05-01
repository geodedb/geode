// Regression test for the upstream OTel BatchSpanProcessor concurrent-producer
// race that surfaces in geode as a `panic: index out of bounds: index N, len M`
// inside `BatchSpanProcessor.drainLocked` at otel/src/sdk/export.zig:330 when
// multiple QUIC connection threads end spans simultaneously.
//
// Production crash from May 01 2026 (geode v0.5.6 / otel pin ee492166):
//
//   thread 178581 panic: index out of bounds: index 512, len 1
//   .../sdk/export.zig:330:38: drainLocked
//   .../sdk/export.zig:457:35: batchOnEnd
//   .../api/trace.zig:216:30: end
//   src/execution.zig:983:19: executeStatementWithContext
//   src/execution.zig:844:50: executeProgramWithContext
//   src/server/quic_connection_handler.zig:3806:74: handleClientMessage
//   src/server/quic_connection_handler.zig:2291:28: handleQuicConnection
//
// Root cause: `BatchSpanProcessor.QueueMutex` (otel/src/sdk/export.zig:170)
// and `span_pool.PoolMutex` collapse to no-op stubs when the build option
// `-Dotel_use_devnw_pool=false` (geode's default), on the assumption that
// only one producer thread ever calls `onEnd`. Geode's QUIC handler pool
// violates that assumption — every inbound stream runs `executeStatementWithContext`
// on a worker thread and ends a `geode.query.execute` span on return,
// racing on the unprotected queue.
//
// Upstream fix: otel commit 0c34ce9b ("fix(bsp): close concurrent-producer
// race in synchronous-drain build") replaces the no-op stubs with a real
// `std.Io.Mutex`. Geode briefly pinned 0c34ce9b in commit 2a9ea3a6 and
// re-added these spans, but commit d7ceaaea reverted the pin to ee492166
// to fix a build-graph diamond (every transitive devnw consumer pins the
// pre-fix SHA). The spans were never re-rolled-back, leaving production
// in a known-buggy state.
//
// This test guards the rollback decision: each banned span name is a
// concurrent-context tracer.startSpan() call that must NOT live in the
// listed source file until the otel pin can advance to 0c34ce9b+ across
// every sibling devnw lib (gql, dns, repl, vulkan, thread_pool, protobuf,
// slog, wal). When the coordinated bump ships, this test should be
// retired (or inverted) alongside re-adding the spans.
//
// Existing precedent for the same rollback pattern: `createEdge` in
// src/storage/graph_storage_adapter.zig:2237 (note left in place since
// the original 2026-04-29 incident).

const std = @import("std");

const BannedSpan = struct {
    // Concurrent-context tracer.startSpan() name to look for. If this
    // string literal is found in `file_path`, the rollback has been
    // undone and the test fails.
    span_name: []const u8,
    // Path relative to the project root (cwd of `zig build test`).
    file_path: []const u8,
};

test "BSP race regression: no concurrent-context spans on hot paths until otel pin advances" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const banned = [_]BannedSpan{
        // src/execution.zig:983 — direct stack-trace site of the panic.
        .{ .span_name = "geode.query.execute", .file_path = "src/execution.zig" },
        // src/graph_store.zig:1197 — emits per node creation; called from
        // every CREATE statement. Same BSP under load.
        .{ .span_name = "geode.graph_store.create_node", .file_path = "src/graph_store.zig" },
        // src/graph_store.zig:1795 — emits per MATCH label lookup; even
        // hotter than create_node under read-heavy workloads.
        .{ .span_name = "geode.graph_store.get_nodes_by_label", .file_path = "src/graph_store.zig" },
        // src/graph_store.zig:3058 — emits per CREATE edge; mirror of
        // create_node. The matching span at graph_storage_adapter.zig:2237
        // was already rolled back during the original incident.
        .{ .span_name = "geode.graph_store.create_edge", .file_path = "src/graph_store.zig" },
        // src/server/quic_connection_handler.zig:1776 — parent span of
        // every inbound QUIC request. Hottest of all five sites because
        // it runs on every client message regardless of statement type.
        .{ .span_name = "geode.transport.request", .file_path = "src/server/quic_connection_handler.zig" },
    };

    // Confirm we're running from the project root by probing for
    // build.zig.zon; if it's not there, `zig build test` was invoked from
    // an unexpected location and the file lookups below would
    // false-fail. Skip rather than emit a misleading regression.
    cwd.access(io, "build.zig.zon", .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    // Source files in geode are well under 1 MiB; the largest
    // (graph_store.zig) is ~340 KiB. Use a generous 16 MiB cap.
    const max_bytes = std.Io.Limit.limited(16 * 1024 * 1024);

    var any_failed = false;
    for (banned) |b| {
        const content = cwd.readFileAlloc(io, b.file_path, allocator, max_bytes) catch |err| {
            std.debug.print(
                "BSP race regression: could not read {s}: {s}\n",
                .{ b.file_path, @errorName(err) },
            );
            return err;
        };
        defer allocator.free(content);

        // Match the Zig string-literal form `"<span_name>"` so rollback
        // comments that mention the span name in backticks
        // (e.g. `` `geode.query.execute` ``) don't trip the guard. A real
        // tracer().startSpan() invocation always passes the span name as
        // a double-quoted Zig string literal.
        var quoted_buf: [128]u8 = undefined;
        const needle = std.fmt.bufPrint(&quoted_buf, "\"{s}\"", .{b.span_name}) catch unreachable;

        if (std.mem.indexOf(u8, content, needle) != null) {
            std.debug.print(
                "BSP race regression: span literal {s} still present in {s}.\n" ++
                    "  This concurrent-context span panics drainLocked at\n" ++
                    "  otel/src/sdk/export.zig:330 under load while the otel pin\n" ++
                    "  remains at ee492166. Roll the span back, or coordinate a\n" ++
                    "  multi-repo bump to otel@0c34ce9b+ (BSP race fix) before\n" ++
                    "  re-enabling. See note at src/storage/graph_storage_adapter.zig:2237.\n",
                .{ needle, b.file_path },
            );
            any_failed = true;
        }
    }
    if (any_failed) return error.BspRaceRegression;
}
