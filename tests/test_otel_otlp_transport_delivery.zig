// SPDX-License-Identifier: Apache-2.0
// Copyright 2024-2026 CodePros
//
// Regression: OTLP/HTTP telemetry transport compiled OUT (RED until the
// build.zig flag-forwarding fix lands).
//
// ROOT CAUSE
// ----------
// geode's build.zig accepts the `-Dotel_use_devnw_tls` build option but
// DISCARDS it (`_ = b.option(bool, "otel_use_devnw_tls", ...)` at
// build.zig:246) and never forwards it to the `otel` dependency
// (build.zig:425 calls `b.dependency("otel", .{ .target, .optimize })`
// with NO `.otel_use_devnw_tls` field). Consequently the otel package's
// own build.zig (`otel_use_devnw_tls` orelse false) compiles the otel
// module with `build_options.use_devnw_tls == false`.
//
// The real `std.http.Client` transport in the otel library is gated on
// exactly that flag:
//
//   src/exporters/otlp_http/transport.zig:139
//       if (!build_options.use_devnw_tls) return error.UnsupportedTransport;
//
// With the flag false the transport short-circuits to
// `error.UnsupportedTransport` BEFORE any IO. The PeriodicMetricReader's
// retry loop classifies that as retryable and silently drops every batch
// (`error.RetryExhausted`), so geode opens ZERO sockets to the collector
// despite logging "OTLP/HTTP push enabled". Result: total telemetry loss
// on the OTLP push path.
//
// THE FIX (separate step — DO NOT implement here)
// -----------------------------------------------
// build.zig will capture `otel_use_devnw_tls` (default true) and forward
// `.otel_use_devnw_tls = otel_use_devnw_tls` into the `b.dependency("otel",
// ...)` call. Because every geode otel module derives from the single
// `otel_dep.module("otel")` instance, the flag then propagates to all otel
// consumers — including this test target.
//
// WHAT THIS TEST GUARDS
// ---------------------
// This test imports the SAME `otel` module instance the production code
// uses (wired via `addImport("otel", otel_mod)` in build.zig, identical to
// the existing `test-otel-facade-smoke` target). It reads the otel
// library's re-exported compile-time configuration — `otel.build_options`
// — which is the exact switch `transport.zig:139` branches on.
//
//   * BEFORE fix (current): geode discards the flag, otel is compiled with
//     `use_devnw_tls == false`, the transport is compiled OUT. The primary
//     assertion below FAILS (RED).
//   * AFTER fix: geode forwards the flag, otel is compiled with
//     `use_devnw_tls == true`, the real transport is compiled IN. The
//     assertion PASSES (GREEN).
//
// No mocks, no simulation: the assertion reads the production transport's
// own compile-time gate, and the corroboration test constructs the real
// `OtlpHttpExporter` and wires its `io` exactly the way geode does in
// src/monitoring/otel_metrics.zig:84,351.

const std = @import("std");
const otel = @import("otel");

// ---------------------------------------------------------------------------
// PRIMARY REGRESSION GUARD
// ---------------------------------------------------------------------------
//
// The transport at `otel/src/exporters/otlp_http/transport.zig:139` is
// compiled in iff `build_options.use_devnw_tls` is true. The otel library
// re-exports that exact compile-time value as `otel.build_options`
// (otel/src/otel.zig:37: `pub const build_options = @import("build_options");`).
//
// Reading it here — through the same `@import("otel")` module instance the
// production code and the metric reader use — is the load-bearing RED→GREEN
// flip: it is the single source of truth for "is the OTLP/HTTP transport
// compiled in or short-circuited to error.UnsupportedTransport".
test "OTLP/HTTP transport is compiled in (otel use_devnw_tls flag forwarded)" {
    // CANARY: REQ=REQ-OTEL-OTLP-PUSH-001; FEATURE="OTel Instrumentation"; ASPECT=OTLPTransportCompiledIn; STATUS=TESTED; TEST=tests/test_otel_otlp_transport_delivery.zig; OWNER=monitoring; UPDATED=2026-05-29
    //
    // RED (current build, flag discarded at build.zig:246/425):
    //     use_devnw_tls == false  ->  this expect() FAILS.
    // GREEN (after build.zig forwards .otel_use_devnw_tls = true):
    //     use_devnw_tls == true   ->  this expect() PASSES and the real
    //     std.http.Client transport at transport.zig:139 is compiled in.
    try std.testing.expect(otel.build_options.use_devnw_tls);
}

// ---------------------------------------------------------------------------
// REAL-CODE CORROBORATION (no mocks)
// ---------------------------------------------------------------------------
//
// Construct the real `OtlpHttpExporter` through its public `init`, then wire
// its `io` field EXACTLY the way geode does at
// src/monitoring/otel_metrics.zig:84,351:
//
//     exp_ptr.io = std.Io.Threaded.global_single_threaded.io();
//
// This satisfies the `io_opt orelse return error.UnsupportedTransport`
// precondition at transport.zig:140, so that — once the transport is
// compiled in — `error.UnsupportedTransport` can ONLY ever come from the
// flag gate at transport.zig:139, never from a missing io. We point the
// exporter at a guaranteed-refused loopback endpoint (a TCP port we bind,
// read, then close) so the wiring is concrete and reproducible.
//
// This proves the production exporter type, its `.stdlib_io` transport
// default, and geode's io wiring all compile and are reachable against the
// shared otel module instance.
test "OtlpHttpExporter wires the stdlib_io transport with geode's io (closed-port endpoint)" {
    const gpa = std.testing.allocator;

    // Reserve a loopback port, then close it so a connection there is
    // guaranteed-refused. This avoids hardcoding a port and avoids any
    // dependency on an external collector. Zig 0.16 reworked the net API
    // into `std.Io.net.*`; mirror the pattern geode itself uses in
    // src/cli/lsp/tcp_transport_test.zig (bind 127.0.0.1:0, read the
    // kernel-assigned port, then tear down).
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const listen_io = threaded.io();

    const bind_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try std.Io.net.IpAddress.listen(&bind_addr, listen_io, .{ .reuse_address = true });
    const bound_port = listener.socket.address.getPort();
    listener.deinit(listen_io); // close the socket; nothing listens on bound_port now.

    var endpoint_buf: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(
        &endpoint_buf,
        "http://127.0.0.1:{d}/",
        .{bound_port},
    );

    // Public init: validates scheme, defaults transport to `.stdlib_io`,
    // leaves io == null.
    var exporter = try otel.exporters.otlp_http.OtlpHttpExporter.init(gpa, .{
        .endpoint = endpoint,
        .protocol = .http_protobuf,
        .allow_loopback = true,
    });
    defer exporter.deinit();

    // Mirror geode's production wiring (otel_metrics.zig:84,351): plumb a
    // real std.Io into the exporter so the stdlib transport can fire
    // std.http.Client.fetch once it is compiled in.
    exporter.io = std.Io.Threaded.global_single_threaded.io();

    // The production path leaves the transport at its `.stdlib_io` default —
    // confirm that, and that geode's io is now non-null. Together with the
    // primary test above, this means a properly-configured stdlib_io
    // transport with a valid io must NEVER resolve to
    // error.UnsupportedTransport: after the fix the only outcome of driving
    // this exporter at the closed port is a connection-class failure.
    try std.testing.expect(exporter.transport == .stdlib_io);
    try std.testing.expect(exporter.io != null);
}
