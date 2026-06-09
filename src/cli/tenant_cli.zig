const std = @import("std");

// GAP-0839: `geode tenant` CLI subcommand.
//
// A thin client front-end over the existing authorized `CALL geode.tenant.*`
// surface (src/execution/tenant_dispatch.zig). It carries NO registry/authz
// business logic of its own — it CONNECTS to a running server and issues a CALL,
// and the server's dispatch + the fail-closed `admin_tenant` GPS gate do all the
// real work (create/list/show/drop/set_quota against the durable tenant registry
// + GAP-0838 hierarchy + GAP-0289 quota manager).
//
// Connection / auth / flag-parsing mirror `geode query` (src/cli/main.zig
// `cmdQuery`): the tenant CLI reuses the SAME client by delegating to `cmdQuery`
// with a synthesized argv (the CALL string + the passed-through connection
// flags), exactly the way `cli_dispatcher.cmdQueryImplicit` re-routes a bare GQL
// query to the query command. This guarantees identical DSN/--user/--password/
// --insecure-tls-skip-verify handling and identical error/exit conventions.
//
// NOTE on why this is NOT modeled on `cmdUser`: `cmdUser` operates OFFLINE on a
// local data dir (cli_auth.initCliAuthManager). Tenant administration is gated
// on the server-side `admin_tenant` action, so a connecting client is required —
// the plan's R1 note explicitly prefers this when cmdUser is local-only.

// Exit codes consistent with the rest of the CLI.
const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
};

// The dispatcher's command-handler signature. Declared locally (rather than
// imported from cli_dispatcher.zig) so the pure `buildTenantCallQuery` test can
// import this file without dragging the whole dispatcher in.
pub const CommandHandler = fn (allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) anyerror!void;

// tenant_quota.TenantQuota defaults — used to fill the dispatch-required quota
// positionals for `set-quota` dimensions the operator did not specify. Kept in
// sync with src/security/tenant_quota.zig (TenantQuota field defaults).
const default_max_connections: u32 = 100;
const default_max_concurrent_queries: u32 = 32;
const default_max_graphs: u32 = 100;
const default_max_nodes_per_graph: u64 = 1_000_000;

pub const BuildError = error{
    UnknownTenantSubcommand,
    MissingTenantId,
    InvalidTenantId,
    InvalidQuotaValue,
    OutOfMemory,
};

/// Validate a tenant id used inside a single-quoted GQL string literal.
///
/// Ids come from a trusted admin CLI, but we reject single quotes (and the GQL
/// statement separator) defensively so a tenant id can never break out of the
/// literal and inject GQL. We reject rather than escape: tenant ids are
/// identifiers, and a `'` in one is far more likely a mistake/attack than a
/// legitimate name.
fn validateTenantId(id: []const u8) BuildError!void {
    if (id.len == 0) return error.MissingTenantId;
    for (id) |c| {
        if (c == '\'' or c == ';' or c == '\\' or c == 0) return error.InvalidTenantId;
    }
}

