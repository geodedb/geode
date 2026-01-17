const std = @import("std");
const Allocator = std.mem.Allocator;

// CANARY: REQ=REQ-AUTH-CLI-001; FEATURE="CLIUserManagement"; ASPECT=FileStorage; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth.yml; OWNER=cli; UPDATED=2025-10-26
// Simple file-based user storage for CLI commands
// Stores users in a JSON file that the server can also read

pub const User = struct {
    username: []const u8,
    email: []const u8,
    password_hash: []const u8,
    salt: []const u8,
    roles: [][]const u8,
    created_at: i64,
    is_active: bool = true,

    pub fn deinit(self: *User, allocator: Allocator) void {
        allocator.free(self.username);
        allocator.free(self.email);
        allocator.free(self.password_hash);
        allocator.free(self.salt);
        for (self.roles) |role| {
            allocator.free(role);
        }
        allocator.free(self.roles);
    }
};

pub const UserStorage = struct {
    allocator: Allocator,
    data_dir: []const u8,

    const Self = @This();

    pub fn init(allocator: Allocator, data_dir: []const u8) !Self {
        // Ensure data directory exists
        std.fs.cwd().makePath(data_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        return Self{
            .allocator = allocator,
            .data_dir = data_dir,
        };
    }

    fn getUsersFilePath(self: *const Self) ![]const u8 {
        return try std.fs.path.join(self.allocator, &[_][]const u8{ self.data_dir, "users.json" });
    }

    pub fn loadUsers(self: *Self) ![]User {
        const file_path = try self.getUsersFilePath();
        defer self.allocator.free(file_path);

        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // No users file yet, return empty list
                return self.allocator.alloc(User, 0);
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024); // 10MB max
        defer self.allocator.free(content);

        if (content.len == 0) return self.allocator.alloc(User, 0);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        if (parsed.value != .array) return error.InvalidFormat;

        const users_array = parsed.value.array.items;
        var users = try self.allocator.alloc(User, users_array.len);
        var user_count: usize = 0;

        for (users_array) |user_val| {
            if (user_val != .object) continue;

            const obj = user_val.object;

            const username = obj.get("username") orelse continue;
            const email = obj.get("email") orelse continue;
            const password_hash = obj.get("password_hash") orelse continue;
            const salt = obj.get("salt") orelse continue;
            const roles_val = obj.get("roles") orelse continue;
            const created_at = obj.get("created_at") orelse continue;
            const is_active_val = obj.get("is_active");

            if (username != .string or email != .string or password_hash != .string or
                salt != .string or roles_val != .array or created_at != .integer)
            {
                continue;
            }

            // Allocate roles
            var roles = try self.allocator.alloc([]const u8, roles_val.array.items.len);
            var role_count: usize = 0;
            for (roles_val.array.items) |role_val| {
                if (role_val == .string) {
                    roles[role_count] = try self.allocator.dupe(u8, role_val.string);
                    role_count += 1;
                }
            }
            roles = roles[0..role_count]; // Trim to actual count

            users[user_count] = User{
                .username = try self.allocator.dupe(u8, username.string),
                .email = try self.allocator.dupe(u8, email.string),
                .password_hash = try self.allocator.dupe(u8, password_hash.string),
                .salt = try self.allocator.dupe(u8, salt.string),
                .roles = roles,
                .created_at = created_at.integer,
                .is_active = if (is_active_val) |v| if (v == .bool) v.bool else true else true,
            };
            user_count += 1;
        }

        return users[0..user_count];
    }

    pub fn saveUsers(self: *Self, users: []const User) !void {
        const file_path = try self.getUsersFilePath();
        defer self.allocator.free(file_path);

        // Write to temporary file first
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{file_path});
        defer self.allocator.free(tmp_path);

        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();

        // Write JSON directly to file
        try file.writeAll("[\n");

        for (users, 0..) |user, i| {
            if (i > 0) try file.writeAll(",\n");

            try file.writeAll("  {\n");
            const line1 = try std.fmt.allocPrint(self.allocator, "    \"username\": \"{s}\",\n", .{user.username});
            defer self.allocator.free(line1);
            try file.writeAll(line1);

            const line2 = try std.fmt.allocPrint(self.allocator, "    \"email\": \"{s}\",\n", .{user.email});
            defer self.allocator.free(line2);
            try file.writeAll(line2);

            const line3 = try std.fmt.allocPrint(self.allocator, "    \"password_hash\": \"{s}\",\n", .{user.password_hash});
            defer self.allocator.free(line3);
            try file.writeAll(line3);

            const line4 = try std.fmt.allocPrint(self.allocator, "    \"salt\": \"{s}\",\n", .{user.salt});
            defer self.allocator.free(line4);
            try file.writeAll(line4);

            try file.writeAll("    \"roles\": [");

            for (user.roles, 0..) |role, j| {
                if (j > 0) try file.writeAll(", ");
                const role_str = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{role});
                defer self.allocator.free(role_str);
                try file.writeAll(role_str);
            }

            try file.writeAll("],\n");
            const line5 = try std.fmt.allocPrint(self.allocator, "    \"created_at\": {d},\n", .{user.created_at});
            defer self.allocator.free(line5);
            try file.writeAll(line5);

            const line6 = try std.fmt.allocPrint(self.allocator, "    \"is_active\": {}\n", .{user.is_active});
            defer self.allocator.free(line6);
            try file.writeAll(line6);

            try file.writeAll("  }");
        }

        try file.writeAll("\n]\n");

        // Atomic rename
        try std.fs.cwd().rename(tmp_path, file_path);
    }

    pub fn findUser(self: *Self, username: []const u8) !?User {
        const users = try self.loadUsers();
        defer {
            for (users) |*user| {
                user.deinit(self.allocator);
            }
            self.allocator.free(users);
        }

        for (users) |user| {
            if (std.mem.eql(u8, user.username, username)) {
                // Return a copy
                var roles = try self.allocator.alloc([]const u8, user.roles.len);
                for (user.roles, 0..) |role, i| {
                    roles[i] = try self.allocator.dupe(u8, role);
                }

                return User{
                    .username = try self.allocator.dupe(u8, user.username),
                    .email = try self.allocator.dupe(u8, user.email),
                    .password_hash = try self.allocator.dupe(u8, user.password_hash),
                    .salt = try self.allocator.dupe(u8, user.salt),
                    .roles = roles,
                    .created_at = user.created_at,
                    .is_active = user.is_active,
                };
            }
        }

        return null;
    }

    pub fn createUser(self: *Self, username: []const u8, email: []const u8, password: []const u8, roles: []const []const u8) !void {
        const users = try self.loadUsers();
        defer {
            for (users) |*user| {
                user.deinit(self.allocator);
            }
            self.allocator.free(users);
        }

        // Check if user already exists
        for (users) |user| {
            if (std.mem.eql(u8, user.username, username)) {
                return error.UserAlreadyExists;
            }
        }

        // Generate salt
        var salt: [32]u8 = undefined;
        std.crypto.random.bytes(&salt);
        const salt_hex = std.fmt.bytesToHex(salt, .lower);
        const salt_hex_str = try self.allocator.dupe(u8, &salt_hex);
        defer self.allocator.free(salt_hex_str);

        // Hash password with salt using Argon2
        const password_hash = try hashPassword(self.allocator, password, &salt);
        defer self.allocator.free(password_hash);

        // Copy roles
        var user_roles = try self.allocator.alloc([]const u8, roles.len);
        for (roles, 0..) |role, i| {
            user_roles[i] = try self.allocator.dupe(u8, role);
        }

        const new_user = User{
            .username = try self.allocator.dupe(u8, username),
            .email = try self.allocator.dupe(u8, email),
            .password_hash = try self.allocator.dupe(u8, password_hash),
            .salt = try self.allocator.dupe(u8, salt_hex_str),
            .roles = user_roles,
            .created_at = std.time.timestamp(),
            .is_active = true,
        };

        // Create new list with new user
        var new_users = try self.allocator.alloc(User, users.len + 1);
        @memcpy(new_users[0..users.len], users);
        new_users[users.len] = new_user;

        try self.saveUsers(new_users);

        // Clean up new_users list (but not the users inside, they were just copied)
        self.allocator.free(new_users);
    }

    pub fn deleteUser(self: *Self, username: []const u8) !bool {
        const users = try self.loadUsers();
        defer {
            for (users) |*user| {
                user.deinit(self.allocator);
            }
            self.allocator.free(users);
        }

        var found = false;
        var found_idx: usize = 0;
        for (users, 0..) |user, i| {
            if (std.mem.eql(u8, user.username, username)) {
                found = true;
                found_idx = i;
                break;
            }
        }

        if (found) {
            // Create new list without the deleted user
            var new_users = try self.allocator.alloc(User, users.len - 1);
            var new_idx: usize = 0;
            for (users, 0..) |user, i| {
                if (i != found_idx) {
                    new_users[new_idx] = user;
                    new_idx += 1;
                }
            }

            try self.saveUsers(new_users);
            self.allocator.free(new_users);
        }

        return found;
    }
};

fn hashPassword(allocator: Allocator, password: []const u8, salt: *const [32]u8) ![]const u8 {
    // Use Argon2id for password hashing
    var hash: [64]u8 = undefined;

    const params = std.crypto.pwhash.argon2.Params{
        .t = 3, // iterations
        .m = 65536, // memory cost (64 MB)
        .p = 4, // parallelism
    };

    try std.crypto.pwhash.argon2.kdf(
        allocator,
        &hash,
        password,
        salt,
        params,
        .argon2id,
    );

    // Return hex-encoded hash
    const hash_hex = std.fmt.bytesToHex(hash, .lower);
    return try allocator.dupe(u8, &hash_hex);
}
