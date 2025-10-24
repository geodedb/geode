const std = @import("std");
const json = std.json;

pub const User = struct {
    username: []const u8,
    email: ?[]const u8 = null,
    status: []const u8 = "active",
    roles: []const []const u8 = &.{},
    created_at: i64,
    updated_at: i64,
};

pub const UserStore = struct {
    users: std.ArrayList(User),
    allocator: std.mem.Allocator,
    file_path: []const u8,

    pub fn init(allocator: std.mem.Allocator) !UserStore {
        const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
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

        const users = std.ArrayList(User).initCapacity(allocator, 0) catch return error.OutOfMemory;

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
                .created_at = std.time.timestamp(),
                .updated_at = std.time.timestamp(),
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

        // Parse JSON
        const parsed = try json.parseFromSlice(json.Value, self.allocator, contents, .{});
        defer parsed.deinit();

        if (parsed.value != .array) return;

        for (parsed.value.array.items) |item| {
            if (item != .object) continue;

            const obj = item.object;
            const username = obj.get("username") orelse continue;
            if (username != .string) continue;

            const user = User{
                .username = try self.allocator.dupe(u8, username.string),
                .email = if (obj.get("email")) |e| if (e == .string) try self.allocator.dupe(u8, e.string) else null else null,
                .status = if (obj.get("status")) |s| if (s == .string) try self.allocator.dupe(u8, s.string) else try self.allocator.dupe(u8, "active") else try self.allocator.dupe(u8, "active"),
                .roles = blk: {
                    if (obj.get("roles")) |r| {
                        if (r == .array) {
                            var roles = try self.allocator.alloc([]const u8, r.array.items.len);
                            for (r.array.items, 0..) |role_item, i| {
                                if (role_item == .string) {
                                    roles[i] = try self.allocator.dupe(u8, role_item.string);
                                } else {
                                    roles[i] = try self.allocator.dupe(u8, "user");
                                }
                            }
                            break :blk roles;
                        }
                    }
                    break :blk try self.allocator.dupe([]const u8, &[_][]const u8{});
                },
                .created_at = if (obj.get("created_at")) |c| if (c == .integer) c.integer else std.time.timestamp() else std.time.timestamp(),
                .updated_at = if (obj.get("updated_at")) |u| if (u == .integer) u.integer else std.time.timestamp() else std.time.timestamp(),
            };

            try self.users.append(self.allocator, user);
        }
    }

    pub fn save(self: *UserStore) !void {
        const file = try std.fs.createFileAbsolute(self.file_path, .{});
        defer file.close();

        const writer = file.writer();

        try writer.writeByte('[');
        for (self.users.items, 0..) |user, i| {
            if (i > 0) {
                try writer.writeAll(",\n  ");
            } else {
                try writer.writeAll("\n  ");
            }

            try writer.writeAll("{");
            try writer.print("\"username\":\"{s}\"", .{user.username});

            if (user.email) |email| {
                try writer.print(",\"email\":\"{s}\"", .{email});
            }

            try writer.print(",\"status\":\"{s}\"", .{user.status});

            try writer.writeAll(",\"roles\":[");
            for (user.roles, 0..) |role, j| {
                if (j > 0) try writer.writeByte(',');
                try writer.print("\"{s}\"", .{role});
            }
            try writer.writeAll("]");

            try writer.print(",\"created_at\":{}", .{user.created_at});
            try writer.print(",\"updated_at\":{}", .{user.updated_at});
            try writer.writeByte('}');
        }
        if (self.users.items.len > 0) try writer.writeByte('\n');
        try writer.writeAll("]\n");
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
            .created_at = std.time.timestamp(),
            .updated_at = std.time.timestamp(),
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
