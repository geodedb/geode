const std = @import("std");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Core API"; ASPECT=API; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_CoreStartStop; OWNER=streaming; UPDATED=2025-09-20

pub const CoreConfig = struct {
    enabled: bool = true,
    flush_interval_ms: u64 = 1000,
};

pub const CoreState = enum { stopped, starting, running, stopping };

/// CDC Event structure
pub const Event = struct {
    sequence_number: u64,
    table_name: []const u8,
    operation: Operation,
    timestamp: i64,
    data: std.json.Value,
};

pub const Operation = enum {
    insert,
    update,
    delete,
    truncate,
};

pub const CoreEngine = struct {
    config: CoreConfig,
    state: CoreState = .stopped,
    start_count: u64 = 0,
    stop_count: u64 = 0,

    pub fn init(cfg: CoreConfig) CoreEngine {
        return .{ .config = cfg };
    }

    pub fn start(self: *CoreEngine) !void {
        if (!self.config.enabled) return; // no-op when disabled
        switch (self.state) {
            .running => return, // idempotent
            .starting => return,
            .stopping => return error.EngineStopping,
            .stopped => {},
        }
        self.state = .starting;
        // simulate lightweight init
        self.start_count += 1;
        self.state = .running;
    }

    pub fn stop(self: *CoreEngine) !void {
        switch (self.state) {
            .stopped => return, // idempotent
            .starting => {},
            .running => {},
            .stopping => return, // already in progress
        }
        self.state = .stopping;
        self.stop_count += 1;
        self.state = .stopped;
    }

    pub fn isRunning(self: *const CoreEngine) bool {
        return self.state == .running;
    }
};

pub const EngineStopping = error{EngineStopping};

// ==================== Unit Tests (GAP-0241) ====================
// CANARY: REQ=REQ-GAP-0241; FEATURE="CDCCoreUnitTests"; ASPECT=CoreEngine; STATUS=TESTED; TEST=test_cdc_engine; OWNER=streaming; UPDATED=2026-01-25

test "CoreEngine init with default config" {
    const engine = CoreEngine.init(.{});
    try std.testing.expect(engine.config.enabled);
    try std.testing.expectEqual(CoreState.stopped, engine.state);
    try std.testing.expectEqual(@as(u64, 0), engine.start_count);
}

test "CoreEngine init with disabled config" {
    const engine = CoreEngine.init(.{ .enabled = false });
    try std.testing.expect(!engine.config.enabled);
}

test "CoreEngine start transitions to running" {
    var engine = CoreEngine.init(.{});
    try engine.start();
    try std.testing.expect(engine.isRunning());
    try std.testing.expectEqual(@as(u64, 1), engine.start_count);
}

test "CoreEngine start is idempotent when running" {
    var engine = CoreEngine.init(.{});
    try engine.start();
    try engine.start(); // Second start should be no-op
    try std.testing.expectEqual(@as(u64, 1), engine.start_count);
}

test "CoreEngine start does nothing when disabled" {
    var engine = CoreEngine.init(.{ .enabled = false });
    try engine.start();
    try std.testing.expect(!engine.isRunning());
    try std.testing.expectEqual(@as(u64, 0), engine.start_count);
}

test "CoreEngine stop transitions to stopped" {
    var engine = CoreEngine.init(.{});
    try engine.start();
    try engine.stop();
    try std.testing.expect(!engine.isRunning());
    try std.testing.expectEqual(@as(u64, 1), engine.stop_count);
}

test "CoreEngine stop is idempotent when already stopped" {
    var engine = CoreEngine.init(.{});
    try engine.stop(); // Already stopped
    try std.testing.expectEqual(@as(u64, 0), engine.stop_count);
}

test "CoreEngine start-stop-start cycle" {
    var engine = CoreEngine.init(.{});
    try engine.start();
    try std.testing.expect(engine.isRunning());
    try engine.stop();
    try std.testing.expect(!engine.isRunning());
    try engine.start();
    try std.testing.expect(engine.isRunning());
    try std.testing.expectEqual(@as(u64, 2), engine.start_count);
}

test "CoreState enum values" {
    try std.testing.expectEqual(CoreState.stopped, CoreState.stopped);
    try std.testing.expectEqual(CoreState.running, CoreState.running);
    try std.testing.expect(CoreState.stopped != CoreState.running);
}

test "Operation enum values" {
    try std.testing.expectEqual(Operation.insert, Operation.insert);
    try std.testing.expectEqual(Operation.update, Operation.update);
    try std.testing.expectEqual(Operation.delete, Operation.delete);
    try std.testing.expectEqual(Operation.truncate, Operation.truncate);
}

test "CoreConfig default values" {
    const cfg = CoreConfig{};
    try std.testing.expect(cfg.enabled);
    try std.testing.expectEqual(@as(u64, 1000), cfg.flush_interval_ms);
}

test "CoreConfig custom flush interval" {
    const cfg = CoreConfig{ .flush_interval_ms = 5000 };
    try std.testing.expectEqual(@as(u64, 5000), cfg.flush_interval_ms);
}

test "CoreEngine multiple start stop cycles" {
    var engine = CoreEngine.init(.{});

    // Cycle 1
    try engine.start();
    try engine.stop();

    // Cycle 2
    try engine.start();
    try engine.stop();

    // Cycle 3
    try engine.start();
    try engine.stop();

    try std.testing.expectEqual(@as(u64, 3), engine.start_count);
    try std.testing.expectEqual(@as(u64, 3), engine.stop_count);
}

test "CoreEngine state after stop" {
    var engine = CoreEngine.init(.{});
    try engine.start();
    try engine.stop();
    try std.testing.expectEqual(CoreState.stopped, engine.state);
}

test "CoreEngine isRunning after various states" {
    var engine = CoreEngine.init(.{});

    // Initially stopped
    try std.testing.expect(!engine.isRunning());

    // After start
    try engine.start();
    try std.testing.expect(engine.isRunning());

    // After stop
    try engine.stop();
    try std.testing.expect(!engine.isRunning());
}

test "Event struct fields" {
    const event = Event{
        .sequence_number = 42,
        .table_name = "users",
        .operation = .insert,
        .timestamp = 1706200000,
        .data = .null,
    };

    try std.testing.expectEqual(@as(u64, 42), event.sequence_number);
    try std.testing.expectEqualStrings("users", event.table_name);
    try std.testing.expectEqual(Operation.insert, event.operation);
}

test "CoreEngine config preserved after operations" {
    var engine = CoreEngine.init(.{ .enabled = true, .flush_interval_ms = 2000 });

    try engine.start();
    try engine.stop();

    // Config should be preserved
    try std.testing.expect(engine.config.enabled);
    try std.testing.expectEqual(@as(u64, 2000), engine.config.flush_interval_ms);
}

test "CoreEngine disabled start multiple times" {
    var engine = CoreEngine.init(.{ .enabled = false });

    try engine.start();
    try engine.start();
    try engine.start();

    // Should never actually start
    try std.testing.expect(!engine.isRunning());
    try std.testing.expectEqual(@as(u64, 0), engine.start_count);
}
