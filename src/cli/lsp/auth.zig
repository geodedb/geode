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
/// `AuthState.verify`. The opaque-pointer + function-pointer pair lets
/// the LSP code stay decoupled from the concrete `AuthProvider` type
/// in `security/authn.zig` — useful for tests (in-process stubs, no
/// need to spin up an entire AuthProvider) and for keeping the LSP
/// build graph independent of every authn dependency.  Production
/// callers use `verifierFromAuthProvider` (below) to wrap a real
/// `*AuthProvider`; tests in this file install a fake.
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

    /// GAP-0818 follow-up: a derived, non-reversible session handle exposed
    /// to `LspContext.session_id`. It is the lowercase hex of a 64-bit
    /// Wyhash of the bearer token, NOT the raw token — so the session id we
    /// hand to feature providers (and any future logging/telemetry) never
    /// carries the secret. Owned inline; no heap, freed with the struct.
    /// Computed once via `deriveSessionHandle` after `token` is set.
    session_handle_buf: [16]u8 = [_]u8{0} ** 16,
    session_handle_len: usize = 0,

    /// Fill `session_handle_buf` with the hex of Wyhash(token). A no-op for
    /// an empty token (stdio default keeps `session_handle_len == 0`, which
    /// `sessionHandle` reports as null). Idempotent.
    pub fn deriveSessionHandle(self: *AuthState) void {
        if (self.token.len == 0) {
            self.session_handle_len = 0;
            return;
        }
        const h = std.hash.Wyhash.hash(0, self.token);
        // 16 lowercase hex chars for a u64 — exactly fills the buffer.
        _ = std.fmt.bufPrint(&self.session_handle_buf, "{x:0>16}", .{h}) catch unreachable;
        self.session_handle_len = 16;
    }

    /// The derived session handle slice, or null when none was derived
    /// (empty/stdio token). Borrows the inline buffer — valid for the
    /// lifetime of the AuthState.
    pub fn sessionHandle(self: *const AuthState) ?[]const u8 {
        if (self.session_handle_len == 0) return null;
        return self.session_handle_buf[0..self.session_handle_len];
    }

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

        s.deriveSessionHandle();
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
    /// `security/authn.zig:AuthProvider.authenticate()`.  The LSP
    /// server reaches it through a small `Verifier` vtable (so the
    /// LSP code does not have to take a direct dependency on the
    /// `authn` module). `verifierFromAuthProvider` below is the
    /// adapter the embedded-TCP listener (`geode serve`) installs: it
    /// wraps a real `*AuthProvider` and tries
    /// `authenticate({.bearer_token=…})` first, then
    /// `authenticate({.session_token=…})` — the same in-order chain
    /// the QUIC handler enforces (authn.zig:261-306).  Stdio LSP keeps
    /// `verifier = null` (fail-closed) unless launched with
    /// `--no-auth`.
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

// ----------------------------------------------------------------------
// AuthProvider → Verifier adapter (Task 28 follow-up).
//
// Wraps a live `geode.security.authn.AuthProvider` so the LSP server's
// vtable-shaped `Verifier` can dispatch through the same authentication
// chain the QUIC handler enforces. The TCP-embedded LSP listener
// constructed by `geode serve` (src/server/main.zig:runLspSession)
// passes the result of `verifierFromAuthProvider` so embedded clients
// can authenticate against the same API-key + session-token store the
// rest of the server already uses.
//
// **Chain.** Bearer token first (API-key path), then session token
// (rotating session path). The two `authenticate` calls are mutually
// exclusive on the input — a token is either a Bearer or a session.
// Both call into the same `AuthProvider`. We don't try mTLS here
// because the LSP `initialize` envelope only carries an opaque token,
// not a client certificate (mTLS belongs at the QUIC accept layer).
//
// **Ownership.** `Verifier.Outcome.ok.username` is a borrowed slice;
// callers (i.e. `AuthState.verify`) immediately `allocator.dupe` it
// before any subsequent provider call can invalidate the backing
// storage. Same lifetime contract the in-test `testVerifierFn` in
// `auth_test.zig` already exercises.
const authn = @import("geode").security.authn;

fn authProviderVerifyFn(ctx: *anyopaque, token: []const u8) Verifier.Outcome {
    if (token.len == 0) return .invalid;
    const provider: *authn.AuthProvider = @ptrCast(@alignCast(ctx));

    // 1. Try API-key (Bearer) — the common path for programmatic LSP clients.
    if (provider.authenticate(.{ .bearer_token = token })) |result| {
        const role_name: ?[]const u8 = if (result.roles.len > 0) result.roles[0] else null;
        return .{ .ok = .{ .username = result.username, .role = role_name } };
    } else |_| {
        // Fall through to session-token path.
    }

    // 2. Try session token — rotating session issued by a prior login.
    if (provider.authenticate(.{ .session_token = token })) |result| {
        const role_name: ?[]const u8 = if (result.roles.len > 0) result.roles[0] else null;
        return .{ .ok = .{ .username = result.username, .role = role_name } };
    } else |_| {
        return .invalid;
    }
}

/// Build a `Verifier` whose `ctx` borrows `provider` for the lifetime of
/// the returned vtable. The caller (typically `geode serve`'s embedded
/// LSP listener bootstrap) owns the `AuthProvider`; the verifier never
/// mutates it beyond what the in-handler `authenticate` calls already do.
pub fn verifierFromAuthProvider(provider: *authn.AuthProvider) Verifier {
    return Verifier{
        .ctx = @ptrCast(provider),
        .verifyFn = authProviderVerifyFn,
    };
}
