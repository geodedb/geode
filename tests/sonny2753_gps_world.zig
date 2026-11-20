// SONNY-2753 / SONNY-2781: the in-process deployment the GPS policy-scope and
// per-action enforcement regressions share. Authorization on, graphs
// `default`, `g1` and `g2` (one :C node each, `default` also a :Seed), a real
// live grant table (`GraphRBACPolicy`) served to gps as
// `server_init.graphGrantCheck` serves it, a real global `PolicyCatalog`
// (deny policies go in through `addPolicyStrict`, the only way one is made
// today besides `__geode_security` hydration), and the in-process gRPC
// Execute handler (the SONNY-1560 shim), as tests/test_per_graph_grants.zig.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");

pub const gps = geode.security.gps;
pub const principal_mod = geode.security.principal;
pub const policy_catalog = geode.security.policy_catalog;
pub const decision_cache = geode.security.decision_cache;
pub const mgs = geode.multi_graph_security;
pub const user_mgmt = geode.user_management;
pub const graph_store = geode.graph_store;
pub const Role = user_mgmt.Role;
pub const PolicyCatalog = policy_catalog.PolicyCatalog;
pub const Kind = gps.PolicyDecisionKind;

pub const READ: u8 = 0;
pub const WRITE: u8 = 1;
pub const SCHEMA: u8 = 2;

const users = [_]struct { name: []const u8, id: u64 }{
    .{ .name = "otto", .id = 11 }, // readonly
    .{ .name = "rita", .id = 12 }, // readwrite
    .{ .name = "ada", .id = 14 }, // admin
    .{ .name = "nora", .id = 15 }, // no stored role
};

fn userId(name: []const u8) ?u64 {
    for (users) |u| if (std.mem.eql(u8, u.name, name)) return u.id;
    return null;
}

/// `server_init.graphGrantCheck` with a fixed user table.
fn liveGrantCheck(username: []const u8, graph_name: []const u8, action: u8) bool {
    const uid = userId(username) orelse return false;
    const pol = mgs.getGlobalPolicy() orelse return false;
    return pol.hasGraphGrant(uid, graph_name, action);
}

pub fn principal(username: []const u8, roles: []const []const u8, auth_version: u64) principal_mod.Principal {
    return .{
        .user_id = null,
        .username = username,
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = roles,
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = auth_version,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .test_harness,
    };
}

pub fn decideKind(p: *const principal_mod.Principal, action: gps.Action, resource: gps.ResourceRef) !Kind {
    const req = gps.DecisionRequest{ .principal = p, .action = action, .resource = resource };
    return (try gps.decide(testing.allocator, &req)).kind;
}

fn encodeProto(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    return allocator.dupe(u8, aw.written());
}

