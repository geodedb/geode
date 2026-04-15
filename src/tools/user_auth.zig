const std = @import("std");
const auth = @import("geode_auth");
const rls = @import("rls");
const user_manager = @import("user_manager");
const user_storage = @import("user_storage");
const graph_store = @import("geode").graph_store;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    // Initialize managers
    var security_manager = try auth.SecurityManager.init(allocator);
    defer security_manager.deinit();

    var rls_engine = try rls.RLSEngine.init(allocator);
    defer rls_engine.deinit();

    const store = graph_store.getGlobalStore(allocator);
    // Create user storage backend using GraphStore persistence
    var user_storage_backend = try user_storage.UserStorageBackend.init(allocator, store);
    defer user_storage_backend.deinit();

    var mgr = try user_manager.UserManager.init(
        allocator,
        &security_manager,
        &rls_engine,
        &user_storage_backend,
    );
    defer mgr.deinit();

    // Handle commands
    if (std.mem.eql(u8, command, "user")) {
        try handleUserCommand(&mgr, args[2..]);
    } else if (std.mem.eql(u8, command, "role")) {
        try handleRoleCommand(&mgr, args[2..]);
    } else if (std.mem.eql(u8, command, "policy")) {
        try handlePolicyCommand(&mgr, args[2..]);
    } else if (std.mem.eql(u8, command, "grant")) {
        try handleGrantCommand(&mgr, args[2..]);
    } else if (std.mem.eql(u8, command, "revoke")) {
        try handleRevokeCommand(&mgr, args[2..]);
    } else {
        try printUsage();
    }
}

fn printUsage() !void {
    std.debug.print(
        \\geode-auth - User and permission management for Geode database
        \\
        \\Usage: geode-auth <command> [options]
        \\
        \\Commands:
        \\  user     Manage users
        \\  role     Manage roles
        \\  policy   Manage RLS policies
        \\  grant    Grant permissions
        \\  revoke   Revoke permissions
        \\
        \\User Commands:
        \\  user create <username> <email> <password>     Create a new user
        \\  user delete <username>                        Delete a user
        \\  user list                                      List all users
        \\  user show <username>                          Show user details
        \\  user enable <username>                        Enable a user
        \\  user disable <username>                       Disable a user
        \\  user password <username> <new_password>       Change password
        \\
        \\Role Commands:
        \\  role create <name> <description>              Create a new role
        \\  role delete <name>                            Delete a role
        \\  role list                                      List all roles
        \\  role show <name>                              Show role details
        \\
        \\Policy Commands:
        \\  policy create <name> <table> <operation>      Create RLS policy
        \\  policy delete <name>                          Delete a policy
        \\  policy list [table]                           List policies
        \\  policy enable <name>                          Enable a policy
        \\  policy disable <name>                         Disable a policy
        \\
        \\Grant/Revoke Commands:
        \\  grant role <role> to <user>                   Grant role to user
        \\  grant permission <permission> to <role>       Grant permission to role
        \\  revoke role <role> from <user>                Revoke role from user
        \\  revoke permission <permission> from <role>    Revoke permission from role
        \\
        \\Examples:
        \\  geode-auth user create alice alice@example.com SecurePass123!
        \\  geode-auth role create editor "Can edit content"
        \\  geode-auth grant role editor to alice
        \\  geode-auth policy create user_isolation users select
        \\
    , .{});
}

