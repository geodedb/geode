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

/// Verifier vtable: the LSP server passes one of these into
/// `AuthState.verify`. The opaque-pointer + function-pointer pair is
/// what unblocks Task 12 in the face of the broken `security/authn.zig`
/// Zig-0.16 migration (the canonical `AuthProvider` does not compile
/// under the current toolchain — see lib.zig's authn note). In Task 28
/// the production wiring will adapt the real `AuthProvider.authenticate`
/// to this same shape; tests in this file install a fake.
///
/// `verifyFn` returns an `Outcome.ok` on success, populating the username
/// and an optional role string (which the caller maps through
/// `user_management.Role.fromString`). It returns `Outcome.invalid` on
/// any error path — auth errors are not differentiated at the LSP layer
/// because the protocol surface is the same -32002 regardless.
pub const Verifier = struct {
    ctx: *anyopaque,
    verifyFn: *const fn (ctx: *anyopaque, token: []const u8) Outcome,

    pub const Outcome = union(enum) {
        ok: struct {
            username: []const u8,
            role: ?[]const u8 = null,
        },
        invalid,
    };
};

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

    /// Validate the bearer token bound at construction time. On
    /// success, populate `self.user` / `self.role` and set
    /// `self.verified = true`.
    ///
    /// **Verifier semantics.** The canonical validator is
    /// `security/authn.zig:AuthProvider.authenticate()`, but that file
    /// does not currently compile against Zig 0.16 (it predates the
    /// `std.crypto.random` removal — see lib.zig's authn note). Until
    /// the migration lands, the LSP server passes a `Verifier` vtable
    /// instead of a raw `AuthProvider`. Production code (Task 28) will
    /// install a verifier whose `ctx` is the real `AuthProvider*` and
    /// whose `verifyFn` calls `authenticate({.bearer_token=…})` then
    /// `…({.session_token=…})` — the same in-order chain the QUIC
    /// handler enforces (authn.zig:261-306).
    ///
    /// When `verifier` is `null` we cannot authenticate; every
    /// non-empty token returns `InvalidToken`. This is the fail-closed
    /// stdio-LSP path until Task 13 lands `--no-auth` and Task 28
    /// plumbs the live verifier through `geode serve`.
    ///
    /// **Ownership.** On success we dupe the username and (optional)
    /// role-name slices so they survive the verifier releasing its
    /// borrowed copies. The dupe is owned by `self` and freed in
    /// `deinit`.
    ///
    /// Errors:
    ///   - `MissingToken` — `self.token` is empty.
    ///   - `InvalidToken` — verifier rejected the token, or `verifier`
    ///     was `null` and the token is non-empty.
    pub fn verify(
        self: *AuthState,
        allocator: std.mem.Allocator,
        verifier: ?Verifier,
    ) AuthError!void {
        if (self.token.len == 0) return AuthError.MissingToken;
        const v = verifier orelse return AuthError.InvalidToken;

        switch (v.verifyFn(v.ctx, self.token)) {
            .invalid => return AuthError.InvalidToken,
            .ok => |ok| {
                self.user = try allocator.dupe(u8, ok.username);
                if (ok.role) |role_name| {
                    if (user_management.Role.fromString(role_name)) |r| {
                        self.role = r;
                    }
                }
                self.verified = true;
            },
        }
    }
};