fn decodeProto(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !T {
    var reader: std.Io.Reader = .fixed(bytes);
    return protobuf.decode(T, &reader, allocator);
}

/// `query` through the real gRPC Execute handler: null when it ran, else
/// the refusal.
pub fn outcome(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !?schema.Error {
    const req = try encodeProto(ga, schema.ExecuteRequest{ .session_id = session_id, .query = query, .params = .empty });
    const resp = try decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
    return switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| e,
        else => null,
    };
}

pub fn expectRuns(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !void {
    if (try outcome(ga, session_id, query)) |e| {
        std.debug.print("expected `{s}` to run, refused {s} '{s}'\n", .{ query, e.code, e.message });
        return error.ExpectedToRun;
    }
}

/// Refused by authorization: 42501.
pub fn expectDenied(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !void {
    const e = (try outcome(ga, session_id, query)) orelse {
        std.debug.print("expected `{s}` to be refused (42501), it ran\n", .{query});
        return error.ExpectedRefusal;
    };
    if (!std.mem.eql(u8, e.code, "42501")) {
        std.debug.print("`{s}`: refused {s} '{s}', expected 42501\n", .{ query, e.code, e.message });
        return error.WrongRefusal;
    }
}

/// Not refused by authorization: it ran, or failed for another reason.
pub fn expectNotDenied(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !void {
    if (try outcome(ga, session_id, query)) |e| {
        if (std.mem.eql(u8, e.code, "42501")) {
            std.debug.print("`{s}`: refused by authorization '{s}'\n", .{ query, e.message });
            return error.UnexpectedAuthorizationRefusal;
        }
    }
}

pub fn countIn(graph: []const u8, label: []const u8) usize {
    const st = graph_store.getGlobalStore(testing.allocator);
    const ids = st.getNodesByLabel(graph, label) orelse return 0;
    return ids.len;
}

pub const World = struct {
    h: harness.Harness,
    arena: std.heap.ArenaAllocator,
    sessions: grpc.SessionStore,
    pol: mgs.GraphRBACPolicy,
    cat: PolicyCatalog,
    auth_was_enabled: bool,
    allow_was: bool,
    strict_was: bool,
    prev_grant_fn: ?*const fn ([]const u8, []const u8, u8) bool,
    prev_pol: ?*mgs.GraphRBACPolicy,

    pub fn init(self: *World) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        try self.h.seed(&.{ "CREATE (:Seed {v: 1})", "CREATE (:C {v: 0})" });
        const st = graph_store.getGlobalStore(testing.allocator);
        _ = geode.txn_undo_log.getGlobalUndoLog(testing.allocator);
        for ([_][]const u8{ "g1", "g2" }) |g| {
            _ = try st.createGraph(g);
            _ = try st.createNodeWithGraph(&[_][]const u8{"C"}, g);
        }

        self.auth_was_enabled = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        self.allow_was = gps.isInsecureAllowAll();
        gps.setInsecureAllowAll(false);
        self.strict_was = geode.tenancy.isStrictTenancy();
        geode.tenancy.setStrictTenancy(false);
        self.pol = mgs.GraphRBACPolicy.init(testing.allocator);
        self.prev_pol = mgs.getGlobalPolicy();
        mgs.setGlobalPolicy(&self.pol);
        self.prev_grant_fn = geode.execution.graph_grant_check_fn;
        geode.execution.graph_grant_check_fn = &liveGrantCheck;
        self.cat = PolicyCatalog.init(testing.allocator);
        policy_catalog.setGlobalCatalog(&self.cat);

        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
    }

    pub fn deinit(self: *World) void {
        grpc.setSessionStore(null);
        self.sessions.deinit();
        self.arena.deinit();
        policy_catalog.clearGlobalCatalog();
        self.cat.deinit();
        geode.execution.graph_grant_check_fn = self.prev_grant_fn;
        mgs.setGlobalPolicy(self.prev_pol);
        self.pol.deinit();
        geode.tenancy.setStrictTenancy(self.strict_was);
        gps.setInsecureAllowAll(self.allow_was);
        user_mgmt.setAuthEnabled(self.auth_was_enabled);
        geode.txn_undo_log.setThreadTxnId(0);
        self.h.deinit();
    }

    pub fn ga(self: *World) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn session(self: *World, username: []const u8, role: Role, graph: ?[]const u8) ![]const u8 {
        return self.sessions.createSession(username, "", role, null, graph, false, 0);
    }

    pub fn grant(self: *World, user: []const u8, graph: []const u8, action: u8) !void {
        try self.pol.grantGraphPermission(userId(user).?, graph, action);
    }

    /// A policy through the strict catalog add, as DDL adds one.
    pub fn policy(self: *World, name: []const u8, scope: []const u8, actions: []const policy_catalog.Action, effect: policy_catalog.Effect) !void {
        try self.cat.addPolicyStrict(.{ .name = name, .scope_graph = scope, .actions = actions, .effect = effect, .expression_source = "true", .enabled = true });
    }

    pub fn drop(self: *World, name: []const u8) !void {
        try self.cat.removePolicy(name);
    }
};
