const std = @import("std");

const geode = @import("geode");

// Import individual test modules (relative to this directory)
const _div_zero = @import("eval_div_zero_unit.zig");
// E2E protocol tests (manually imported so they run under `zig build test`)
const _e2e_profile_committed = @import("e2e_protocol_profile_committed_txns.zig");
const _e2e_recovery_checksum_committed = @import("e2e_protocol_recovery_checksum_committed.zig");
const _e2e_hashagg_spill = @import("e2e_protocol_hashagg_spill.zig");
const _e2e_mvcc_phantom = @import("e2e_protocol_mvcc_phantom.zig");
const _e2e_sort_spill = @import("e2e_protocol_sort_spill.zig");
const _e2e_wal_skip_ratio = @import("e2e_wal_skip_ratio.zig");
const _e2e_protocol_wal_skip_ratio = @import("e2e_protocol_wal_skip_ratio.zig");
const _e2e_protocol_groupby_hashagg = @import("e2e_protocol_groupby_hashagg.zig");
const _e2e_protocol_txn_baseline = @import("e2e_protocol_txn_baseline.zig");
const _e2e_setops_intersect_except = @import("e2e_setops_intersect_except.zig");
const _e2e_setops_all = @import("e2e_setops_all.zig");
const _e2e_setops_mixed_nulls = @import("e2e_setops_mixed_nulls.zig");
const _e2e_order_policy_toggle = @import("e2e_order_policy_toggle.zig");
const _e2e_explain_setops = @import("e2e_explain_setops.zig");
const _e2e_catalog_persistence_disk = @import("e2e_catalog_persistence_disk.zig");
const _e2e_quic_basic = @import("e2e_quic_basic.zig");
const _e2e_with_clause = @import("e2e_with_clause.zig");
const _unit_shortest_path_tiebreak = @import("unit_shortest_path_tiebreak.zig");

// Placeholder aggregate test to ensure file compiles and geode linkage is valid.
// Additional per-feature aggregator logic can be placed here later.

// Existing placeholder
const _e2e_sort_spill_placeholder = @import("e2e_protocol_sort_spill.zig");

test "aggregate: geode module loads" {
    // Basic sanity check: parse trivial query
    var res = try geode.parseGql("RETURN 1", std.testing.allocator);
    defer res.deinit();
    try std.testing.expect(res.program.statements.len == 1);
}
