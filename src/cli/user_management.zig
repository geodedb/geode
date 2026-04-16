const std = @import("std");

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

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-059; FEATURE="JSON Library Migration"; ASPECT=UserManagement; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-25
const json_lib = @import("json");

pub const User = struct {
    username: []const u8,
    email: ?[]const u8 = null,
    status: []const u8 = "active",
    roles: []const []const u8 = &.{},
    created_at: i64,
    updated_at: i64,
};

// JSON struct for unmarshaling - matches the User struct for direct parsing
const JsonUser = struct {
    username: []const u8,
    email: ?[]const u8 = null,
    status: []const u8 = "active",
    roles: []const []const u8 = &.{},
    created_at: i64 = 0,
    updated_at: i64 = 0,
};

pub const UserStore = struct {
    users: std.ArrayList(User),
    allocator: std.mem.Allocator,
    file_path: []const u8,

    pub fn init(allocator: std.mem.Allocator) !UserStore {
        const home_dir = getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return error.NoHomeDir,
            else => return err,
        };
        defer allocator.free(home_dir);

        const geode_dir = try std.fs.path.join(allocator, &.{ home_dir, ".geode" });
        defer allocator.free(geode_dir);

        // Create directory if it doesn't exist
        std.fs.makeDirAbsolute(geode_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const file_path = try std.fs.path.join(allocator, &.{ geode_dir, "users.json" });

        const users = std.ArrayList(User).empty;

        var store = UserStore{
            .users = users,
            .allocator = allocator,
            .file_path = file_path,
        };

        // Load existing users
        try store.load();

        // If no users exist, create default admin user
        if (store.users.items.len == 0) {
            const admin = User{
                .username = try allocator.dupe(u8, "admin"),
                .email = try allocator.dupe(u8, "admin@localhost"),
                .status = try allocator.dupe(u8, "active"),
                .roles = try allocator.dupe([]const u8, &[_][]const u8{"admin"}),
                .created_at = compat_timestamp(),
                .updated_at = compat_timestamp(),
            };
            try store.users.append(store.allocator, admin);
            try store.save();
        }

        return store;
    }

    pub fn deinit(self: *UserStore) void {
        // Free all user data
        for (self.users.items) |user| {
            self.allocator.free(user.username);
            if (user.email) |email| self.allocator.free(email);
            self.allocator.free(user.status);
            for (user.roles) |role| {
                self.allocator.free(role);
            }
            self.allocator.free(user.roles);
        }
        self.users.deinit();
        self.allocator.free(self.file_path);
    }

    pub fn load(self: *UserStore) !void {
        const file = std.fs.openFileAbsolute(self.file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return, // No file yet, that's OK
            else => return err,
        };
        defer file.close();

        const file_size = try file.getEndPos();
        if (file_size == 0) return; // Empty file

        const contents = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(contents);
        _ = try file.read(contents);

        // Parse JSON using json library unmarshal
        var json_users = json_lib.unmarshal([]JsonUser, self.allocator, contents) catch |err| {
            // If unmarshal fails, try to recover gracefully
            _ = err;
            return;
        };
        defer json_lib.free([]JsonUser, self.allocator, &json_users);

        // Copy users with owned memory
        for (json_users) |json_user| {
            const user = User{
                .username = try self.allocator.dupe(u8, json_user.username),
                .email = if (json_user.email) |e| try self.allocator.dupe(u8, e) else null,
                .status = try self.allocator.dupe(u8, json_user.status),
                .roles = blk: {
                    var roles = try self.allocator.alloc([]const u8, json_user.roles.len);
                    for (json_user.roles, 0..) |role, i| {
                        roles[i] = try self.allocator.dupe(u8, role);
                    }
                    break :blk roles;
                },
                .created_at = if (json_user.created_at == 0) compat_timestamp() else json_user.created_at,
                .updated_at = if (json_user.updated_at == 0) compat_timestamp() else json_user.updated_at,
            };

            try self.users.append(self.allocator, user);
        }
    }

    pub fn save(self: *UserStore) !void {
        const file = try std.fs.createFileAbsolute(self.file_path, .{});
        defer file.close();

        // Encode users to JSON using json library
        const json_str = try json_lib.encode(self.allocator, self.users.items, .{ .pretty = true });
        defer self.allocator.free(json_str);

        try file.writeAll(json_str);
        try file.writeAll("\n");
    }

    pub fn createUser(self: *UserStore, username: []const u8, email: ?[]const u8, roles: ?[]const []const u8) !void {
        // Check if user already exists
        for (self.users.items) |user| {
            if (std.mem.eql(u8, user.username, username)) {
                return error.UserAlreadyExists;
            }
        }

        const user = User{
            .username = try self.allocator.dupe(u8, username),
            .email = if (email) |e| try self.allocator.dupe(u8, e) else null,
            .status = try self.allocator.dupe(u8, "active"),
            .roles = if (roles) |r| try self.allocator.dupe([]const u8, r) else try self.allocator.dupe([]const u8, &[_][]const u8{"user"}),
            .created_at = compat_timestamp(),
            .updated_at = compat_timestamp(),
        };

        try self.users.append(self.allocator, user);
        try self.save();
    }

    pub fn deleteUser(self: *UserStore, username: []const u8) !void {
        var found_index: ?usize = null;
        for (self.users.items, 0..) |user, i| {
            if (std.mem.eql(u8, user.username, username)) {
                found_index = i;
                break;
            }
        }

        if (found_index) |index| {
            const user = self.users.orderedRemove(index);
            self.allocator.free(user.username);
            if (user.email) |email| self.allocator.free(email);
            self.allocator.free(user.status);
            for (user.roles) |role| {
                self.allocator.free(role);
            }
            self.allocator.free(user.roles);
            try self.save();
        } else {
            return error.UserNotFound;
        }
    }

    pub fn getUser(self: *UserStore, username: []const u8) ?User {
        for (self.users.items) |user| {
            if (std.mem.eql(u8, user.username, username)) {
                return user;
            }
        }
        return null;
    }

    pub fn listUsers(self: *UserStore) []User {
        return self.users.items;
    }
};