fn handleUserCommand(mgr: *user_manager.UserManager, args: []const [:0]const u8) !void {
    if (args.len < 1) {
        try printUserHelp();
        return;
    }

    const subcommand = args[0];
    // Use std.debug.print for CLI output

    if (std.mem.eql(u8, subcommand, "create")) {
        if (args.len < 4) {
            std.debug.print("Usage: user create <username> <email> <password>\n", .{});
            return;
        }

        const request = user_manager.UserManager.CreateUserRequest{
            .username = args[1],
            .email = args[2],
            .password = args[3],
            .roles = null,
            .attributes = null,
            .metadata = null,
        };

        const response = try mgr.createUser(request);
        std.debug.print("User created successfully:\n", .{});
        std.debug.print("  ID: {}\n", .{response.user_id});
        std.debug.print("  Username: {s}\n", .{response.username});
        std.debug.print("  Email: {s}\n", .{response.email});
        std.debug.print("  Roles: ", .{});
        for (response.roles) |role| {
            std.debug.print("{s} ", .{role});
        }
        std.debug.print("\n", .{});
    } else if (std.mem.eql(u8, subcommand, "delete")) {
        if (args.len < 2) {
            std.debug.print("Usage: user delete <username>\n", .{});
            return;
        }

        // Find user by username
        var user_id: ?auth.UserId = null;
        var it = mgr.security_manager.users.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, args[1])) {
                user_id = entry.key_ptr.*;
                break;
            }
        }

        if (user_id) |id| {
            try mgr.deleteUser(id);
            std.debug.print("User '{s}' deleted successfully\n", .{args[1]});
        } else {
            std.debug.print("User '{s}' not found\n", .{args[1]});
        }
    } else if (std.mem.eql(u8, subcommand, "list")) {
        const users = try mgr.listUsers(null);
        std.debug.print("Users ({} total):\n", .{users.len});
        std.debug.print("{s:<20} {s:<30} {s:<10} {s:<10}\n", .{ "Username", "Email", "Active", "Superuser" });
        std.debug.print("{s}\n", .{"-" ** 70});

        for (users) |user| {
            std.debug.print("{s:<20} {s:<30} {s:<10} {s:<10}\n", .{
                user.username,
                user.email,
                if (user.is_active) "Yes" else "No",
                if (user.is_superuser) "Yes" else "No",
            });
        }
    } else if (std.mem.eql(u8, subcommand, "show")) {
        if (args.len < 2) {
            std.debug.print("Usage: user show <username>\n", .{});
            return;
        }

        // Find user by username
        var user: ?auth.User = null;
        var it = mgr.security_manager.users.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, args[1])) {
                user = entry.value_ptr.*;
                break;
            }
        }

        if (user) |u| {
            std.debug.print("User Details:\n", .{});
            std.debug.print("  ID: {}\n", .{u.id});
            std.debug.print("  Username: {s}\n", .{u.username});
            std.debug.print("  Email: {s}\n", .{u.email});
            std.debug.print("  Active: {}\n", .{u.is_active});
            std.debug.print("  Superuser: {}\n", .{u.is_superuser});
            std.debug.print("  MFA Enabled: {}\n", .{u.mfa_enabled});
            std.debug.print("  Created: {}\n", .{u.created_at});
            std.debug.print("  Updated: {}\n", .{u.updated_at});
            if (u.last_login) |login| {
                std.debug.print("  Last Login: {}\n", .{login});
            }

            // Show roles
            std.debug.print("  Roles: ", .{});
            if (mgr.security_manager.rbac.user_roles.get(u.id)) |roles| {
                for (roles.items) |role_id| {
                    if (mgr.security_manager.roles.get(role_id)) |role| {
                        std.debug.print("{s} ", .{role.name});
                    }
                }
            }
            std.debug.print("\n", .{});

            // Show attributes
            if (u.attributes.count() > 0) {
                std.debug.print("  Attributes:\n", .{});
                var attr_it = u.attributes.iterator();
                while (attr_it.next()) |entry| {
                    std.debug.print("    {s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                }
            }
        } else {
            std.debug.print("User '{s}' not found\n", .{args[1]});
        }
    } else if (std.mem.eql(u8, subcommand, "enable")) {
        if (args.len < 2) {
            std.debug.print("Usage: user enable <username>\n", .{});
            return;
        }

        // Find and enable user
        var found = false;
        var it = mgr.security_manager.users.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, args[1])) {
                entry.value_ptr.is_active = true;
                entry.value_ptr.updated_at = std.time.milliTimestamp();
                found = true;
                break;
            }
        }

        if (found) {
            std.debug.print("User '{s}' enabled\n", .{args[1]});
        } else {
            std.debug.print("User '{s}' not found\n", .{args[1]});
        }
    } else if (std.mem.eql(u8, subcommand, "disable")) {
        if (args.len < 2) {
            std.debug.print("Usage: user disable <username>\n", .{});
            return;
        }

        // Find and disable user
        var found = false;
        var it = mgr.security_manager.users.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, args[1])) {
                entry.value_ptr.is_active = false;
                entry.value_ptr.updated_at = std.time.milliTimestamp();
                found = true;
                break;
            }
        }

        if (found) {
            std.debug.print("User '{s}' disabled\n", .{args[1]});
        } else {
            std.debug.print("User '{s}' not found\n", .{args[1]});
        }
    } else if (std.mem.eql(u8, subcommand, "password")) {
        if (args.len < 3) {
            std.debug.print("Usage: user password <username> <new_password>\n", .{});
            return;
        }

        // Find user and update password
        var user_id: ?auth.UserId = null;
        var it = mgr.security_manager.users.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, args[1])) {
                user_id = entry.key_ptr.*;
                break;
            }
        }

        if (user_id) |id| {
            const request = user_manager.UserManager.UpdateUserRequest{
                .user_id = id,
                .password = args[2],
            };
            try mgr.updateUser(request);
            std.debug.print("Password updated for user '{s}'\n", .{args[1]});
        } else {
            std.debug.print("User '{s}' not found\n", .{args[1]});
        }
    } else {
        try printUserHelp();
    }
}

