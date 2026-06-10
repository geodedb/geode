// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// REQ-QUIC-FIRST-STREAM-OWNER-LIFETIME — dedicated test root (at src/ so all of
// the server graph's relative imports resolve, same as src/unified_entry.zig).
//
// CANARY: REQ=REQ-QUIC-FIRST-STREAM-OWNER-LIFETIME; FEATURE="QuicTransport"; ASPECT=FirstStreamOwnerLifetimeTestRoot; STATUS=TESTED; TEST=tests/test_first_stream_owner_lifetime.zig; OWNER=server; UPDATED=2026-06-10
//
// The FirstStreamOwnerContext use-after-free reproduction tests are INLINE in
// src/server/quic_connection_handler.zig (the scheduler / owner-context /
// notifier internals are private and intentionally NOT exported through `geode`
// — circular dependency, see src/lib.zig:652). Zig 0.16 only collects inline
// `test` blocks from files reachable from a test module's ROOT via references.
// This thin root sits at src/ (so the handler's `@import("transport/quic")`-
// style module imports and sibling relative imports all resolve, exactly like
// src/unified_entry.zig) and force-references the handler namespace, pulling its
// `first_stream_owner_*` / `first_stream_decode_*` inline tests into the
// `test-first-stream-owner-lifetime` build step. Test-only; never linked into
// the shipped binary.

const std = @import("std");

// Force the handler's inline tests into this test binary.
pub const quic_connection_handler = @import("server/quic_connection_handler.zig");

test {
    // refAllDecls on the handler namespace forces its container to be analyzed
    // so the test runner collects its inline `test` blocks.
    std.testing.refAllDecls(quic_connection_handler);
}