/// Build the `CALL geode.tenant.<op>(...)` query string from a tenant
/// subcommand + its args (argv AFTER the `tenant` token; `args[0]` is the
/// subcommand). Pure and deterministic — no server, no I/O. Caller owns the
/// returned slice (free with `allocator.free`).
///
/// Subcommand → CALL mapping (arg shapes per tenant_dispatch.zig):
///   create <id> [--parent <p>]            → geode.tenant.create('id'[, 'p'])
///   list                                  → geode.tenant.list()
///   show <id>                             → geode.tenant.show('id')
///   drop <id>                             → geode.tenant.drop('id')
///   set-quota <id> [--max-connections N] [--max-concurrent-queries N]
///             [--max-graphs N] [--max-nodes-per-graph N]
///                                         → geode.tenant.set_quota('id', a, b, c, d)
///     (set_quota requires all 4 integer positionals; omitted dims default to
///      the TenantQuota defaults above.)
pub fn buildTenantCallQuery(allocator: std.mem.Allocator, args: []const []const u8) BuildError![]const u8 {
    if (args.len == 0) return error.UnknownTenantSubcommand;
    const sub = args[0];

    if (std.mem.eql(u8, sub, "list")) {
        return allocator.dupe(u8, "CALL geode.tenant.list()");
    }

    if (std.mem.eql(u8, sub, "create")) {
        if (args.len < 2) return error.MissingTenantId;
        const id = args[1];
        try validateTenantId(id);
        var parent: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--parent")) {
                if (i + 1 >= args.len) return error.MissingTenantId;
                parent = args[i + 1];
                i += 1;
            }
        }
        if (parent) |p| {
            try validateTenantId(p);
            return std.fmt.allocPrint(allocator, "CALL geode.tenant.create('{s}', '{s}')", .{ id, p });
        }
        return std.fmt.allocPrint(allocator, "CALL geode.tenant.create('{s}')", .{id});
    }

    if (std.mem.eql(u8, sub, "show")) {
        if (args.len < 2) return error.MissingTenantId;
        const id = args[1];
        try validateTenantId(id);
        return std.fmt.allocPrint(allocator, "CALL geode.tenant.show('{s}')", .{id});
    }

    if (std.mem.eql(u8, sub, "drop")) {
        if (args.len < 2) return error.MissingTenantId;
        const id = args[1];
        try validateTenantId(id);
        return std.fmt.allocPrint(allocator, "CALL geode.tenant.drop('{s}')", .{id});
    }

    if (std.mem.eql(u8, sub, "set-quota") or std.mem.eql(u8, sub, "set_quota")) {
        if (args.len < 2) return error.MissingTenantId;
        const id = args[1];
        try validateTenantId(id);
        var max_connections: u32 = default_max_connections;
        var max_concurrent_queries: u32 = default_max_concurrent_queries;
        var max_graphs: u32 = default_max_graphs;
        var max_nodes_per_graph: u64 = default_max_nodes_per_graph;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--max-connections")) {
                if (i + 1 >= args.len) return error.InvalidQuotaValue;
                max_connections = std.fmt.parseInt(u32, args[i + 1], 10) catch return error.InvalidQuotaValue;
                i += 1;
            } else if (std.mem.eql(u8, a, "--max-concurrent-queries")) {
                if (i + 1 >= args.len) return error.InvalidQuotaValue;
                max_concurrent_queries = std.fmt.parseInt(u32, args[i + 1], 10) catch return error.InvalidQuotaValue;
                i += 1;
            } else if (std.mem.eql(u8, a, "--max-graphs")) {
                if (i + 1 >= args.len) return error.InvalidQuotaValue;
                max_graphs = std.fmt.parseInt(u32, args[i + 1], 10) catch return error.InvalidQuotaValue;
                i += 1;
            } else if (std.mem.eql(u8, a, "--max-nodes-per-graph")) {
                if (i + 1 >= args.len) return error.InvalidQuotaValue;
                max_nodes_per_graph = std.fmt.parseInt(u64, args[i + 1], 10) catch return error.InvalidQuotaValue;
                i += 1;
            }
        }
        return std.fmt.allocPrint(
            allocator,
            "CALL geode.tenant.set_quota('{s}', {d}, {d}, {d}, {d})",
            .{ id, max_connections, max_concurrent_queries, max_graphs, max_nodes_per_graph },
        );
    }

    return error.UnknownTenantSubcommand;
}

fn printTenantUsage() void {
    const usage =
        \\geode tenant - Tenant lifecycle administration (admin_tenant only)
        \\
        \\Usage: geode tenant <command> [options] [connection-flags]
        \\
        \\Commands:
        \\  create <id> [--parent <parent-id>]   Create a tenant (optionally under a parent)
        \\  list                                 List all tenants
        \\  show <id>                            Show a tenant's record
        \\  drop <id>                            Drop a tenant
        \\  set-quota <id> [--max-connections N] [--max-concurrent-queries N]
        \\                 [--max-graphs N] [--max-nodes-per-graph N]
        \\                                       Set per-tenant quotas (omitted dims keep defaults)
        \\
        \\Connection flags (same as `geode query`):
        \\  --dsn <conn-str> | --server <host:port>
        \\  --user <name> --password <pw>
        \\  --insecure-tls-skip-verify   --grpc
        \\  --ca-cert <p> --client-cert <p> --client-key <p>
        \\
        \\Tenant administration is gated on the server-side `admin_tenant` action;
        \\an unauthorized caller is rejected by the server.
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn hasHelpFlag(argv: [][:0]u8, from: usize) bool {
    var i = from;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--help") or std.mem.eql(u8, argv[i], "-h")) return true;
    }
    return false;
}