fn handleRoleCommand(mgr: *user_manager.UserManager, args: []const [:0]const u8) !void {
    if (args.len < 1) {
        try printRoleHelp();
        return;
    }

    const subcommand = args[0];
    // Use std.debug.print for CLI output

    if (std.mem.eql(u8, subcommand, "create")) {
        if (args.len < 3) {
            std.debug.print("Usage: role create <name> <description>\n", .{});
            return;
        }

        const request = user_manager.UserManager.CreateRoleRequest{
            .name = args[1],
            .description = args[2],
            .permissions = null,
            .parent_role = null,
            .priority = null,
        };

        const role_id = try mgr.createRole(request);
        std.debug.print("Role created successfully:\n", .{});
        std.debug.print("  ID: {}\n", .{role_id});
        std.debug.print("  Name: {s}\n", .{args[1]});
        std.debug.print("  Description: {s}\n", .{args[2]});
    } else if (std.mem.eql(u8, subcommand, "delete")) {
        if (args.len < 2) {
            std.debug.print("Usage: role delete <name>\n", .{});
            return;
        }

        // Find role by name
        var role_id: ?auth.RoleId = null;
        var it = mgr.security_manager.roles.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.name, args[1])) {
                role_id = entry.key_ptr.*;
                break;
            }
        }

        if (role_id) |id| {
            try mgr.deleteRole(id);
            std.debug.print("Role '{s}' deleted successfully\n", .{args[1]});
        } else {
            std.debug.print("Role '{s}' not found\n", .{args[1]});
        }
    } else if (std.mem.eql(u8, subcommand, "list")) {
        std.debug.print("Roles:\n", .{});
        std.debug.print("{s:<20} {s:<40} {s:<10} {s:<10}\n", .{ "Name", "Description", "System", "Priority" });
        std.debug.print("{s}\n", .{"-" ** 80});

        var it = mgr.security_manager.roles.iterator();
        while (it.next()) |entry| {
            const role = entry.value_ptr.*;
            std.debug.print("{s:<20} {s:<40} {s:<10} {:<10}\n", .{
                role.name,
                role.description,
                if (role.is_system) "Yes" else "No",
                role.priority,
            });
        }
    } else if (std.mem.eql(u8, subcommand, "show")) {
        if (args.len < 2) {
            std.debug.print("Usage: role show <name>\n", .{});
            return;
        }

        // Find role by name
        var role: ?auth.Role = null;
        var it = mgr.security_manager.roles.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.name, args[1])) {
                role = entry.value_ptr.*;
                break;
            }
        }

        if (role) |r| {
            std.debug.print("Role Details:\n", .{});
            std.debug.print("  ID: {}\n", .{r.id});
            std.debug.print("  Name: {s}\n", .{r.name});
            std.debug.print("  Description: {s}\n", .{r.description});
            std.debug.print("  System Role: {}\n", .{r.is_system});
            std.debug.print("  Priority: {}\n", .{r.priority});
            if (r.parent_role) |parent| {
                std.debug.print("  Parent Role ID: {}\n", .{parent});
            }

            // Show permissions
            if (r.permissions.items.len > 0) {
                std.debug.print("  Permissions:\n", .{});
                for (r.permissions.items) |perm_id| {
                    if (mgr.security_manager.permissions.get(perm_id)) |perm| {
                        std.debug.print("    - {s} ({s}: {s})\n", .{ perm.name, perm.resource, @tagName(perm.action) });
                    }
                }
            }

            // Show users with this role
            std.debug.print("  Users with this role:\n", .{});
            var user_it = mgr.security_manager.rbac.user_roles.iterator();
            while (user_it.next()) |entry| {
                for (entry.value_ptr.items) |role_id| {
                    if (role_id == r.id) {
                        if (mgr.security_manager.users.get(entry.key_ptr.*)) |user| {
                            std.debug.print("    - {s}\n", .{user.username});
                        }
                    }
                }
            }
        } else {
            std.debug.print("Role '{s}' not found\n", .{args[1]});
        }
    } else {
        try printRoleHelp();
    }
}

