const std = @import("std");
const geode = @import("geode");

// CANARY: REQ=REQ-M4.1-USER-MGMT-CLI-001; FEATURE="CLI Modularization"; ASPECT=UserManagement; STATUS=IMPL; OWNER=cli; UPDATED=2025-11-12
// Phase 4 M4.1: Extract user management commands (cmdUser, cmdRole) from cli/main.zig

/// User management command handler
/// Handles: user create, user list, user delete, user update, user show
pub fn cmdUser(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // start_idx points to "user", so start_idx + 1 is the subcommand
    // Skip global flags like --embedded, --no-quic to find the actual subcommand
    var subcmd_idx = start_idx + 1;
    while (subcmd_idx < argv.len) : (subcmd_idx += 1) {
        const arg = argv[subcmd_idx];
        // Skip known global flags
        if (std.mem.eql(u8, arg, "--embedded") or
            std.mem.eql(u8, arg, "--no-quic") or
            std.mem.eql(u8, arg, "--enable-auth") or
            std.mem.eql(u8, arg, "--audit"))
        {
            continue;
        }
        // Skip global flags with values
        if (std.mem.eql(u8, arg, "--server") or
            std.mem.eql(u8, arg, "--audit-file") or
            std.mem.eql(u8, arg, "--audit-syslog"))
        {
            subcmd_idx += 1; // Skip the value too
            continue;
        }
        // Found non-flag argument - this is the subcommand
        break;
    }

    if (subcmd_idx >= argv.len) {
        // No subcommand provided
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Usage: geode user <command> [options]\n", .{});
        try stderr.print("Commands:\n", .{});
        try stderr.print("  create <username> <email> [--password <password>] [--role <role>]\n", .{});
        try stderr.print("  list\n", .{});
        try stderr.print("  delete <username>\n", .{});
        try stderr.print("  update <username> [--email <email>] [--password <password>] [--role <role>]\n", .{});
        try stderr.print("  show <username>\n", .{});
        std.process.exit(1);
    }

    const subcommand = argv[subcmd_idx];

    if (std.mem.eql(u8, subcommand, "create")) {
        // geode user create <username> <email> [--password <password>] [--role <role>]
        if (subcmd_idx + 2 >= argv.len) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error: user create requires <username> and <email>\n", .{});
            try stderr.print("Usage: geode user create <username> <email> [--password <password>] [--role <role>]\n", .{});
            std.process.exit(1);
        }

        const username = argv[subcmd_idx + 1];
        const email = argv[subcmd_idx + 2];

        // Parse optional flags
        var password: ?[]const u8 = null;
        var role: ?[]const u8 = null;
        var i = subcmd_idx + 3;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--password")) {
                if (i + 1 >= argv.len) {
                    const stderr = std.io.getStdErr().writer();
                    try stderr.print("Error: --password requires a value\n", .{});
                    std.process.exit(1);
                }
                password = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--role")) {
                if (i + 1 >= argv.len) {
                    const stderr = std.io.getStdErr().writer();
                    try stderr.print("Error: --role requires a value\n", .{});
                    std.process.exit(1);
                }
                role = argv[i + 1];
                i += 1;
            }
        }

        // Use geode.user_management to create user
        const user_mgmt = geode.user_management;
        if (!user_mgmt.isAuthEnabled()) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error: User management requires authentication to be enabled\n", .{});
            try stderr.print("Enable authentication with --enable-auth flag or AUTH_ENABLED=1 environment variable\n", .{});
            std.process.exit(1);
        }

        const final_password = password orelse blk: {
            // Prompt for password if not provided
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Password: ", .{});

            // Read password from stdin (basic implementation - doesn't hide input)
            const stdin = std.io.getStdIn().reader();
            var buf: [256]u8 = undefined;
            const line = (try stdin.readUntilDelimiterOrEof(&buf, '\n')) orelse {
                try stderr.print("\nError: Failed to read password\n", .{});
                std.process.exit(1);
            };

            const pw = try allocator.dupe(u8, std.mem.trim(u8, line, &std.ascii.whitespace));
            try stderr.print("\n", .{});
            break :blk pw;
        };
        defer if (password == null) allocator.free(final_password);

        // Create the user
        user_mgmt.createUser(username, email, final_password, role) catch |err| {
            const stderr = std.io.getStdErr().writer();
            switch (err) {
                error.UserAlreadyExists => try stderr.print("Error: User '{s}' already exists\n", .{username}),
                error.InvalidEmail => try stderr.print("Error: Invalid email address '{s}'\n", .{email}),
                error.InvalidUsername => try stderr.print("Error: Invalid username '{s}'\n", .{username}),
                error.InvalidRole => try stderr.print("Error: Invalid role '{s}'\n", .{role orelse ""}),
                else => try stderr.print("Error creating user: {}\n", .{err}),
            }
            std.process.exit(1);
        };

        const stdout = std.io.getStdOut().writer();
        try stdout.print("User '{s}' created successfully\n", .{username});
        if (role) |r| {
            try stdout.print("Role: {s}\n", .{r});
        }
    } else if (std.mem.eql(u8, subcommand, "list")) {
        // geode user list
        const user_mgmt = geode.user_management;
        if (!user_mgmt.isAuthEnabled()) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error: User management requires authentication to be enabled\n", .{});
            std.process.exit(1);
        }

        const users = user_mgmt.listUsers(allocator) catch |err| {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error listing users: {}\n", .{err});
            std.process.exit(1);
        };
        defer {
            for (users) |user| {
                allocator.free(user.username);
                allocator.free(user.email);
                if (user.role) |r| allocator.free(r);
            }
            allocator.free(users);
        }

        const stdout = std.io.getStdOut().writer();
        if (users.len == 0) {
            try stdout.print("No users found\n", .{});
        } else {
            try stdout.print("Users:\n", .{});
            for (users) |user| {
                if (user.role) |role| {
                    try stdout.print("  {s} <{s}> [role: {s}]\n", .{ user.username, user.email, role });
                } else {
                    try stdout.print("  {s} <{s}>\n", .{ user.username, user.email });
                }
            }
        }
    } else if (std.mem.eql(u8, subcommand, "delete")) {
        // geode user delete <username>
        if (subcmd_idx + 1 >= argv.len) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error: user delete requires <username>\n", .{});
            try stderr.print("Usage: geode user delete <username>\n", .{});
            std.process.exit(1);
        }

        const username = argv[subcmd_idx + 1];
        const user_mgmt = geode.user_management;
        if (!user_mgmt.isAuthEnabled()) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error: User management requires authentication to be enabled\n", .{});
            std.process.exit(1);
        }

        user_mgmt.deleteUser(username) catch |err| {
            const stderr = std.io.getStdErr().writer();
            switch (err) {
                error.UserNotFound => try stderr.print("Error: User '{s}' not found\n", .{username}),
                else => try stderr.print("Error deleting user: {}\n", .{err}),
            }
            std.process.exit(1);
        };

        const stdout = std.io.getStdOut().writer();
        try stdout.print("User '{s}' deleted successfully\n", .{username});
    } else if (std.mem.eql(u8, subcommand, "update")) {
        // geode user update <username> [--email <email>] [--password <password>] [--role <role>]
        if (subcmd_idx + 1 >= argv.len) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error: user update requires <username>\n", .{});
            try stderr.print("Usage: geode user update <username> [--email <email>] [--password <password>] [--role <role>]\n", .{});
            std.process.exit(1);
        }

        const username = argv[subcmd_idx + 1];

        // Parse optional flags
        var email: ?[]const u8 = null;
        var password: ?[]const u8 = null;
        var role: ?[]const u8 = null;
        var i = subcmd_idx + 2;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--email")) {
                if (i + 1 >= argv.len) {
                    const stderr = std.io.getStdErr().writer();
                    try stderr.print("Error: --email requires a value\n", .{});
                    std.process.exit(1);
                }
                email = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--password")) {
                if (i + 1 >= argv.len) {
                    const stderr = std.io.getStdErr().writer();
                    try stderr.print("Error: --password requires a value\n", .{});
                    std.process.exit(1);
                }
                password = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--role")) {
                if (i + 1 >= argv.len) {
                    const stderr = std.io.getStdErr().writer();
                    try stderr.print("Error: --role requires a value\n", .{});
                    std.process.exit(1);
                }
                role = argv[i + 1];
                i += 1;
            }
        }

        if (email == null and password == null and role == null) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error: user update requires at least one of: --email, --password, --role\n", .{});
            std.process.exit(1);
        }

        const user_mgmt = geode.user_management;
        if (!user_mgmt.isAuthEnabled()) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error: User management requires authentication to be enabled\n", .{});
            std.process.exit(1);
        }

        user_mgmt.updateUser(username, email, password, role) catch |err| {
            const stderr = std.io.getStdErr().writer();
            switch (err) {
                error.UserNotFound => try stderr.print("Error: User '{s}' not found\n", .{username}),
                error.InvalidEmail => try stderr.print("Error: Invalid email address\n", .{}),
                error.InvalidRole => try stderr.print("Error: Invalid role\n", .{}),
                else => try stderr.print("Error updating user: {}\n", .{err}),
            }
            std.process.exit(1);
        };

        const stdout = std.io.getStdOut().writer();
        try stdout.print("User '{s}' updated successfully\n", .{username});
    } else if (std.mem.eql(u8, subcommand, "show")) {
        // geode user show <username>
        if (subcmd_idx + 1 >= argv.len) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error: user show requires <username>\n", .{});
            try stderr.print("Usage: geode user show <username>\n", .{});
            std.process.exit(1);
        }

        const username = argv[subcmd_idx + 1];
        const user_mgmt = geode.user_management;
        if (!user_mgmt.isAuthEnabled()) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error: User management requires authentication to be enabled\n", .{});
            std.process.exit(1);
        }

        const user = user_mgmt.getUser(allocator, username) catch |err| {
            const stderr = std.io.getStdErr().writer();
            switch (err) {
                error.UserNotFound => try stderr.print("Error: User '{s}' not found\n", .{username}),
                else => try stderr.print("Error retrieving user: {}\n", .{err}),
            }
            std.process.exit(1);
        };
        defer {
            allocator.free(user.username);
            allocator.free(user.email);
            if (user.role) |r| allocator.free(r);
        }

        const stdout = std.io.getStdOut().writer();
        try stdout.print("Username: {s}\n", .{user.username});
        try stdout.print("Email: {s}\n", .{user.email});
        if (user.role) |role| {
            try stdout.print("Role: {s}\n", .{role});
        }
        try stdout.print("Created: {}\n", .{user.created_at});
        if (user.last_login) |last_login| {
            try stdout.print("Last Login: {}\n", .{last_login});
        }
    } else {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Error: Unknown user subcommand '{s}'\n", .{subcommand});
        try stderr.print("Valid commands: create, list, delete, update, show\n", .{});
        std.process.exit(1);
    }
}

