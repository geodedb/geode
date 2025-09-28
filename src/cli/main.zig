const std = @import("std");
const builtin = @import("builtin");

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

    try server_args.append(ally, "geoded");

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

    const term = try child.spawnAndWait();
    std.process.exit(switch (term) {
        .Exited => |code| code,
        else => @intFromEnum(ExitCode.general_error),
    });
}

fn cmdQuery(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Check for help
    if (start_idx >= argv.len) {
        std.debug.print("Error: query text required\n", .{});
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
    _ = ally;
    _ = argv;
    _ = start_idx;
    std.debug.print("Error: shell command not yet implemented\n", .{});
    std.process.exit(@intFromEnum(ExitCode.general_error));
}

fn cmdAuth(ally: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = ally;

    if (start_idx >= argv.len) {
        printAuthUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    const subcmd = argv[start_idx];

    if (std.mem.eql(u8, subcmd, "login")) {
        std.debug.print("Mock auth login - would connect to server and authenticate\n", .{});
        std.debug.print("Successfully authenticated (mock)\n", .{});
    } else if (std.mem.eql(u8, subcmd, "logout")) {
        std.debug.print("Logged out successfully (mock)\n", .{});
    } else if (std.mem.eql(u8, subcmd, "-h") or std.mem.eql(u8, subcmd, "--help")) {
        printAuthUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    } else {
        std.debug.print("Error: unknown auth command '{s}'\n", .{subcmd});
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

    std.debug.print("Error: backup command not yet implemented\n", .{});
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

    std.debug.print("Error: restore command not yet implemented\n", .{});
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

    std.debug.print("Error: migrate command not yet implemented\n", .{});
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
    } else if (std.mem.eql(u8, subcommand, "revoke")) {
        try cmdRevoke(ally, argv, 2);
    } else {
        std.debug.print("Error: unknown subcommand '{s}'\n\n", .{subcommand});
        printMainUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
}