fn handlePolicyCommand(mgr: *user_manager.UserManager, args: []const [:0]const u8) !void {
    if (args.len < 1) {
        try printPolicyHelp();
        return;
    }

    const subcommand = args[0];
    // Use std.debug.print for CLI output

    if (std.mem.eql(u8, subcommand, "create")) {
        if (args.len < 4) {
            std.debug.print("Usage: policy create <name> <table> <operation> [options]\n", .{});
            return;
        }

        const operation = std.meta.stringToEnum(rls.RLSEngine.Operation, args[3]) orelse {
            std.debug.print("Invalid operation. Use: select, insert, update, delete, or all\n", .{});
            return;
        };

        const request = user_manager.UserManager.CreatePolicyRequest{
            .name = args[1],
            .description = "RLS policy",
            .graph = "default",
            .table = args[2],
            .operation = operation,
            .permissive = true,
            .roles = &[_][]const u8{"user"}, // Default to user role
            .using_clause = null,
            .check_clause = null,
            .temporal = null,
            .data_classification = null,
            .audit_level = .denials,
        };

        const policy_id = try mgr.createPolicy(request);
        std.debug.print("Policy created successfully:\n", .{});
        std.debug.print("  ID: {}\n", .{policy_id});
        std.debug.print("  Name: {s}\n", .{args[1]});
        std.debug.print("  Table: {s}\n", .{args[2]});
        std.debug.print("  Operation: {s}\n", .{@tagName(operation)});
    } else if (std.mem.eql(u8, subcommand, "list")) {
        std.debug.print("RLS Policies:\n", .{});
        std.debug.print("{s:<20} {s:<20} {s:<15} {s:<10} {s:<10}\n", .{ "Name", "Table", "Operation", "Permissive", "Enabled" });
        std.debug.print("{s}\n", .{"-" ** 75});

        var it = mgr.rls_engine.policies.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |policy| {
                std.debug.print("{s:<20} {s:<20} {s:<15} {s:<10} {s:<10}\n", .{
                    policy.name,
                    policy.table,
                    @tagName(policy.operation),
                    if (policy.permissive) "Yes" else "No",
                    if (policy.enabled) "Yes" else "No",
                });
            }
        }
    } else {
        try printPolicyHelp();
    }
}

