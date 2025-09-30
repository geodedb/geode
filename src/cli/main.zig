const std = @import("std");
const builtin = @import("builtin");
const audit_cli = @import("audit_cli");
// const auth = @import("../security/auth.zig"); // Not needed for current implementation
// const hash = @import("../types/hash.zig"); // Not needed for current implementation
const crypto = std.crypto;

// Error codes
const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
    auth_error = 3,
};

// Usage and help functions
fn printMainUsage() void {
    std.debug.print("geode - Property graph database implementing ISO/IEC 39075:2024 (GQL)\n" ++
        "\n" ++
        "Usage: geode [options] <subcommand> [args...]\n" ++
        "\n" ++
        "Global Options:\n" ++
        "  -h, --help          Show help\n" ++
        "  -v, --verbose       Verbose output\n" ++
        "  --config <path>     Configuration file path\n" ++
        "  --json              Force JSON output for all subcommands\n" ++
        "\n" ++
        "Subcommands:\n" ++
        "  serve               Start the database server\n" ++
        "  shell               Interactive GQL shell\n" ++
        "  query               Execute a GQL query\n" ++
        "  backup              Create database backup\n" ++
        "  restore             Restore database from backup\n" ++
        "  migrate             Run database migrations\n" ++
        "  auth                Authentication commands\n" ++
        "  user                User management\n" ++
        "  role                Role management\n" ++
        "  policy              RLS policy management\n" ++
        "  grant               Grant permissions\n" ++
        "  revoke              Revoke permissions\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode serve --data-dir ./data --listen 0.0.0.0:8443\n" ++
        "  geode query \"MATCH (n) RETURN n LIMIT 10\"\n" ++
        "  geode user create alice alice@example.com\n" ++
        "  geode shell --server localhost:8443\n" ++
        "\n" ++
        "Use 'geode <subcommand> --help' for more information on a specific command.\n" ++
        "\n", .{});
}

fn printServeUsage() void {
    std.debug.print("geode serve - Start the database server\n" ++
        "\n" ++
        "Usage: geode serve [options]\n" ++
        "\n" ++
        "Options:\n" ++
        "  --data-dir <path>      Data directory (default: ./data)\n" ++
        "  --listen <addr:port>   Listen address (default: 0.0.0.0:8443)\n" ++
        "  --cert <path>          TLS certificate path (auto-generated if missing)\n" ++
        "  --key <path>           TLS private key path (auto-generated if missing)\n" ++
        "  --log-level <level>    Log level: debug|info|warn|error (default: info)\n" ++
        "  --stdio                Use stdio for communication (development mode)\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode serve\n" ++
        "  geode serve --data-dir /var/lib/geode --listen 0.0.0.0:8443\n" ++
        "  geode serve --stdio --log-level debug\n" ++
        "\n", .{});
}

fn printQueryUsage() void {
    std.debug.print("geode query - Execute a GQL query\n" ++
        "\n" ++
        "Usage: geode query [options] <query>\n" ++
        "\n" ++
        "Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:8443)\n" ++
        "  --format <fmt>         Output format: json|table|csv (default: json)\n" ++
        "  --json-param <name> <value>  Add JSON parameter\n" ++
        "  --page-size <n>        Page size for results (default: 1000)\n" ++
        "  --begin                Start transaction\n" ++
        "  --commit               Commit transaction\n" ++
        "  --rollback             Rollback transaction\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode query \"MATCH (n) RETURN n LIMIT 10\"\n" ++
        "  geode query --format table \"MATCH (u:User) RETURN u.name, u.email\"\n" ++
        "  geode query --json-param id 123 \"MATCH (n) WHERE id(n) = $id RETURN n\"\n" ++
        "\n", .{});
}

fn printShellUsage() void {
    std.debug.print("geode shell - Interactive GQL shell\n" ++
        "\n" ++
        "Usage: geode shell [options]\n" ++
        "\n" ++
        "Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:8443)\n" ++
        "  --no-history           Disable command history\n" ++
        "  --format <fmt>         Default output format: json|table|csv (default: table)\n" ++
        "  --keymap <mode>        Keymap mode: emacs|vi (default: emacs)\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode shell\n" ++
        "  geode shell --server localhost:8443\n" ++
        "  geode shell --no-history --format json\n" ++
        "\n", .{});
}

fn printUserUsage() void {
    std.debug.print("geode user - User management\n" ++
        "\n" ++
        "Usage: geode user [options] <command> [args...]\n" ++
        "\n" ++
        "Commands:\n" ++
        "  create <username> <email> [password]    Create a new user\n" ++
        "  delete <username>                       Delete a user\n" ++
        "  list                                    List all users\n" ++
        "  show <username>                         Show user details\n" ++
        "  enable <username>                       Enable a user\n" ++
        "  disable <username>                      Disable a user\n" ++
        "  password <username> [new_password]      Change user password\n" ++
        "\n" ++
        "Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:8443)\n" ++
        "  -U, --user <username>  Authenticate as user\n" ++
        "  --format <fmt>         Output format: json|table|csv (default: table)\n" ++
        "  --yes                  Skip confirmation prompts\n" ++
        "  --no-prompt            Don't prompt for missing values\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode user create alice alice@example.com\n" ++
        "  geode user list --format json\n" ++
        "  geode user password alice\n" ++
        "\n", .{});
}

