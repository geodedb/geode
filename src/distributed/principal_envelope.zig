// CANARY: REQ=REQ-GPS-DIST-002; FEATURE="GPS Distributed Envelope"; ASPECT=Serialization; STATUS=TESTED; TEST=tests/test_gps_distributed_envelope.zig; OWNER=security; UPDATED=2026-05-20
//
// principal_envelope.zig — serializes/deserializes the identity-bearing fields
// from a Principal plus the current policy_version for cluster RPCs.
//
// Design goals (GPS Phase 6, Task 6-3):
//  1. Coordinator attaches an envelope to every outbound shard request so the
//     receiving worker can reconstruct an ExecutionContext with the caller's
//     identity rather than the generic "geode-coordinator" internal principal.
//  2. The envelope is self-describing with a magic header + version byte so
//     future format extensions can be detected without breakage.
//  3. Intentionally narrow scope: only the fields that are meaningful across
//     the cluster wire (identity + policy_version). Local-only fields like
//     session_id, risk_context.ip_address, and elevation_until are NOT
//     forwarded — workers must not act on session-local context.
//
// Wire format (version 1) — little-endian throughout:
//   [4]u8   magic       "GPSP"
//   u8      version     = 1
//   u8      flags       bit 0 = has_user_id
//                       bit 1 = has_username
//                       bit 2 = has_tenant_id
//                       bit 3 = has_active_graph
//   u64     user_id     (only if has_user_id)
//   u32     username_len + []u8 username  (only if has_username)
//   u32     roles_count
//     for each role: u32 len + []u8 name
//   u32     custom_roles_count
//     for each custom_role: u32 len + []u8 name
//   u32     tenant_id_len + []u8 tenant_id  (only if has_tenant_id)
//   u32     active_graph_len + []u8 active_graph  (only if has_active_graph)
//   u64     auth_version
//   u64     policy_version
//   u8      source_tag_ordinal  (PrincipalSource enum ordinal)
//
// Phase 7 note: when the wire-level shard RPC (enhanced_query_transport.zig;
// query_transport.zig was never compiled and was removed in SONNY-6279) is
// extended to carry opaque metadata blobs,
// the coordinator should call serialize() and attach the result to the
// outbound NodeQuery; the worker should call deserialize() and construct its
// ExecutionContext. That integration is deferred to Phase 7 because the
// current QueryTransport does not have a metadata header on the RPC path.

const std = @import("std");
const principal_mod = @import("../security/principal.zig");

// Magic bytes that identify a GPS principal envelope blob.
pub const MAGIC: [4]u8 = "GPSP".*;
// Current serialization format version.
pub const FORMAT_VERSION: u8 = 1;

/// The subset of Principal fields that are meaningful across the cluster wire.
/// Workers reconstruct an ExecutionContext principal from this.
pub const PrincipalEnvelope = struct {
    user_id: ?u64,
    username: ?[]const u8,
    roles: []const []const u8,
    custom_roles: []const []const u8,
    tenant_id: ?[]const u8,
    active_graph: ?[]const u8,
    auth_version: u64,
    policy_version: u64,
    source: principal_mod.PrincipalSource,
};

/// Errors returned by deserialize().
pub const EnvelopeError = error{
    InvalidMagic,
    UnsupportedVersion,
    TruncatedEnvelope,
    InvalidSourceOrdinal,
};

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