fn handleGrantCommand(mgr: *user_manager.UserManager, args: []const [:0]const u8) !void {
    // Use std.debug.print for CLI output

    if (args.len < 4) {
        std.debug.print("Usage: grant <type> <name> to <target>\n", .{});
        return;
    }

    if (std.mem.eql(u8, args[0], "role") and std.mem.eql(u8, args[2], "to")) {
        // Grant role to user
        const role_name = args[1];
        const username = args[3];

        // Find role
        var role_id: ?auth.RoleId = null;
        var it = mgr.security_manager.roles.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.name, role_name)) {
                role_id = entry.key_ptr.*;
                break;
            }
        }

        // Find user
        var user_id: ?auth.UserId = null;
        var user_it = mgr.security_manager.users.iterator();
        while (user_it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, username)) {
                user_id = entry.key_ptr.*;
                break;
            }
        }

        if (role_id == null) {
            std.debug.print("Role '{s}' not found\n", .{role_name});
            return;
        }

        if (user_id == null) {
            std.debug.print("User '{s}' not found\n", .{username});
            return;
        }

        try mgr.security_manager.assignRole(user_id.?, role_id.?);
        std.debug.print("Granted role '{s}' to user '{s}'\n", .{ role_name, username });
    } else {
        std.debug.print("Invalid grant command\n", .{});
    }
}

fn handleRevokeCommand(mgr: *user_manager.UserManager, args: []const [:0]const u8) !void {
    // Use std.debug.print for CLI output

    if (args.len < 4) {
        std.debug.print("Usage: revoke <type> <name> from <target>\n", .{});
        return;
    }

    if (std.mem.eql(u8, args[0], "role") and std.mem.eql(u8, args[2], "from")) {
        // Revoke role from user
        const role_name = args[1];
        const username = args[3];

        // Find role
        var role_id: ?auth.RoleId = null;
        var it = mgr.security_manager.roles.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.name, role_name)) {
                role_id = entry.key_ptr.*;
                break;
            }
        }

        // Find user
        var user_id: ?auth.UserId = null;
        var user_it = mgr.security_manager.users.iterator();
        while (user_it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.username, username)) {
                user_id = entry.key_ptr.*;
                break;
            }
        }

        if (role_id == null) {
            std.debug.print("Role '{s}' not found\n", .{role_name});
            return;
        }

        if (user_id == null) {
            std.debug.print("User '{s}' not found\n", .{username});
            return;
        }

        try mgr.security_manager.revokeRole(user_id.?, role_id.?);
        std.debug.print("Revoked role '{s}' from user '{s}'\n", .{ role_name, username });
    } else {
        std.debug.print("Invalid revoke command\n", .{});
    }
}

fn printUserHelp() !void {
    std.debug.print(
        \\User Commands:
        \\  create <username> <email> <password>   Create a new user
        \\  delete <username>                       Delete a user
        \\  list                                    List all users
        \\  show <username>                         Show user details
        \\  enable <username>                       Enable a user
        \\  disable <username>                      Disable a user
        \\  password <username> <new_password>      Change password
        \\
    , .{});
}

fn printRoleHelp() !void {
    std.debug.print(
        \\Role Commands:
        \\  create <name> <description>   Create a new role
        \\  delete <name>                 Delete a role
        \\  list                          List all roles
        \\  show <name>                   Show role details
        \\
    , .{});
}

fn printPolicyHelp() !void {
    std.debug.print(
        \\Policy Commands:
        \\  create <name> <table> <operation>   Create RLS policy
        \\  delete <name>                        Delete a policy
        \\  list [table]                         List policies
        \\  enable <name>                        Enable a policy
        \\  disable <name>                       Disable a policy
        \\
        \\Operations: select, insert, update, delete, all
        \\
    , .{});
}