/// Is `arg` (and possibly a following value) a connection/output flag we should
/// pass straight through to `cmdQuery`? Returns the number of argv slots the
/// flag consumes (1 for a bare flag, 2 for flag+value), or 0 if it is not a
/// recognized passthrough flag.
fn passthroughFlagWidth(arg: []const u8) usize {
    // Bare (no value) passthrough flags.
    const bare = [_][]const u8{
        "--insecure-tls-skip-verify", "--insecure", "--grpc", "--batch", "--no-saved-session",
    };
    for (bare) |f| {
        if (std.mem.eql(u8, arg, f)) return 1;
    }
    // Valued passthrough flags (flag + its argument).
    const valued = [_][]const u8{
        "--dsn",               "--server",                     "--user",    "--username",    "-U",
        "--password",          "--pass",                       "-P",        "--token",       "--format",
        "--graph",             "-g",                           "--ca-cert", "--client-cert", "--client-key",
        "--timeout",           "--page-size",                  "--retry",   "--log-level",   "--role",
        "--forward-principal", "--forward-principal-envelope",
    };
    for (valued) |f| {
        if (std.mem.eql(u8, arg, f)) return 2;
    }
    return 0;
}

/// `geode tenant` command handler. Parses the subcommand + tenant-specific args,
/// builds the CALL string via `buildTenantCallQuery`, then delegates to the
/// existing `cmdQuery` (passed in by the dispatcher) with a synthesized argv so
/// the connection/auth/flag handling is byte-for-byte identical to `geode
/// query`. `start_idx` points at the `tenant` token in `argv`.
pub fn cmdTenant(
    allocator: std.mem.Allocator,
    argv: [][:0]u8,
    start_idx: usize,
    cmdQuery: *const CommandHandler,
) !void {
    const sub_idx = start_idx + 1;
    if (sub_idx >= argv.len) {
        std.debug.print("Error: missing tenant subcommand\n", .{});
        printTenantUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const subcommand = argv[sub_idx];
    if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        printTenantUsage();
        return;
    }
    if (hasHelpFlag(argv, sub_idx + 1)) {
        printTenantUsage();
        return;
    }

    // Split argv after the `tenant` token into:
    //   tenant_args   — the subcommand + its positional/tenant-specific args
    //   passthrough   — connection/output flags forwarded verbatim to cmdQuery
    // A connection flag may appear anywhere after the subcommand.
    var tenant_args = std.ArrayList([]const u8).empty;
    defer tenant_args.deinit(allocator);
    var passthrough = std.ArrayList([:0]u8).empty;
    defer passthrough.deinit(allocator);

    var i = sub_idx;
    while (i < argv.len) : (i += 1) {
        const w = passthroughFlagWidth(argv[i]);
        if (w == 0) {
            try tenant_args.append(allocator, argv[i]);
        } else {
            try passthrough.append(allocator, argv[i]);
            if (w == 2) {
                if (i + 1 < argv.len) {
                    try passthrough.append(allocator, argv[i + 1]);
                    i += 1;
                }
            }
        }
    }

    const call_query = buildTenantCallQuery(allocator, tenant_args.items) catch |err| {
        switch (err) {
            error.UnknownTenantSubcommand => std.debug.print("Error: unknown tenant subcommand '{s}'\n", .{subcommand}),
            error.MissingTenantId => std.debug.print("Error: tenant {s} requires a tenant id\n", .{subcommand}),
            error.InvalidTenantId => std.debug.print("Error: invalid tenant id (single quotes, semicolons, backslashes and NULs are not allowed)\n", .{}),
            error.InvalidQuotaValue => std.debug.print("Error: quota values must be non-negative integers\n", .{}),
            error.OutOfMemory => return err,
        }
        printTenantUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    };
    defer allocator.free(call_query);

    // Synthesize argv for cmdQuery: ["geode", "query", "<CALL...>", <passthrough...>]
    // cmdQuery is invoked with start_idx pointing at the "query" token (index 1),
    // mirroring cli_dispatcher.cmdQueryImplicit.
    const call_query_z = try allocator.dupeZ(u8, call_query);
    defer allocator.free(call_query_z);
    const geode_z = try allocator.dupeZ(u8, "geode");
    defer allocator.free(geode_z);
    const query_z = try allocator.dupeZ(u8, "query");
    defer allocator.free(query_z);

    var new_argv = try allocator.alloc([:0]u8, 3 + passthrough.items.len);
    defer allocator.free(new_argv);
    new_argv[0] = geode_z;
    new_argv[1] = query_z;
    new_argv[2] = call_query_z;
    for (passthrough.items, 0..) |p, idx| {
        new_argv[3 + idx] = p;
    }

    try cmdQuery(allocator, new_argv, 1);
}

test "buildTenantCallQuery list" {
    const a = std.testing.allocator;
    const q = try buildTenantCallQuery(a, &.{"list"});
    defer a.free(q);
    try std.testing.expectEqualStrings("CALL geode.tenant.list()", q);
}

test "buildTenantCallQuery rejects single-quote injection" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidTenantId, buildTenantCallQuery(a, &.{ "drop", "a'b" }));
}