/// Serialize `env` into a heap-allocated byte slice owned by the caller.
/// The caller must free the slice with `allocator.free(slice)`.
pub fn serialize(allocator: std.mem.Allocator, env: PrincipalEnvelope) ![]u8 {
    // Zig 0.16: ArrayList is unmanaged; allocator is passed per-operation.
    var buf = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    errdefer buf.deinit(allocator);

    // Magic + version
    try buf.appendSlice(allocator, &MAGIC);
    try buf.append(allocator, FORMAT_VERSION);

    // Flags byte
    var flags: u8 = 0;
    if (env.user_id != null) flags |= 0b0001;
    if (env.username != null) flags |= 0b0010;
    if (env.tenant_id != null) flags |= 0b0100;
    if (env.active_graph != null) flags |= 0b1000;
    try buf.append(allocator, flags);

    // Optional user_id
    if (env.user_id) |uid| {
        try appendU64(allocator, &buf, uid);
    }

    // Optional username
    if (env.username) |name| {
        try appendLenPrefixedSlice(allocator, &buf, name);
    }

    // roles[]
    try appendU32(allocator, &buf, @intCast(env.roles.len));
    for (env.roles) |role| {
        try appendLenPrefixedSlice(allocator, &buf, role);
    }

    // custom_roles[]
    try appendU32(allocator, &buf, @intCast(env.custom_roles.len));
    for (env.custom_roles) |role| {
        try appendLenPrefixedSlice(allocator, &buf, role);
    }

    // Optional tenant_id
    if (env.tenant_id) |tid| {
        try appendLenPrefixedSlice(allocator, &buf, tid);
    }

    // Optional active_graph
    if (env.active_graph) |graph| {
        try appendLenPrefixedSlice(allocator, &buf, graph);
    }

    // auth_version + policy_version
    try appendU64(allocator, &buf, env.auth_version);
    try appendU64(allocator, &buf, env.policy_version);

    // source ordinal
    try buf.append(allocator, @intFromEnum(env.source));

    return buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Deserialization
// ---------------------------------------------------------------------------

/// Deserialize a PrincipalEnvelope from `bytes`.
/// String slices inside the returned envelope are sub-slices of `bytes` — the
/// caller must keep `bytes` alive as long as the envelope is used.
/// If you need to own the strings independently, dupe them before freeing `bytes`.
pub fn deserialize(bytes: []const u8) !PrincipalEnvelope {
    resetStaticRoleBuffer();
    var r = Reader.init(bytes);

    // Magic
    const magic = try r.readBytes(4);
    if (!std.mem.eql(u8, magic, &MAGIC)) return EnvelopeError.InvalidMagic;

    // Version
    const version = try r.readByte();
    if (version != 1) return EnvelopeError.UnsupportedVersion;

    // Flags
    const flags = try r.readByte();
    const has_user_id = (flags & 0b0001) != 0;
    const has_username = (flags & 0b0010) != 0;
    const has_tenant_id = (flags & 0b0100) != 0;
    const has_active_graph = (flags & 0b1000) != 0;

    // Optional user_id
    const user_id: ?u64 = if (has_user_id) try r.readU64() else null;

    // Optional username
    const username: ?[]const u8 = if (has_username) try r.readLenPrefixedSlice() else null;

    // roles[]
    const roles_count = try r.readU32();
    const roles_start = static_role_buf_used;
    var ri: u32 = 0;
    while (ri < roles_count) : (ri += 1) {
        if (static_role_buf_used >= MAX_ROLES_STATIC) return EnvelopeError.TruncatedEnvelope;
        const s = try r.readLenPrefixedSlice();
        static_role_buf[static_role_buf_used] = s;
        static_role_buf_used += 1;
    }
    const roles = static_role_buf[roles_start..static_role_buf_used];

    // custom_roles[]
    const custom_roles_count = try r.readU32();
    const custom_roles_start = static_role_buf_used;
    var ci: u32 = 0;
    while (ci < custom_roles_count) : (ci += 1) {
        if (static_role_buf_used >= MAX_ROLES_STATIC) return EnvelopeError.TruncatedEnvelope;
        const s = try r.readLenPrefixedSlice();
        static_role_buf[static_role_buf_used] = s;
        static_role_buf_used += 1;
    }
    const custom_roles = static_role_buf[custom_roles_start..static_role_buf_used];

    // Optional tenant_id
    const tenant_id: ?[]const u8 = if (has_tenant_id) try r.readLenPrefixedSlice() else null;

    // Optional active_graph
    const active_graph: ?[]const u8 = if (has_active_graph) try r.readLenPrefixedSlice() else null;

    // auth_version + policy_version
    const auth_version = try r.readU64();
    const policy_version = try r.readU64();

    // source ordinal — safe conversion: iterate enum values instead of using
    // std.meta.intToEnum which was removed in Zig 0.16.
    const source_ord = try r.readByte();
    const source = sourceFromOrdinal(source_ord) orelse
        return EnvelopeError.InvalidSourceOrdinal;

    return .{
        .user_id = user_id,
        .username = username,
        .roles = roles,
        .custom_roles = custom_roles,
        .tenant_id = tenant_id,
        .active_graph = active_graph,
        .auth_version = auth_version,
        .policy_version = policy_version,
        .source = source,
    };
}

/// Safe byte → PrincipalSource conversion.
/// Zig 0.16 removed std.meta.intToEnum; `@enumFromInt` on an out-of-range byte
/// is undefined behaviour in ReleaseFast. This explicit switch is fail-closed.
fn sourceFromOrdinal(ord: u8) ?principal_mod.PrincipalSource {
    return switch (ord) {
        @intFromEnum(principal_mod.PrincipalSource.unattributed) => .unattributed,
        @intFromEnum(principal_mod.PrincipalSource.quic_handler) => .quic_handler,
        @intFromEnum(principal_mod.PrincipalSource.grpc_handler) => .grpc_handler,
        @intFromEnum(principal_mod.PrincipalSource.distributed_coordinator) => .distributed_coordinator,
        @intFromEnum(principal_mod.PrincipalSource.distributed_worker) => .distributed_worker,
        @intFromEnum(principal_mod.PrincipalSource.mcp_handler) => .mcp_handler,
        @intFromEnum(principal_mod.PrincipalSource.repl) => .repl,
        @intFromEnum(principal_mod.PrincipalSource.internal_service) => .internal_service,
        @intFromEnum(principal_mod.PrincipalSource.test_harness) => .test_harness,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// NEW-8 / #860 — Envelope trust gate
// ---------------------------------------------------------------------------

/// Returns true ONLY when the connection was authenticated as the federation
/// cluster identity ("geode-cluster"), meaning the other end proved possession
/// of GEODE_CLUSTER_TOKEN through validateFederationAuth().
///
/// On ANY other connection — including ReadWrite or Admin users — field 4
/// (principal_envelope_bytes) MUST be ignored entirely; the handler falls
/// through to derivePrincipal() from the session-authenticated identity.
///
/// The "geode-cluster" username is RESERVED in user_management.zig (returns
/// error.ReservedUsername on CREATE USER attempts) so a regular user cannot
/// claim this identity through normal authentication paths. That reservation
/// is the security invariant that makes this name check sufficient.
///
/// FOLLOW-UP (separate PR, do NOT change here): add HMAC-SHA256 over the
/// envelope bytes (key = GEODE_CLUSTER_TOKEN / GEODE_CLUSTER_TOKEN_PREVIOUS
/// rotation via validateTokenWithRotation) so the envelope is cryptographically
/// verified, not just connection-identity-based.
/// Design: serializeAndSign(allocator, env, token) / deserializeAndVerify(bytes, token).
// CANARY: REQ=REQ-NEW8-ENVELOPE-TRUST; FEATURE="EnvelopeTrustGate"; ASPECT=PureFunction; STATUS=TESTED; TEST=tests/test_new8_envelope_trust.zig; OWNER=security; UPDATED=2026-06-26
pub fn shouldTrustEnvelope(authenticated_user: ?[]const u8) bool {
    const u = authenticated_user orelse return false;
    return std.mem.eql(u8, u, "geode-cluster");
}

// ---------------------------------------------------------------------------
// Conversion helpers: Principal → PrincipalEnvelope and back
// ---------------------------------------------------------------------------

/// Build an envelope from a live Principal and the current policy_version.
/// All slice fields are borrowed from `p` — the envelope is only valid while
/// `p` is alive.
pub fn fromPrincipal(p: *const principal_mod.Principal, policy_version: u64) PrincipalEnvelope {
    return .{
        .user_id = p.user_id,
        .username = p.username,
        .roles = p.roles,
        .custom_roles = p.custom_roles,
        .tenant_id = p.tenant_id,
        .active_graph = p.active_graph,
        .auth_version = p.auth_version,
        .policy_version = policy_version,
        .source = p.source,
    };
}

/// Reconstruct a Principal from an envelope on the worker side.
/// All slice fields are borrowed from `env` (which in turn borrows from the
/// raw bytes passed to deserialize()). The caller must not free `env`'s
/// backing buffer while the returned Principal is in use.
pub fn toPrincipal(env: *const PrincipalEnvelope) principal_mod.Principal {
    return .{
        .user_id = env.user_id,
        .username = env.username,
        .session_id = null, // session-local, not forwarded
        .tenant_id = env.tenant_id,
        .active_graph = env.active_graph,
        .roles = env.roles,
        .custom_roles = env.custom_roles,
        .auth_method = .anonymous, // not forwarded; worker only needs identity
        .auth_version = env.auth_version,
        .mfa_state = .none, // session-local
        .elevation_until = null, // session-local
        .api_key_id = null, // not forwarded
        .certificate_subject = null, // not forwarded
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = env.source,
    };
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn appendU32(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), v: u32) !void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, v, .little);
    try buf.appendSlice(allocator, &tmp);
}

fn appendU64(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), v: u64) !void {
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(u64, &tmp, v, .little);
    try buf.appendSlice(allocator, &tmp);
}

