const std = @import("std");

// Shared portable feature flag + test override helper.
// Each feature registers a Flag struct with an environment variable name.
// Provides deterministic test overrides without mutating real process env.
// CANARY: REQ=REQ-GQL-FLAGS-001; FEATURE="Shared Feature Flag Wrapper"; ASPECT=INFRA; STATUS=IMPL; OWNER=core; UPDATED=2026-11-14

/// P2-3: Static GPA for env var checks in feature flags
var flags_gpa: std.heap.DebugAllocator(.{}) = .{};
var flags_gpa_init = false;

pub const Flag = struct {
    env_var: []const u8,
    test_override: ?bool = null,

    pub fn init(env_var: []const u8) Flag {
        return Flag{ .env_var = env_var };
    }

    pub fn enabled(self: *Flag) bool {
        if (self.test_override) |override| return override;
        // P2-3: Use static GPA for env var check
        if (!flags_gpa_init) {
            flags_gpa_init = true;
        }
        const name_z = std.posix.toPosixPath(self.env_var) catch return false;
        return std.c.getenv(&name_z) != null;
    }

    pub fn enableForTests(self: *Flag) void {
        self.test_override = true;
    }

    pub fn disableForTests(self: *Flag) void {
        self.test_override = false;
    }

    pub fn clearTestOverride(self: *Flag) void {
        self.test_override = null;
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

/// parseEnvBool returns the boolean value of an environment variable.
/// Returns default_val if the variable is not set.
/// Accepts "true"/"1"/"yes" as true, "false"/"0"/"no" as false (case-insensitive).
/// Uses non-allocating std.process.getenv; suitable for startup configuration reads.
pub fn parseEnvBool(name: []const u8, default_val: bool) bool {
    const val = std.process.getenv(name) orelse return default_val;
    if (std.mem.eql(u8, val, "1") or std.ascii.eqlIgnoreCase(val, "true") or std.ascii.eqlIgnoreCase(val, "yes")) return true;
    if (std.mem.eql(u8, val, "0") or std.ascii.eqlIgnoreCase(val, "false") or std.ascii.eqlIgnoreCase(val, "no")) return false;
    return default_val;
}
