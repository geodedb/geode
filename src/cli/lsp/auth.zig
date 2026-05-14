// Task 10 of the LSP permission-aware completion plan.
//
// Parses the `initializeOptions.geode.*` block that geode-ui (or any
// LSP client) ships with the JSON-RPC `initialize` request. The shape
// it accepts is:
//
//     {
//       "geode": {
//         "authToken": "<JWT or PAT-style bearer>",
//         "graph":     "<active graph name, optional>",
//         "tenant":    "<tenant id, optional>"
//       }
//     }
//
// `verify()` (server-side JWT validation) lands in Task 11. This file
// only owns the parse + ownership-transfer step: every returned slice
// is a fresh allocator dupe and `deinit` releases all of them.
//
// `Role` defaults to `.ReadOnly` so a not-yet-verified AuthState can
// never be mistaken for an admin session. Task 11 overwrites this once
// the token has been validated.

const std = @import("std");

// Module-diamond escape hatch (matches Task 5 / 6 / 9 wiring): we reach
// user_management.zig through the `geode` named module rather than a
// relative import. A relative path tripped Zig 0.16's
//   "import of file outside module path"
// error because this file is consumed by `src/cli/lsp/auth_test.zig`
// which is registered as a standalone root module in build.zig — the
// security/ tree is outside that module's source root. The build.zig
// wiring for `auth_mod` / `auth_test_mod` adds the named `geode`
// import so this resolves at compile time.
const geode = @import("geode");
const user_management = geode.user_management;

pub const AuthError = error{
    MissingToken,
    InvalidToken,
    ExpiredToken,
    BadFormat,
    OutOfMemory,
};

pub const AuthState = struct {
    token: []const u8,
    user: []const u8 = "",
    role: user_management.Role = .ReadOnly,
    graph: ?[]const u8 = null,
    tenant_id: ?[]const u8 = null,
    verified: bool = false,

    /// Parse `params.geode.{authToken,graph,tenant}` out of an
    /// `initialize` request's `initializationOptions`. Every owned
    /// slice is freshly duped; release them all via `deinit`.
    ///
    /// Errors:
    ///   - `MissingToken` — no `geode` block, or `geode.authToken` absent.
    ///   - `BadFormat`    — `params` / `geode` / `authToken` wrong JSON kind.
    pub fn fromInitializeOptions(
        allocator: std.mem.Allocator,
        params: std.json.Value,
    ) AuthError!AuthState {
        if (params != .object) return AuthError.BadFormat;
        const geode_obj = params.object.get("geode") orelse return AuthError.MissingToken;
        if (geode_obj != .object) return AuthError.BadFormat;
        const tok = geode_obj.object.get("authToken") orelse return AuthError.MissingToken;
        if (tok != .string) return AuthError.BadFormat;

        var s = AuthState{ .token = try allocator.dupe(u8, tok.string) };
        errdefer allocator.free(s.token);

        if (geode_obj.object.get("graph")) |g| {
            if (g == .string) s.graph = try allocator.dupe(u8, g.string);
        }
        errdefer if (s.graph) |g| allocator.free(g);

        if (geode_obj.object.get("tenant")) |t| {
            if (t == .string) s.tenant_id = try allocator.dupe(u8, t.string);
        }

        return s;
    }

    pub fn deinit(self: AuthState, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        if (self.graph) |g| allocator.free(g);
        if (self.tenant_id) |t| allocator.free(t);
        if (self.user.len > 0) allocator.free(self.user);
    }
};
