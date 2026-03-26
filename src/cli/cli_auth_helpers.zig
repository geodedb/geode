// CANARY: REQ=REQ-CLI-AUTH-HELPERS-001; FEATURE="CLI Auth Helpers"; ASPECT=Offline; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-24
//! Shared helpers for CLI commands that need offline access to auth data.
//!
//! Provides:
//! - `resolveStatePath` — resolve a state file path (for non-auth state files like authn, session, apikey, mtls)
//! - `isPasswordStrong` — password strength validation
//! - `initCliAuthManager` — initialise AuthGraphManager for offline CLI operations
//! - `generateSecurePassword` — generate a cryptographically secure random password

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const graph_store = geode.graph_store;
const auth_graph_manager = @import("auth_graph_manager");
pub const AuthGraphManager = auth_graph_manager.AuthGraphManager;

// -- State Path Resolution (for non-auth flat files) --

const STATE_DIR_ENV = "GEODE_STATE_DIR";

fn secureChmod(path: []const u8, mode: std.fs.File.Mode) void {
    if (builtin.os.tag == .windows) return;
    if (std.fs.openFileAbsolute(path, .{})) |file| {
        defer file.close();
        file.chmod(mode) catch {};
        return;
    } else |_| {}

    if (std.fs.openDirAbsolute(path, .{ .iterate = true })) |opened_dir| {
        var dir = opened_dir;
        defer dir.close();
        dir.chmod(mode) catch {};
    } else |_| {}
}

fn resolveStateDir(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, STATE_DIR_ENV)) |raw| {
        defer allocator.free(raw);
        if (std.fs.path.isAbsolute(raw)) return allocator.dupe(u8, raw);

        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);
        return std.fs.path.join(allocator, &.{ cwd, raw });
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "XDG_STATE_HOME")) |xdg_state_home| {
        defer allocator.free(xdg_state_home);
        return std.fs.path.join(allocator, &.{ xdg_state_home, "geode" });
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".local", "state", "geode" });
    } else |_| {}

    if (builtin.os.tag != .windows) {
        return std.fmt.allocPrint(allocator, "/tmp/geode-{d}", .{std.posix.getuid()});
    }
    return std.fs.path.join(allocator, &.{ ".", ".geode", "state" });
}

/// Resolve the full filesystem path for a state file.
/// Used by authn_cli, session_cli, apikey_cli, and mtls_cli for their own
/// flat-file state (NOT user credentials, which live in the graph store).
pub fn resolveStatePath(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    const state_dir = try resolveStateDir(allocator);
    defer allocator.free(state_dir);

    try std.fs.cwd().makePath(state_dir);
    secureChmod(state_dir, 0o700);

    return std.fs.path.join(allocator, &.{ state_dir, filename });
}

// -- Password Strength Validation --

/// Check whether a password meets minimum policy requirements.
/// Requires at least 8 characters, at least one letter, and at least one digit.
pub fn isPasswordStrong(password: []const u8) bool {
    if (password.len < 8) return false;
    var has_digit = false;
    var has_alpha = false;
    for (password) |c| {
        if (std.ascii.isDigit(c)) has_digit = true;
        if (std.ascii.isAlphabetic(c)) has_alpha = true;
    }
    return has_digit and has_alpha;
}

// -- Secure Password Generation --

/// Generate a cryptographically secure random password.
/// Returns a 32-character hex string (16 random bytes converted to hex).
pub fn generateSecurePassword() [32]u8 {
    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    return std.fmt.bytesToHex(random_bytes, .lower);
}

// -- Offline Auth Manager Initialization --

/// Initialise an AuthGraphManager for CLI offline operations.
///
/// Opens the graph store at the given data directory (from --data-dir flag
/// or GEODE_DATA_DIR env var) and returns a ready-to-use AuthGraphManager.
///
/// The caller must call `deinit()` on the returned manager when done.
pub fn initCliAuthManager(allocator: std.mem.Allocator, data_dir: ?[]const u8) !AuthGraphManager {
    // Set the data directory override so getGlobalStore uses the right path
    if (data_dir) |dir| {
        graph_store.setDataDirOverride(allocator, dir);
    }
    const store = graph_store.getGlobalStore(allocator);
    return AuthGraphManager.init(allocator, store);
}

/// Persist any dirty graph-store state and deinitialise the CLI auth manager.
///
/// CLI commands run as short-lived processes without a persistence thread.
/// This function ensures that mutations (user create, role create, etc.) are
/// flushed to disk before the process exits.  Call this instead of (or in
/// addition to) `mgr.deinit()` from every CLI command that may mutate auth
/// state.
pub fn deinitAndSaveCliAuth(allocator: std.mem.Allocator, mgr: *AuthGraphManager) void {
    // Flush any in-memory changes to disk before tearing down.
    graph_store.getGlobalStore(allocator).saveIfDirty();
    mgr.deinit();
}

// -- Tests --

test "isPasswordStrong rejects short passwords" {
    try std.testing.expect(!isPasswordStrong("abc123"));
    try std.testing.expect(!isPasswordStrong("abcdefg"));
}

test "isPasswordStrong rejects missing digits" {
    try std.testing.expect(!isPasswordStrong("abcdefgh"));
}

test "isPasswordStrong rejects missing letters" {
    try std.testing.expect(!isPasswordStrong("12345678"));
}

test "isPasswordStrong accepts valid passwords" {
    try std.testing.expect(isPasswordStrong("password1"));
    try std.testing.expect(isPasswordStrong("abc12345"));
    try std.testing.expect(isPasswordStrong("SecureP4ss!"));
}

test "generateSecurePassword returns 32 chars" {
    const pw = generateSecurePassword();
    try std.testing.expectEqual(@as(usize, 32), pw.len);
}
