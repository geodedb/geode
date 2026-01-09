const std = @import("std");
const Allocator = std.mem.Allocator;

// CANARY: REQ=REQ-AUTH-CLI-001; FEATURE="CLIUserManagement"; ASPECT=SecureStorage; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-09
// Secure encrypted user storage for CLI commands
// Uses AES-256-GCM authenticated encryption with Argon2id password hashing

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
    encryption_key: [32]u8,

    const Self = @This();

    pub fn init(allocator: Allocator, data_dir: []const u8) !Self {
        // Ensure data directory exists
        std.fs.cwd().makePath(data_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Generate or load encryption key (in production, this should be from a secure key store)
        var encryption_key: [32]u8 = undefined;
        const key_path = try std.fs.path.join(allocator, &[_][]const u8{ data_dir, ".enckey" });
        defer allocator.free(key_path);

        // Try to load existing key or generate new one
        if (std.fs.cwd().openFile(key_path, .{})) |key_file| {
            // File exists, read the key
            defer key_file.close();
            const bytes_read = try key_file.readAll(&encryption_key);
            if (bytes_read != 32) {
                return error.InvalidKeyFile;
            }
        } else |err| switch (err) {
            error.FileNotFound => {
                // Generate new key
                std.crypto.random.bytes(&encryption_key);

                // Save it
                const file = try std.fs.cwd().createFile(key_path, .{ .mode = 0o600 });
                defer file.close();
                try file.writeAll(&encryption_key);
            },
            else => return err,
        }

        return Self{
            .allocator = allocator,
            .data_dir = try allocator.dupe(u8, data_dir),
            .encryption_key = encryption_key,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.data_dir);
    }

    fn getDataPath(self: *Self) ![]const u8 {
        return std.fs.path.join(self.allocator, &[_][]const u8{ self.data_dir, "users.dat" });
    }

    pub fn createUser(self: *Self, username: []const u8, email: []const u8, password: []const u8, roles: []const []const u8) !void {
        // Check if user already exists
        const users = try self.loadUsers();
        defer {
            for (users) |*user| {
                user.deinit(self.allocator);
            }
            self.allocator.free(users);
        }

        for (users) |user| {
            if (std.mem.eql(u8, user.username, username)) {
                return error.UserAlreadyExists;
            }
        }

        // Generate random salt
        var salt: [32]u8 = undefined;
        std.crypto.random.bytes(&salt);

        // Hash password with Argon2id (OWASP recommended)
        const password_hash = try hashPassword(self.allocator, password, &salt);
        defer self.allocator.free(password_hash);

        // Create new user
        var new_user = User{
            .username = try self.allocator.dupe(u8, username),
            .email = try self.allocator.dupe(u8, email),
            .password_hash = try self.allocator.dupe(u8, password_hash),
            .salt = try self.allocator.dupe(u8, &salt),
            .roles = try self.allocator.alloc([]const u8, roles.len),
            .created_at = std.time.timestamp(),
            .is_active = true,
        };

        for (roles, 0..) |role, i| {
            new_user.roles[i] = try self.allocator.dupe(u8, role);
        }

        // Add to users array and save
        var all_users = try self.allocator.alloc(User, users.len + 1);
        defer self.allocator.free(all_users);

        @memcpy(all_users[0..users.len], users);
        all_users[users.len] = new_user;

        try self.saveUsers(all_users);

        // Clean up new_user (it's been saved)
        new_user.deinit(self.allocator);
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
                // Return a deep copy
                var roles_copy = try self.allocator.alloc([]const u8, user.roles.len);
                for (user.roles, 0..) |role, i| {
                    roles_copy[i] = try self.allocator.dupe(u8, role);
                }

                return User{
                    .username = try self.allocator.dupe(u8, user.username),
                    .email = try self.allocator.dupe(u8, user.email),
                    .password_hash = try self.allocator.dupe(u8, user.password_hash),
                    .salt = try self.allocator.dupe(u8, user.salt),
                    .roles = roles_copy,
                    .created_at = user.created_at,
                    .is_active = user.is_active,
                };
            }
        }

        return null;
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
        var new_users = try self.allocator.alloc(User, 0);
        defer if (!found) self.allocator.free(new_users);

        for (users) |user| {
            if (std.mem.eql(u8, user.username, username)) {
                found = true;
                continue;
            }

            const old_len = new_users.len;
            new_users = try self.allocator.realloc(new_users, old_len + 1);

            // Deep copy to avoid double-free when cleaning up both arrays
            var roles_copy = try self.allocator.alloc([]const u8, user.roles.len);
            for (user.roles, 0..) |role, i| {
                roles_copy[i] = try self.allocator.dupe(u8, role);
            }

            new_users[old_len] = User{
                .username = try self.allocator.dupe(u8, user.username),
                .email = try self.allocator.dupe(u8, user.email),
                .password_hash = try self.allocator.dupe(u8, user.password_hash),
                .salt = try self.allocator.dupe(u8, user.salt),
                .roles = roles_copy,
                .created_at = user.created_at,
                .is_active = user.is_active,
            };
        }

        if (found) {
            try self.saveUsers(new_users);
            for (new_users) |*user| {
                user.deinit(self.allocator);
            }
            self.allocator.free(new_users);
        }

        return found;
    }

    pub fn loadUsers(self: *Self) ![]User {
        const data_path = try self.getDataPath();
        defer self.allocator.free(data_path);

        // Try to load encrypted data
        const file = std.fs.cwd().openFile(data_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // No users yet, return empty array
                return try self.allocator.alloc(User, 0);
            },
            else => return err,
        };
        defer file.close();

        const encrypted_data = try file.readToEndAlloc(self.allocator, 100 * 1024 * 1024);
        defer self.allocator.free(encrypted_data);

        if (encrypted_data.len == 0) {
            return try self.allocator.alloc(User, 0);
        }

        // Decrypt the data (simplified - in production use proper AES-GCM)
        const json_data = try self.decryptData(encrypted_data);
        defer self.allocator.free(json_data);

        // Parse JSON
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json_data, .{});
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

            var roles = try self.allocator.alloc([]const u8, roles_val.array.items.len);
            var role_count: usize = 0;
            for (roles_val.array.items) |role_val| {
                if (role_val == .string) {
                    roles[role_count] = try self.allocator.dupe(u8, role_val.string);
                    role_count += 1;
                }
            }
            roles = roles[0..role_count];

            // Hex-decode salt from JSON
            const salt_hex = salt.string;
            if (salt_hex.len != 64) continue; // Salt must be 32 bytes = 64 hex chars
            var salt_bytes: [32]u8 = undefined;
            var i: usize = 0;
            while (i < 32) : (i += 1) {
                const high = std.fmt.charToDigit(salt_hex[i * 2], 16) catch continue;
                const low = std.fmt.charToDigit(salt_hex[i * 2 + 1], 16) catch continue;
                salt_bytes[i] = (high << 4) | low;
            }

            users[user_count] = User{
                .username = try self.allocator.dupe(u8, username.string),
                .email = try self.allocator.dupe(u8, email.string),
                .password_hash = try self.allocator.dupe(u8, password_hash.string),
                .salt = try self.allocator.dupe(u8, &salt_bytes),
                .roles = roles,
                .created_at = created_at.integer,
                .is_active = if (is_active_val) |v| if (v == .bool) v.bool else true else true,
            };
            user_count += 1;
        }

        return users[0..user_count];
    }

    fn saveUsers(self: *Self, users: []const User) !void {
        const data_path = try self.getDataPath();
        defer self.allocator.free(data_path);

        // Serialize to JSON
        var json_array = std.ArrayList(u8).initCapacity(self.allocator, 1024) catch return error.OutOfMemory;
        defer json_array.deinit(self.allocator);

        try json_array.appendSlice(self.allocator, "[");
        for (users, 0..) |user, i| {
            if (i > 0) try json_array.appendSlice(self.allocator, ",");

            // Hex-encode salt for JSON storage
            const salt_hex = std.fmt.bytesToHex(user.salt[0..32].*, .lower);

            try json_array.appendSlice(self.allocator, "{");
            try std.fmt.format(json_array.writer(self.allocator), "\"username\":\"{s}\",", .{user.username});
            try std.fmt.format(json_array.writer(self.allocator), "\"email\":\"{s}\",", .{user.email});
            try std.fmt.format(json_array.writer(self.allocator), "\"password_hash\":\"{s}\",", .{user.password_hash});
            try std.fmt.format(json_array.writer(self.allocator), "\"salt\":\"{s}\",", .{salt_hex});
            try std.fmt.format(json_array.writer(self.allocator), "\"created_at\":{d},", .{user.created_at});
            try std.fmt.format(json_array.writer(self.allocator), "\"is_active\":{},", .{user.is_active});
            try json_array.appendSlice(self.allocator, "\"roles\":[");
            for (user.roles, 0..) |role, ri| {
                if (ri > 0) try json_array.appendSlice(self.allocator, ",");
                try std.fmt.format(json_array.writer(self.allocator), "\"{s}\"", .{role});
            }
            try json_array.appendSlice(self.allocator, "]}");
        }
        try json_array.appendSlice(self.allocator, "]");

        // Encrypt the data
        const encrypted_data = try self.encryptData(json_array.items);
        defer self.allocator.free(encrypted_data);

        // Write to file
        const file = try std.fs.cwd().createFile(data_path, .{ .mode = 0o600 });
        defer file.close();
        try file.writeAll(encrypted_data);
    }

    // AES-256-GCM encryption constants
    const AesGcm = std.crypto.aead.aes_gcm.Aes256Gcm;
    const nonce_len = AesGcm.nonce_length; // 12 bytes
    const tag_len = AesGcm.tag_length; // 16 bytes

    fn encryptData(self: *Self, data: []const u8) ![]u8 {
        // AES-256-GCM authenticated encryption
        // Output format: [nonce (12 bytes)] [auth_tag (16 bytes)] [ciphertext]
        const total_len = nonce_len + tag_len + data.len;
        var result = try self.allocator.alloc(u8, total_len);
        errdefer self.allocator.free(result);

        // Generate random nonce
        var nonce: [nonce_len]u8 = undefined;
        std.crypto.random.bytes(&nonce);
        @memcpy(result[0..nonce_len], &nonce);

        // Encrypt with authentication
        var ciphertext = result[nonce_len + tag_len ..];
        var tag: [tag_len]u8 = undefined;

        AesGcm.encrypt(ciphertext, &tag, data, "", nonce, self.encryption_key);

        // Copy tag after nonce
        @memcpy(result[nonce_len .. nonce_len + tag_len], &tag);

        return result;
    }

    fn decryptData(self: *Self, encrypted: []const u8) ![]u8 {
        // AES-256-GCM authenticated decryption
        // Input format: [nonce (12 bytes)] [auth_tag (16 bytes)] [ciphertext]
        const min_len = nonce_len + tag_len;
        if (encrypted.len < min_len) return error.InvalidData;

        const nonce = encrypted[0..nonce_len].*;
        const tag = encrypted[nonce_len .. nonce_len + tag_len].*;
        const ciphertext = encrypted[nonce_len + tag_len ..];

        var plaintext = try self.allocator.alloc(u8, ciphertext.len);
        errdefer self.allocator.free(plaintext);

        // Decrypt and verify authentication tag
        AesGcm.decrypt(plaintext, ciphertext, tag, "", nonce, self.encryption_key) catch {
            self.allocator.free(plaintext);
            return error.AuthenticationFailed;
        };

        return plaintext;
    }
};

fn hashPassword(allocator: Allocator, password: []const u8, salt: *const [32]u8) ![]const u8 {
    // Use Argon2id for password hashing (OWASP recommended)
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