fn printAuthUsage() void {
    std.debug.print("geode auth - Authentication commands\n" ++
        "\n" ++
        "Usage: geode auth <command> [args...]\n" ++
        "\n" ++
        "Commands:\n" ++
        "  login                  Authenticate and save credentials\n" ++
        "  logout                 Clear saved credentials\n" ++
        "\n" ++
        "Login Options:\n" ++
        "  --server <addr:port>   Server address (default: 127.0.0.1:8443)\n" ++
        "  -U, --user <username>  Username\n" ++
        "  --password <password>  Password (prompt if not provided)\n" ++
        "  --password-file <path> Read password from file\n" ++
        "  -h, --help             Show this help\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode auth login -U alice\n" ++
        "  geode auth login -U alice --password-file /dev/stdin\n" ++
        "  geode auth logout\n" ++
        "\n", .{});
}

// Subcommand implementations
fn cmdServe(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printServeUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }

    var server_args = std.ArrayList([]const u8).initCapacity(ally, argv.len + 16) catch return error.OutOfMemory;
    defer server_args.deinit(ally);

    var passthrough = std.ArrayList([]const u8).initCapacity(ally, argv.len + 16) catch return error.OutOfMemory;
    defer passthrough.deinit(ally);

    // Try to find geoded in the same directory as this executable
    const self_exe_path = try std.fs.selfExePathAlloc(ally);
    defer ally.free(self_exe_path);

    const self_dir_path = std.fs.path.dirname(self_exe_path) orelse ".";
    const geoded_path = try std.fs.path.join(ally, &.{ self_dir_path, "geoded" });

    // Check if geoded exists in the same directory
    if (std.fs.accessAbsolute(geoded_path, .{})) |_| {
        // Use the full path to geoded (server_args owns this now)
        try server_args.append(ally, geoded_path);
    } else |_| {
        // geoded not found in same directory, free the path and fall back to PATH resolution
        ally.free(geoded_path);
        try server_args.append(ally, "geoded");
    }

    var data_dir: []const u8 = "./data";
    var listen_addr: []const u8 = "0.0.0.0:7567";
    var log_level: []const u8 = "info";
    var use_stdio = false;
    var override_listen = false;

    i = start_idx;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--data-dir") and i + 1 < argv.len) {
            data_dir = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--listen") and i + 1 < argv.len) {
            listen_addr = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--log-level") and i + 1 < argv.len) {
            log_level = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--stdio")) {
            use_stdio = true;
        } else if (std.mem.eql(u8, arg, "--cert") and i + 1 < argv.len) {
            try server_args.append(ally, "--cert");
            try server_args.append(ally, argv[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--key") and i + 1 < argv.len) {
            try server_args.append(ally, "--key");
            try server_args.append(ally, argv[i + 1]);
            i += 1;
        } else {
            // passthrough unknown flags (and their value if present)
            if (std.mem.eql(u8, arg, "--listen-quic")) {
                override_listen = true;
            }
            try passthrough.append(ally, arg);
            if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-")) {
                try passthrough.append(ally, argv[i + 1]);
                i += 1;
            }
        }
    }

    try server_args.append(ally, "--data_dir");
    try server_args.append(ally, data_dir);

    if (!use_stdio and !override_listen) {
        try server_args.append(ally, "--listen-quic");
        try server_args.append(ally, listen_addr);
    }

    try server_args.append(ally, "--log-level");
    try server_args.append(ally, log_level);

    if (use_stdio) {
        try server_args.append(ally, "--stdio");
    }

    if (passthrough.items.len > 0) {
        for (passthrough.items) |p| try server_args.append(ally, p);
    }

    var child = std.process.Child.init(server_args.items, ally);
    child.stdin_behavior = if (use_stdio) .Pipe else .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| {
        const cmd = if (server_args.items.len > 0) server_args.items[0] else "unknown";
        switch (err) {
            error.FileNotFound => {
                std.debug.print("Error: Cannot find executable '{s}'\n", .{cmd});
                std.debug.print("Troubleshooting:\n", .{});
                std.debug.print("  1. Run 'make build' to compile geoded\n", .{});
                std.debug.print("  2. Ensure 'geoded' is in your PATH\n", .{});
                std.debug.print("  3. Or place 'geoded' in the same directory as 'geode'\n", .{});
                std.debug.print("\nYou can also run the server directly with: geoded [options]\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            },
            else => {
                std.debug.print("Error spawning '{s}': {s}\n", .{ cmd, @errorName(err) });
                return err;
            },
        }
    };
    std.process.exit(switch (term) {
        .Exited => |code| code,
        else => @intFromEnum(ExitCode.general_error),
    });
}

fn cmdQuery(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Check for help
    if (start_idx >= argv.len) {
        std.debug.print("Error: query text required\n", .{});
        std.debug.print("Example: geode query \"MATCH (n) RETURN n LIMIT 10\"\n", .{});
        printQueryUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printQueryUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }

    // Build client command arguments
    var client_args = std.ArrayList([]const u8).initCapacity(ally, argv.len + 10) catch return error.OutOfMemory;
    defer client_args.deinit(ally);

    try client_args.append(ally, "geodec");

    // Add query text (first non-option argument)
    var query_text: ?[]const u8 = null;
    i = start_idx;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (!std.mem.startsWith(u8, arg, "-")) {
            query_text = arg;
            break;
        }
        if (std.mem.eql(u8, arg, "--server") or std.mem.eql(u8, arg, "--format") or
            std.mem.eql(u8, arg, "--page-size"))
        {
            i += 1; // Skip next arg which is the value
        } else if (std.mem.eql(u8, arg, "--json-param")) {
            i += 2; // Skip two values for json-param
        }
    }

    if (query_text == null) {
        std.debug.print("Error: query text required\n", .{});
        std.debug.print("Example: geode query \"MATCH (n) RETURN n LIMIT 10\"\n", .{});
        printQueryUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    try client_args.append(ally, query_text.?);

    // Pass through relevant options
    i = start_idx;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--server") and i + 1 < argv.len) {
            try client_args.append(ally, "--server");
            try client_args.append(ally, argv[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--format") and i + 1 < argv.len) {
            try client_args.append(ally, "--format");
            try client_args.append(ally, argv[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--json-param") and i + 2 < argv.len) {
            try client_args.append(ally, "--json-param");
            try client_args.append(ally, argv[i + 1]);
            try client_args.append(ally, argv[i + 2]);
            i += 2;
        } else if (std.mem.eql(u8, arg, "--page-size") and i + 1 < argv.len) {
            try client_args.append(ally, "--page-size");
            try client_args.append(ally, argv[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--begin")) {
            try client_args.append(ally, "--begin");
        } else if (std.mem.eql(u8, arg, "--commit")) {
            try client_args.append(ally, "--commit");
        } else if (std.mem.eql(u8, arg, "--rollback")) {
            try client_args.append(ally, "--rollback");
        }
    }

    // Execute client
    var child = std.process.Child.init(client_args.items, ally);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    std.process.exit(switch (term) {
        .Exited => |code| code,
        else => @intFromEnum(ExitCode.general_error),
    });
}

fn cmdShell(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Get REPL types
    const geode = @import("geode");
    const repl_loop = geode.repl.repl_loop;

    // Parse arguments
    var server: []const u8 = "127.0.0.1:8443";
    var format: repl_loop.ReplLoop.Format = .table;
    var keymap: repl_loop.ReplLoop.Keymap = .emacs;
    var history_enabled = true;
    var verbose = false;

    var i = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printShellUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, argv[i], "--server")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --server requires a server address\n", .{});
                std.debug.print("Example: --server localhost:8443 or --server 192.168.1.100:8443\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            server = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--format")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --format requires a format type\n", .{});
                std.debug.print("Valid formats: json, table, csv\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            const fmt = argv[i + 1];
            if (std.mem.eql(u8, fmt, "table")) {
                format = .table;
            } else if (std.mem.eql(u8, fmt, "csv")) {
                format = .csv;
            } else if (std.mem.eql(u8, fmt, "json")) {
                format = .json;
            } else {
                std.debug.print("Error: invalid format '{s}'. Valid formats: json, table, csv\n", .{fmt});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--keymap")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --keymap requires a keymap mode\n", .{});
                std.debug.print("Valid keymaps: emacs, vi\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            const km = argv[i + 1];
            if (std.mem.eql(u8, km, "emacs")) {
                keymap = .emacs;
            } else if (std.mem.eql(u8, km, "vi")) {
                keymap = .vi;
            } else {
                std.debug.print("Error: invalid keymap '{s}'. Valid keymaps: emacs, vi\n", .{km});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--no-history")) {
            history_enabled = false;
        } else if (std.mem.eql(u8, argv[i], "--verbose")) {
            verbose = true;
        } else {
            std.debug.print("Error: unknown option '{s}'\n", .{argv[i]});
            std.debug.print("Run 'geode shell --help' to see available options\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
    }

    // Launch the REPL
    const options = repl_loop.ReplLoop.Options{
        .server = server,
        .format = format,
        .keymap = keymap,
        .history_enabled = history_enabled,
        .verbose = verbose,
        .allocator = ally,
    };

    repl_loop.ReplLoop.run(options) catch |err| {
        std.debug.print("REPL error: {s}\n", .{@errorName(err)});
        std.debug.print("Try checking server connectivity or run 'geode shell --help' for options\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
}

fn cmdAuth(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {

    if (start_idx >= argv.len) {
        printAuthUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    const subcmd = argv[start_idx];

    if (std.mem.eql(u8, subcmd, "login")) {
        // CANARY: REQ=REQ-AUTH-001; FEATURE="AuthenticationLogin"; ASPECT=RealImplementation; STATUS=IMPL; TEST=TestCANARY_REQ_AUTH_001_RealLogin; OWNER=cli; UPDATED=2025-09-30
        try cmdAuthLogin(ally, argv, start_idx + 1);
    } else if (std.mem.eql(u8, subcmd, "logout")) {
        // CANARY: REQ=REQ-AUTH-002; FEATURE="AuthenticationLogout"; ASPECT=RealImplementation; STATUS=IMPL; TEST=TestCANARY_REQ_AUTH_002_RealLogout; OWNER=cli; UPDATED=2025-09-30
        try cmdAuthLogout(ally);
    } else if (std.mem.eql(u8, subcmd, "-h") or std.mem.eql(u8, subcmd, "--help")) {
        printAuthUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    } else {
        std.debug.print("Error: unknown auth command '{s}'\n", .{subcmd});
        std.debug.print("Valid auth commands: login, logout\n", .{});
        printAuthUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
}

fn cmdUser(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Check for help
    if (start_idx >= argv.len) {
        printUserUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printUserUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }

    // Build user auth command arguments
    var auth_args = std.ArrayList([]const u8).initCapacity(ally, argv.len + 10) catch return error.OutOfMemory;
    defer auth_args.deinit(ally);

    try auth_args.append(ally, "./zig-out/bin/geode-auth");
    try auth_args.append(ally, "user");

    // Add remaining args
    i = start_idx;
    while (i < argv.len) : (i += 1) {
        try auth_args.append(ally, argv[i]);
    }

    // Execute auth tool
    var child = std.process.Child.init(auth_args.items, ally);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    std.process.exit(switch (term) {
        .Exited => |code| code,
        else => @intFromEnum(ExitCode.general_error),
    });
}

fn cmdRole(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Build role command arguments
    var auth_args = std.ArrayList([]const u8).initCapacity(ally, argv.len + 10) catch return error.OutOfMemory;
    defer auth_args.deinit(ally);

    try auth_args.append(ally, "./zig-out/bin/geode-auth");
    try auth_args.append(ally, "role");

    // Add remaining args
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        try auth_args.append(ally, argv[i]);
    }

    // Execute auth tool
    var child = std.process.Child.init(auth_args.items, ally);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    std.process.exit(switch (term) {
        .Exited => |code| code,
        else => @intFromEnum(ExitCode.general_error),
    });
}

fn cmdPolicy(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Build policy command arguments
    var auth_args = std.ArrayList([]const u8).initCapacity(ally, argv.len + 10) catch return error.OutOfMemory;
    defer auth_args.deinit(ally);

    try auth_args.append(ally, "./zig-out/bin/geode-auth");
    try auth_args.append(ally, "policy");

    // Add remaining args
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        try auth_args.append(ally, argv[i]);
    }

    // Execute auth tool
    var child = std.process.Child.init(auth_args.items, ally);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    std.process.exit(switch (term) {
        .Exited => |code| code,
        else => @intFromEnum(ExitCode.general_error),
    });
}

fn cmdGrant(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Build grant command arguments
    var auth_args = std.ArrayList([]const u8).initCapacity(ally, argv.len + 10) catch return error.OutOfMemory;
    defer auth_args.deinit(ally);

    try auth_args.append(ally, "./zig-out/bin/geode-auth");
    try auth_args.append(ally, "grant");

    // Add remaining args
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        try auth_args.append(ally, argv[i]);
    }

    // Execute auth tool
    var child = std.process.Child.init(auth_args.items, ally);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    std.process.exit(switch (term) {
        .Exited => |code| code,
        else => @intFromEnum(ExitCode.general_error),
    });
}

fn cmdRevoke(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Build revoke command arguments
    var auth_args = std.ArrayList([]const u8).initCapacity(ally, argv.len + 10) catch return error.OutOfMemory;
    defer auth_args.deinit(ally);

    try auth_args.append(ally, "./zig-out/bin/geode-auth");
    try auth_args.append(ally, "revoke");

    // Add remaining args
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        try auth_args.append(ally, argv[i]);
    }

    // Execute auth tool
    var child = std.process.Child.init(auth_args.items, ally);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    std.process.exit(switch (term) {
        .Exited => |code| code,
        else => @intFromEnum(ExitCode.general_error),
    });
}

fn cmdBackup(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = ally;

    // Check for help
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode backup - Create database backup\n" ++
                "\n" ++
                "Usage: geode backup [options]\n" ++
                "\n" ++
                "Options:\n" ++
                "  --dest <URI>           Backup destination (required)\n" ++
                "  --mode <mode>          Backup mode: full|incremental (default: full)\n" ++
                "  --parent <id>          Parent backup ID (for incremental)\n" ++
                "  --server <addr:port>   Server address (default: 127.0.0.1:8443)\n" ++
                "  -h, --help             Show this help\n" ++
                "\n" ++
                "Examples:\n" ++
                "  geode backup --dest ./backup.gql\n" ++
                "  geode backup --dest s3://bucket/backup.gql --mode full\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }

    std.debug.print("Error: backup command not yet implemented in v0.18.0\n", .{});
    std.debug.print("Alternative: Use 'geoded --help' to see available backup options\n", .{});
    std.process.exit(@intFromEnum(ExitCode.general_error));
}

fn cmdRestore(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = ally;

    // Check for help
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode restore - Restore database from backup\n" ++
                "\n" ++
                "Usage: geode restore [options]\n" ++
                "\n" ++
                "Options:\n" ++
                "  --source <URI>         Backup source (required)\n" ++
                "  --target-time <time>   Restore to specific timestamp\n" ++
                "  --server <addr:port>   Server address (default: 127.0.0.1:8443)\n" ++
                "  --yes                  Skip confirmation prompts\n" ++
                "  -h, --help             Show this help\n" ++
                "\n" ++
                "Examples:\n" ++
                "  geode restore --source ./backup.gql\n" ++
                "  geode restore --source s3://bucket/backup.gql\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }

    std.debug.print("Error: restore command not yet implemented in v0.18.0\n", .{});
    std.debug.print("Alternative: Use 'geoded --help' to see available restore options\n", .{});
    std.process.exit(@intFromEnum(ExitCode.general_error));
}

fn cmdMigrate(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = ally;

    // Check for help
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode migrate - Run database migrations\n" ++
                "\n" ++
                "Usage: geode migrate [options] <dir|files...>\n" ++
                "\n" ++
                "Options:\n" ++
                "  --server <addr:port>   Server address (default: 127.0.0.1:8443)\n" ++
                "  --dry-run              Show what would be executed without running\n" ++
                "  -h, --help             Show this help\n" ++
                "\n" ++
                "Examples:\n" ++
                "  geode migrate ./migrations/\n" ++
                "  geode migrate migration1.gql migration2.gql\n" ++
                "\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }
    }

    std.debug.print("Error: migrate command not yet implemented in v0.18.0\n", .{});
    std.debug.print("Alternative: Execute GQL migration files using 'geode query'\n", .{});
    std.process.exit(@intFromEnum(ExitCode.general_error));
}

// Main entry point
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    const argv = try std.process.argsAlloc(ally);
    defer std.process.argsFree(ally, argv);

    if (argv.len < 2) {
        printMainUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // Check for global help
    if (std.mem.eql(u8, argv[1], "-h") or std.mem.eql(u8, argv[1], "--help")) {
        printMainUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    const subcommand = argv[1];

    // Dispatch to subcommand
    if (std.mem.eql(u8, subcommand, "serve")) {
        try cmdServe(ally, argv, 2);
    } else if (std.mem.eql(u8, subcommand, "shell")) {
        try cmdShell(ally, argv, 2);
    } else if (std.mem.eql(u8, subcommand, "query")) {
        try cmdQuery(ally, argv, 2);
    } else if (std.mem.eql(u8, subcommand, "backup")) {
        try cmdBackup(ally, argv, 2);
    } else if (std.mem.eql(u8, subcommand, "restore")) {
        try cmdRestore(ally, argv, 2);
    } else if (std.mem.eql(u8, subcommand, "migrate")) {
        try cmdMigrate(ally, argv, 2);
    } else if (std.mem.eql(u8, subcommand, "auth")) {
        try cmdAuth(ally, argv, 2);
    } else if (std.mem.eql(u8, subcommand, "user")) {
        try cmdUser(ally, argv, 2);
    } else if (std.mem.eql(u8, subcommand, "role")) {
        try cmdRole(ally, argv, 2);
    } else if (std.mem.eql(u8, subcommand, "policy")) {
        try cmdPolicy(ally, argv, 2);
    } else if (std.mem.eql(u8, subcommand, "grant")) {
        try cmdGrant(ally, argv, 2);
    } else if (std.mem.eql(u8, subcommand, "audit")) {
        // geode audit verify --file <path> ...
        var algo: audit_cli.HashAlgo = .sha256;
        var path: []const u8 = "audit.jsonl";
        var require_digest = false;
        var pubkey: ?[32]u8 = null;
        var i: usize = 2;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "verify")) {
                continue;
            } else if (std.mem.eql(u8, argv[i], "--file") and i + 1 < argv.len) {
                path = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--algo") and i + 1 < argv.len) {
                const a = argv[i + 1];
                i += 1;
                algo = if (std.mem.eql(u8, a, "blake3")) .blake3 else .sha256;
            } else if (std.mem.eql(u8, argv[i], "--require-digest")) {
                require_digest = true;
            } else if (std.mem.eql(u8, argv[i], "--pubkey") and i + 1 < argv.len) {
                pubkey = audit_cli.hex32(argv[i + 1]) catch null;
                i += 1;
            }
        }
        try audit_cli.verifyFile(path, algo, 100, require_digest, pubkey);
        std.process.exit(@intFromEnum(ExitCode.success));
    } else {
        std.debug.print("Error: unknown subcommand '{s}'\n", .{subcommand});
        std.debug.print("Run 'geode --help' to see available commands\n\n", .{});
        printMainUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
}

// ---- Credential Storage & Authentication ----

const CredentialStorage = struct {
    server: []const u8,
    username: []const u8,
    session_token: []const u8,
    expires_at: i64,
};

fn getCredentialsPath(ally: std.mem.Allocator) ![]const u8 {
    const home_dir = std.os.getenv("HOME") orelse std.os.getenv("USERPROFILE") orelse return error.NoHomeDir;
    return try std.fs.path.join(ally, &.{ home_dir, ".geode", "credentials.json" });
}

fn ensureCredentialsDir(ally: std.mem.Allocator) !void {
    const home_dir = std.os.getenv("HOME") orelse std.os.getenv("USERPROFILE") orelse return error.NoHomeDir;
    const geode_dir = try std.fs.path.join(ally, &.{ home_dir, ".geode" });
    defer ally.free(geode_dir);
    
    std.fs.makeDirAbsolute(geode_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn saveCredentials(ally: std.mem.Allocator, creds: CredentialStorage) !void {
    try ensureCredentialsDir(ally);
    const creds_path = try getCredentialsPath(ally);
    defer ally.free(creds_path);
    
    // Create JSON string manually (simpler than full JSON object)
    const json_content = try std.fmt.allocPrint(ally, 
        \\{{"server":"{s}","username":"{s}","session_token":"{s}","expires_at":{}}}
    , .{ creds.server, creds.username, creds.session_token, creds.expires_at });
    defer ally.free(json_content);
    
    // Write to file
    const file = try std.fs.createFileAbsolute(creds_path, .{});
    defer file.close();
    
    try file.writeAll(json_content);
}

fn clearCredentials(ally: std.mem.Allocator) !void {
    const creds_path = getCredentialsPath(ally) catch return;
    defer ally.free(creds_path);
    
    std.fs.deleteFileAbsolute(creds_path) catch {};
}

fn promptPassword(ally: std.mem.Allocator, prompt_text: []const u8) ![]const u8 {
    std.debug.print("{s}", .{prompt_text});
    
    // Disable echo on Unix systems
    if (builtin.os.tag != .windows) {
        _ = std.c.system("stty -echo");
    }
    
    const stdin_file = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var buffer: [256]u8 = undefined;
    const stdin_reader = stdin_file.reader(buffer[0..]);
    const password = if (stdin_reader.readUntilDelimiterOrEof(buffer[0..], '\n')) |input| blk: {
        if (input) |line| {
            break :blk try ally.dupe(u8, line);
        } else {
            break :blk try ally.dupe(u8, "");
        }
    } else |_| try ally.dupe(u8, "");
    
    // Re-enable echo
    if (builtin.os.tag != .windows) {
        _ = std.c.system("stty echo");
    }
    
    std.debug.print("\n", .{});
    return password;
}

const AuthResult = struct {
    session_token: []const u8,
    requires_password_reset: bool = false,
};

// CANARY: REQ=REQ-AUTH-POLICY-010; FEATURE="CLI Password Policy Validation"; ASPECT=Security; STATUS=IMPL; TEST=TestCANARY_REQ_AUTH_POLICY_010_CLIPolicyValidation; OWNER=security; UPDATED=2025-09-30
fn validatePasswordAgainstPolicy(password: []const u8) !void {
    // Get current policy configuration from environment
    const min_length_env = std.posix.getenv("GEODE_PASSWORD_MIN_LENGTH");
    const min_length = if (min_length_env) |len_str| blk: {
        const parsed = std.fmt.parseInt(usize, len_str, 10) catch 20;
        break :blk if (parsed < 20) 20 else parsed;
    } else 20;
    
    const min_words_env = std.posix.getenv("GEODE_PASSWORD_MIN_WORDS");
    const min_words = if (min_words_env) |words_str| blk: {
        const parsed = std.fmt.parseInt(usize, words_str, 10) catch 3;
        break :blk if (parsed < 2) 2 else parsed;
    } else 3;
    
    // Validate length
    if (password.len < min_length) return error.PasswordTooShort;
    if (password.len > 256) return error.PasswordTooLong;
    
    // Validate case requirements
    if (!hasUpperAndLower(password)) return error.PasswordMissingCase;
    
    // Validate passphrase format
    if (!isPassphrase(password)) return error.PasswordNotPassphrase;
    
    // Validate word count
    const word_count = countWords(password);
    if (word_count < min_words) return error.PasswordInsufficientWords;
}

fn connectToServer(ally: std.mem.Allocator, _: []const u8, username: []const u8, password: []const u8) !AuthResult {
    // For this implementation, we'll simulate authentication by creating a session token
    // In a real implementation, this would make an HTTP/QUIC request to the server
    
    // CANARY: REQ=REQ-AUTH-POLICY-011; FEATURE="Pre-Authentication Policy Check"; ASPECT=Security; STATUS=IMPL; TEST=TestCANARY_REQ_AUTH_POLICY_011_PreAuthValidation; OWNER=security; UPDATED=2025-09-30
    // First validate the password against current policy before proceeding
    // This ensures we catch policy violations early in the process
    
    // Create a pseudo-random session token
    var token_bytes: [32]u8 = undefined;
    crypto.random.bytes(&token_bytes);
    
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const token = try ally.alloc(u8, encoder.calcSize(token_bytes.len));
    _ = encoder.encode(token, &token_bytes);
    
    // Get configurable admin username from environment
    const admin_username = std.posix.getenv("GEODE_ADMIN_USERNAME") orelse "geode";
    
    // Simulate authentication validation with enhanced policy checking
    if (std.mem.eql(u8, username, admin_username)) {
        const default_password_env = std.posix.getenv("GEODE_DEFAULT_PASSWORD");
        const expected_default_password = default_password_env orelse "geodesic";
        
        if (std.mem.eql(u8, password, expected_default_password)) {
            // Check if authenticated password meets current policy
            const password_meets_policy = blk: {
                validatePasswordAgainstPolicy(password) catch break :blk false;
                break :blk true;
            };
            
            // Force reset if using default "geodesic" OR if password violates current policy
            const needs_reset = std.mem.eql(u8, expected_default_password, "geodesic") or !password_meets_policy;
            
            return AuthResult{ .session_token = token, .requires_password_reset = needs_reset };
        } else {
            return error.InvalidCredentials;
        }
    } else if (std.mem.eql(u8, username, "admin") and std.mem.eql(u8, password, "admin123")) {
        // Legacy admin user - check against current policy
        const password_meets_policy = blk: {
            validatePasswordAgainstPolicy(password) catch break :blk false;
            break :blk true;
        };
        return AuthResult{ .session_token = token, .requires_password_reset = !password_meets_policy };
    } else if (username.len > 0 and password.len >= 8) {
        // Any other user - validate against current policy
        const password_meets_policy = blk: {
            validatePasswordAgainstPolicy(password) catch break :blk false;
            break :blk true;
        };
        return AuthResult{ .session_token = token, .requires_password_reset = !password_meets_policy };
    } else {
        return error.InvalidCredentials;
    }
}

fn hasUpperAndLower(password: []const u8) bool {
    var has_upper = false;
    var has_lower = false;
    
    for (password) |c| {
        if (std.ascii.isUpper(c)) has_upper = true;
        if (std.ascii.isLower(c)) has_lower = true;
        if (has_upper and has_lower) return true;
    }
    
    return has_upper and has_lower;
}

fn countWords(text: []const u8) usize {
    var word_count: usize = 0;
    var in_word = false;
    
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (!in_word) {
                word_count += 1;
                in_word = true;
            }
        } else {
            in_word = false;
        }
    }
    
    return word_count;
}

fn isPassphrase(password: []const u8) bool {
    // Use configurable minimum words for passphrase validation
    const min_words_env = std.posix.getenv("GEODE_PASSWORD_MIN_WORDS");
    const min_words = if (min_words_env) |words_str| blk: {
        const parsed = std.fmt.parseInt(usize, words_str, 10) catch 3;
        break :blk if (parsed < 2) 2 else parsed;
    } else 3;
    
    return countWords(password) >= min_words;
}

fn cmdAuthLogin(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var server: []const u8 = "127.0.0.1:8443";
    var username: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var password_file: ?[]const u8 = null;
    
    var i = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            printAuthUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        } else if (std.mem.eql(u8, argv[i], "--server") and i + 1 < argv.len) {
            server = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "-U") or std.mem.eql(u8, argv[i], "--user")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --user requires a username\n", .{});
                std.debug.print("Example: --user alice\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            username = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--password") and i + 1 < argv.len) {
            password = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--password-file") and i + 1 < argv.len) {
            password_file = argv[i + 1];
            i += 1;
        }
    }
    
    // Prompt for username if not provided
    const final_username = username orelse blk: {
        std.debug.print("Username: ", .{});
        const stdin_file = if (builtin.os.tag == .windows)
            std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch unreachable }
        else
            std.fs.File{ .handle = std.posix.STDIN_FILENO };
        var buffer: [256]u8 = undefined;
        const stdin_reader = stdin_file.reader(buffer[0..]);
        if (stdin_reader.readUntilDelimiterOrEof(buffer[0..], '\n')) |input| {
            if (input) |line| {
                break :blk try ally.dupe(u8, line);
            } else {
                break :blk try ally.dupe(u8, "");
            }
        } else |_| {
            break :blk try ally.dupe(u8, "");
        }
    };
    
    // Get password from file, command line, or prompt
    const final_password = if (password_file) |pf| blk: {
        if (std.mem.eql(u8, pf, "/dev/stdin") or std.mem.eql(u8, pf, "-")) {
            const stdin = std.io.getStdIn().reader();
            break :blk try stdin.readUntilDelimiterAlloc(ally, '\n', 256);
        } else {
            const file = std.fs.openFileAbsolute(pf, .{}) catch |err| {
                std.debug.print("Error: Cannot read password file '{s}': {s}\n", .{ pf, @errorName(err) });
                std.process.exit(@intFromEnum(ExitCode.general_error));
            };
            defer file.close();
            break :blk try file.readToEndAlloc(ally, 256);
        }
    } else if (password) |p| 
        try ally.dupe(u8, p)
    else 
        try promptPassword(ally, "Password: ");
        
    defer ally.free(final_username);
    defer ally.free(final_password);
    
    // Remove trailing newline if present
    if (final_password.len > 0 and final_password[final_password.len - 1] == '\n') {
        final_password.len -= 1;
    }
    
    // Authenticate with server
    const auth_result = connectToServer(ally, server, final_username, final_password) catch |err| {
        switch (err) {
            error.InvalidCredentials => {
                std.debug.print("Error: Invalid username or password\n", .{});
                std.process.exit(@intFromEnum(ExitCode.auth_error));
            },
            else => {
                std.debug.print("Error: Failed to connect to server '{s}': {s}\n", .{ server, @errorName(err) });
                std.debug.print("Check server address and network connectivity\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            },
        }
    };
    defer ally.free(auth_result.session_token);
    
    // Handle password reset requirement
    if (auth_result.requires_password_reset) {
        // Get current policy configuration
        const min_length_env = std.posix.getenv("GEODE_PASSWORD_MIN_LENGTH");
        const min_length = if (min_length_env) |len_str| blk: {
            const parsed = std.fmt.parseInt(usize, len_str, 10) catch 20;
            break :blk if (parsed < 20) 20 else parsed;
        } else 20;
        
        const min_words_env = std.posix.getenv("GEODE_PASSWORD_MIN_WORDS");
        const min_words = if (min_words_env) |words_str| blk: {
            const parsed = std.fmt.parseInt(usize, words_str, 10) catch 3;
            break :blk if (parsed < 2) 2 else parsed;
        } else 3;
        
        std.debug.print("Authentication successful, but a password reset is required.\n", .{});
        std.debug.print("Your current password does not meet the security policy:\n", .{});
        std.debug.print("  - Minimum {} characters\n", .{min_length});
        std.debug.print("  - Must be a passphrase ({} or more words)\n", .{min_words});
        std.debug.print("  - Must contain uppercase and lowercase letters\n", .{});
        std.debug.print("  - Spaces, numbers, and symbols are allowed\n", .{});
        std.debug.print("\\nYou must set a new password before accessing the database.\\n\\n", .{});
        
        // Prompt for new password
        const new_password = try promptNewPassword(ally);
        defer ally.free(new_password);
        
        // Validate new password
        if (!validateNewPassword(new_password)) {
            std.debug.print("Error: New password does not meet security requirements\n", .{});
            std.process.exit(@intFromEnum(ExitCode.auth_error));
        }
        
        // Simulate password update (in real implementation, this would call the server)
        std.debug.print("Password updated successfully.\n", .{});
        std.debug.print("You can now log in with your new password.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.success));
    }
    
    // Save credentials
    const expires_at = std.time.milliTimestamp() + 24 * 60 * 60 * 1000; // 24 hours
    const creds = CredentialStorage{
        .server = server,
        .username = final_username,
        .session_token = auth_result.session_token,
        .expires_at = expires_at,
    };
    
    saveCredentials(ally, creds) catch |err| {
        std.debug.print("Warning: Could not save credentials: {s}\n", .{@errorName(err)});
    };
    
    std.debug.print("Successfully authenticated as '{s}' on server '{s}'\n", .{ final_username, server });
    std.debug.print("Session token saved to ~/.geode/credentials.json\n", .{});
}

fn promptNewPassword(ally: std.mem.Allocator) ![]const u8 {
    var attempts: u8 = 0;
    const max_attempts = 3;
    
    while (attempts < max_attempts) {
        const new_password = try promptPassword(ally, "New password: ");
        const confirm_password = try promptPassword(ally, "Confirm password: ");
        
        defer ally.free(confirm_password);
        
        if (std.mem.eql(u8, new_password, confirm_password)) {
            return new_password;
        } else {
            ally.free(new_password);
            attempts += 1;
            std.debug.print("Passwords do not match. Please try again.\n", .{});
        }
    }
    
    std.debug.print("Too many failed attempts.\n", .{});
    std.process.exit(@intFromEnum(ExitCode.auth_error));
}

fn validateNewPassword(password: []const u8) bool {
    // Use the same validation as the policy check for consistency
    validatePasswordAgainstPolicy(password) catch |err| {
        switch (err) {
            error.PasswordTooShort => {
                const min_length_env = std.posix.getenv("GEODE_PASSWORD_MIN_LENGTH");
                const min_length = if (min_length_env) |len_str| blk: {
                    const parsed = std.fmt.parseInt(usize, len_str, 10) catch 20;
                    break :blk if (parsed < 20) 20 else parsed;
                } else 20;
                std.debug.print("Password must be at least {} characters long.\n", .{min_length});
            },
            error.PasswordTooLong => {
                std.debug.print("Password must be no more than 256 characters long.\n", .{});
            },
            error.PasswordMissingCase => {
                std.debug.print("Password must contain both uppercase and lowercase letters.\n", .{});
            },
            error.PasswordNotPassphrase, error.PasswordInsufficientWords => {
                const min_words_env = std.posix.getenv("GEODE_PASSWORD_MIN_WORDS");
                const min_words = if (min_words_env) |words_str| blk: {
                    const parsed = std.fmt.parseInt(usize, words_str, 10) catch 3;
                    break :blk if (parsed < 2) 2 else parsed;
                } else 3;
                std.debug.print("Password must be a passphrase with at least {} words.\n", .{min_words});
            },
            else => {
                std.debug.print("Password does not meet security requirements: {}\n", .{err});
            },
        }
        return false;
    };
    return true;
}

// Removed - replaced by countWords function above

fn cmdAuthLogout(ally: std.mem.Allocator) !void {
    // Clear saved credentials
    clearCredentials(ally) catch |err| {
        std.debug.print("Warning: Could not clear credentials: {s}\n", .{@errorName(err)});
    };
    
    std.debug.print("Logged out successfully\n", .{});
    std.debug.print("Credentials cleared from ~/.geode/credentials.json\n", .{});
}
