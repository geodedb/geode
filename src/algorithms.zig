// QUIC algorithm implementations for Geode graph database
//
// CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICAlgorithms; STATUS=TESTED; TEST=src/algorithms/drr.zig; OWNER=wire; UPDATED=2026-01-15
// Exports DRR scheduling, NewReno congestion control, loss recovery, timer heap, and connection sharding

pub const drr = @import("algorithms/drr.zig");
pub const congestion = @import("algorithms/congestion_newreno.zig");
pub const loss_recovery = @import("algorithms/loss_recovery.zig");
pub const timer_heap = @import("algorithms/timer_heap.zig");
pub const sharding = @import("algorithms/sharding.zig");
