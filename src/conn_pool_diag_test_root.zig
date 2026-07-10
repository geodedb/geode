// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// GAP-0927 / GAP-0928 — dedicated test root (at src/ so all of the server
// graph's relative imports resolve, same as src/unified_entry.zig).
//
// CANARY: REQ=REQ-GAP-0927-IDLE-TIMEOUT-REAP-WIRING; FEATURE="ConnectionPool"; ASPECT=DiagTestRoot; STATUS=TESTED; TEST=self; OWNER=transport; UPDATED=2026-07-10
//
// The GAP-0927 idle-reap-deadline wiring test is INLINE in
// src/server/quic_connection_handler.zig and the GAP-0928 pool-exhausted
// rate-limit predicate test is INLINE in src/server/main.zig. Neither module
// is exported through the `geode` root (server graph, circular dep). Zig 0.16
// only collects inline `test` blocks from files reachable from a test module's
// ROOT via references, so this thin src/-rooted module force-references both
// namespaces. Test-only; never linked into the shipped binary.

const std = @import("std");

pub const quic_connection_handler = @import("server/quic_connection_handler.zig");
pub const server_main = @import("server/main.zig");

test {
    std.testing.refAllDecls(quic_connection_handler);
    std.testing.refAllDecls(server_main);
}
