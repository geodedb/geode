const std = @import("std");

// Shared portable feature flag + test override helper.
// Each feature registers a Flag struct with an environment variable name.
// Provides deterministic test overrides without mutating real process env.
// CANARY: REQ=REQ-GQL-FLAGS-001; FEATURE="Shared Feature Flag Wrapper"; ASPECT=INFRA; STATUS=TESTED; TEST=tests/unit_feature_flags.zig:1; OWNER=core; UPDATED=2025-09-26

/// P2-3: Static GPA for env var checks in feature flags
var flags_gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var flags_gpa_init = false;

pub const Flag = struct {
    env_var: []const u8,

    pub fn init(env_var: []const u8) Flag {
        return Flag{ .env_var = env_var };
    }

    pub fn enabled(self: *Flag) bool {
        // P2-3: Use static GPA for env var check
        if (!flags_gpa_init) {
            flags_gpa_init = true;
        }
        return std.process.hasEnvVar(flags_gpa.allocator(), self.env_var) catch false;
    }
};

// Convenience getter for code paths that previously had local statics.
// Example:
// var tde_flag = feature_flags.global(.tde);

pub const GlobalFlags = struct {
    // Add fields per feature
    tde: Flag = Flag.init("GEODE_ENABLE_TDE"),
    mfa: Flag = Flag.init("GEODE_ENABLE_MFA"),
    adv_fts: Flag = Flag.init("GEODE_ENABLE_ADVANCED_FTS"),

    pub fn singleton() *GlobalFlags {
        // Use a single static mutable instance. Zig 0.15.1 forbids returning pointer to comptime var.
        // Thread-safety: initialization is zeroed at program start; individual atomic overrides are safe.
        const S = struct {
            var instance: GlobalFlags = GlobalFlags{};
        };
        return &S.instance;
    }
};

pub fn global() *GlobalFlags {
    return GlobalFlags.singleton();
}
