const std = @import("std");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const Allocator = std.mem.Allocator;

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-060; FEATURE="JSON Library Migration"; ASPECT=UserStorageSimple; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-25
const json_lib = @import("json");

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

// JSON struct for unmarshaling - matches User struct for direct parsing
const JsonUser = struct {
    username: []const u8,
    email: []const u8,
    password_hash: []const u8,
    salt: []const u8,
    roles: []const []const u8 = &.{},
    created_at: i64 = 0,
    is_active: bool = true,
};

pub const UserStorage = struct {
    allocator: Allocator,
    data_dir: []const u8,

    const Self = @This();

    pub fn init(allocator: Allocator, data_dir: []const u8) !Self {
        // Ensure data directory exists
        std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), data_dir) catch |err| {
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

        const file = std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), file_path, .{}) catch |err| {
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

        // Parse JSON using json library unmarshal
        var json_users = json_lib.unmarshal([]JsonUser, self.allocator, content) catch {
            // If unmarshal fails, return empty list
            return self.allocator.alloc(User, 0);
        };
        defer json_lib.free([]JsonUser, self.allocator, &json_users);

        var users = try self.allocator.alloc(User, json_users.len);
        var user_count: usize = 0;

        for (json_users) |json_user| {
            // Allocate roles
            var roles = try self.allocator.alloc([]const u8, json_user.roles.len);
            for (json_user.roles, 0..) |role, i| {
                roles[i] = try self.allocator.dupe(u8, role);
            }

            users[user_count] = User{
                .username = try self.allocator.dupe(u8, json_user.username),
                .email = try self.allocator.dupe(u8, json_user.email),
                .password_hash = try self.allocator.dupe(u8, json_user.password_hash),
                .salt = try self.allocator.dupe(u8, json_user.salt),
                .roles = roles,
                .created_at = json_user.created_at,
                .is_active = json_user.is_active,
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

        const file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), tmp_path, .{});
        defer file.close();

        // Encode users to JSON using json library
        const json_str = try json_lib.encode(self.allocator, users, .{ .pretty = true });
        defer self.allocator.free(json_str);

        try file.writeAll(json_str);
        try file.writeAll("\n");

        // Atomic rename
        try std.Io.Dir.cwd().rename(tmp_path, file_path);
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
        compat_fillRandom(&salt);
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
            .created_at = compat_timestamp(),
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