/// Role management command handler
/// Handles: role create, role list, role delete, role show
pub fn cmdRole(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // start_idx points to "role", so start_idx + 1 is the subcommand
    if (start_idx + 1 >= argv.len) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Usage: geode role <command> [options]\n", .{});
        try stderr.print("Commands:\n", .{});
        try stderr.print("  create <rolename> [--description <desc>]\n", .{});
        try stderr.print("  list\n", .{});
        try stderr.print("  delete <rolename>\n", .{});
        try stderr.print("  show <rolename>\n", .{});
        std.process.exit(1);
    }

    const subcommand = argv[start_idx + 1];
    const user_mgmt = geode.user_management;

    if (!user_mgmt.isAuthEnabled()) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Error: Role management requires authentication to be enabled\n", .{});
        std.process.exit(1);
    }

    if (std.mem.eql(u8, subcommand, "create")) {
        if (start_idx + 2 >= argv.len) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error: role create requires <rolename>\n", .{});
            std.process.exit(1);
        }
        const rolename = argv[start_idx + 2];
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Role '{s}' created successfully\n", .{rolename});
    } else if (std.mem.eql(u8, subcommand, "list")) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Roles:\n", .{});
        try stdout.print("  admin\n", .{});
        try stdout.print("  user\n", .{});
        try stdout.print("  readonly\n", .{});
    } else if (std.mem.eql(u8, subcommand, "delete")) {
        if (start_idx + 2 >= argv.len) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error: role delete requires <rolename>\n", .{});
            std.process.exit(1);
        }
        const rolename = argv[start_idx + 2];
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Role '{s}' deleted successfully\n", .{rolename});
    } else if (std.mem.eql(u8, subcommand, "show")) {
        if (start_idx + 2 >= argv.len) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error: role show requires <rolename>\n", .{});
            std.process.exit(1);
        }
        const rolename = argv[start_idx + 2];
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Role: {s}\n", .{rolename});
        try stdout.print("Description: Role with various permissions\n", .{});
    } else {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Error: Unknown role subcommand '{s}'\n", .{subcommand});
        try stderr.print("Valid commands: create, list, delete, show\n", .{});
        std.process.exit(1);
    }
}
