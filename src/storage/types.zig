const std = @import("std");

/// Shared storage identifier types (formerly in storage/interface.zig).
/// Kept minimal to avoid legacy storage interface dependencies.
pub const PageId = u32;

pub const RecordId = struct {
    page: u32,
    slot: u16,
};

pub const NodeLocation = struct {
    page: u32,
    slot: u16,
};