fn appendLenPrefixedSlice(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try appendU32(allocator, buf, @intCast(s.len));
    try buf.appendSlice(allocator, s);
}

/// Cursor-based reader over a byte slice. Returns TruncatedEnvelope on short reads.
const Reader = struct {
    data: []const u8,
    pos: usize,

    fn init(data: []const u8) Reader {
        return .{ .data = data, .pos = 0 };
    }

    fn readBytes(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.data.len) return EnvelopeError.TruncatedEnvelope;
        const slice = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    fn readByte(self: *Reader) !u8 {
        const b = try self.readBytes(1);
        return b[0];
    }

    fn readU32(self: *Reader) !u32 {
        const b = try self.readBytes(4);
        return std.mem.readInt(u32, b[0..4], .little);
    }

    fn readU64(self: *Reader) !u64 {
        const b = try self.readBytes(8);
        return std.mem.readInt(u64, b[0..8], .little);
    }

    fn readLenPrefixedSlice(self: *Reader) ![]const u8 {
        const len = try self.readU32();
        return try self.readBytes(len);
    }
};

// Static role buffer: good enough for unit tests and typical cluster RPCs where
// a principal carries at most a handful of roles.
//
// Thread-safety note: this is threadlocal, so concurrent calls on different
// threads are safe. Within a single thread, resetStaticRoleBuffer() is called
// at the start of each deserialize() call so the buffer is always clean.
// Production wiring (Phase 7) can switch to an allocator-based path if needed.
const MAX_ROLES_STATIC = 64;
threadlocal var static_role_buf: [MAX_ROLES_STATIC][]const u8 = undefined;
threadlocal var static_role_buf_used: usize = 0;

/// Reset the thread-local role buffer. Called automatically at the start of
/// deserialize(); exposed for tests that call deserialize() in a tight loop.
pub fn resetStaticRoleBuffer() void {
    static_role_buf_used = 0;
}
