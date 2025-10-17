const std = @import("std");

// Two-Phase Commit (2PC) scaffolding.
// Runtime gated by GEODE_ENABLE_DISTRIBUTED_WRITES. Provides coordinator & participant state machines.
// CANARY: REQ=REQ-GQL-2PC-001; FEATURE="Distributed 2PC"; ASPECT=TXN; STATUS=STUB; TEST=tests/e2e_2pc_distributed.zig:1; OWNER=txn; UPDATED=2025-09-26

pub const Xid = struct { bytes: [16]u8 };

pub const Decision = enum { unknown, commit, abort };

pub const ParticipantState = enum { init, prepared, committed, aborted };

pub const Participant = struct {
    id: u32,
    state: ParticipantState = .init,
    last_lsn: u64 = 0,

    pub fn prepare(self: *Participant) !void {
        if (!enabled()) return error.FeatureDisabled;
        if (self.state != .init) return error.InvalidState;
        self.state = .prepared;
    }
    pub fn commit(self: *Participant) !void {
        if (!enabled()) return error.FeatureDisabled;
        if (self.state != .prepared) return error.InvalidState;
        self.state = .committed;
    }
    pub fn abort(self: *Participant) !void {
        if (!enabled()) return error.FeatureDisabled;
        if (self.state == .committed) return error.InvalidState;
        self.state = .aborted;
    }
};

pub const Coordinator = struct {
    xid: Xid,
    participants: []Participant,
    decision: Decision = .unknown,

    pub fn init(xid: Xid, parts: []Participant) Coordinator {
        return .{ .xid = xid, .participants = parts };
    }

    pub fn drivePrepare(self: *Coordinator) !void {
        if (!enabled()) return error.FeatureDisabled;
        for (self.participants) |*p| try p.prepare();
    }
    pub fn decide(self: *Coordinator, commit_flag: bool) !void {
        if (!enabled()) return error.FeatureDisabled;
        if (commit_flag) self.decision = .commit else self.decision = .abort;
    }
    pub fn driveCommitOrAbort(self: *Coordinator) !void {
        if (!enabled()) return error.FeatureDisabled;
        if (self.decision == .unknown) return error.InvalidState;
        switch (self.decision) {
            .commit => for (self.participants) |*p| try p.commit(),
            .abort => for (self.participants) |*p| try p.abort(),
            else => {},
        }
    }
};

// P2-3: Use static GPA for env var check
var enabled_gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var enabled_gpa_init = false;

fn enabled() bool {
    if (!enabled_gpa_init) {
        enabled_gpa_init = true;
    }
    return std.process.hasEnvVar(enabled_gpa.allocator(), "GEODE_ENABLE_DISTRIBUTED_WRITES") catch false;
}
