const std = @import("std");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Core API"; ASPECT=API; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_CoreStartStop; OWNER=streaming; UPDATED=2025-09-20

pub const CoreConfig = struct {
    enabled: bool = true,
    flush_interval_ms: u64 = 1000,
};

pub const CoreState = enum { stopped, starting, running, stopping };

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
