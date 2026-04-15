const std = @import("std");
const Allocator = std.mem.Allocator;

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-061; FEATURE="JSON Library Migration"; ASPECT=UserStorageSecure; STATUS=EXEMPT; OWNER=cli; UPDATED=2026-01-25
const json_lib = @import("json");

// CANARY: REQ=REQ-AUTH-CLI-001; FEATURE="CLIUserManagement"; ASPECT=SecureStorage; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth.yml; OWNER=cli; UPDATED=2026-01-09
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

// JSON struct for unmarshaling - salt is hex-encoded in JSON
const JsonUser = struct {
    username: []const u8,
    email: []const u8,
    password_hash: []const u8,
    salt: []const u8, // Hex-encoded in JSON
    roles: []const []const u8 = &.{},
    created_at: i64 = 0,
    is_active: bool = true,
};

pub const UserStorage = struct {
    allocator: Allocator,
    data_dir: []const u8,
    encryption_key: [32]u8,

    const Self = @This();

    pub fn init(allocator: Allocator, data_dir: []const u8) !Self {
        // Ensure data directory exists
        std.Io.Dir.cwd().makePath(data_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Generate or load encryption key (in production, this should be from a secure key store)
        var encryption_key: [32]u8 = undefined;
        const key_path = try std.fs.path.join(allocator, &[_][]const u8{ data_dir, ".enckey" });
        defer allocator.free(key_path);

        // Try to load existing key or generate new one
        if (std.Io.Dir.cwd().openFile(key_path, .{})) |key_file| {
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
                const file = try std.Io.Dir.cwd().createFile(key_path, .{ .mode = 0o600 });
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
        const file = std.Io.Dir.cwd().openFile(data_path, .{}) catch |err| switch (err) {
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

        // Decrypt the data
        const json_data = try self.decryptData(encrypted_data);
        defer self.allocator.free(json_data);

        // Parse JSON using json library unmarshal
        var json_users = json_lib.unmarshal([]JsonUser, self.allocator, json_data) catch {
            return try self.allocator.alloc(User, 0);
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

            // Hex-decode salt from JSON
            const salt_hex = json_user.salt;
            if (salt_hex.len != 64) continue; // Salt must be 32 bytes = 64 hex chars
            var salt_bytes: [32]u8 = undefined;
            var valid_salt = true;
            var i: usize = 0;
            while (i < 32) : (i += 1) {
                const high = std.fmt.charToDigit(salt_hex[i * 2], 16) catch {
                    valid_salt = false;
                    break;
                };
                const low = std.fmt.charToDigit(salt_hex[i * 2 + 1], 16) catch {
                    valid_salt = false;
                    break;
                };
                salt_bytes[i] = (high << 4) | low;
            }
            if (!valid_salt) {
                for (roles) |role| self.allocator.free(role);
                self.allocator.free(roles);
                continue;
            }

            users[user_count] = User{
                .username = try self.allocator.dupe(u8, json_user.username),
                .email = try self.allocator.dupe(u8, json_user.email),
                .password_hash = try self.allocator.dupe(u8, json_user.password_hash),
                .salt = try self.allocator.dupe(u8, &salt_bytes),
                .roles = roles,
                .created_at = json_user.created_at,
                .is_active = json_user.is_active,
            };
            user_count += 1;
        }

        return users[0..user_count];
    }

    fn saveUsers(self: *Self, users: []const User) !void {
        const data_path = try self.getDataPath();
        defer self.allocator.free(data_path);

        // Convert users to JSON-compatible format with hex-encoded salt
        var json_users = try self.allocator.alloc(JsonUser, users.len);
        defer self.allocator.free(json_users);

        var salt_hex_strs = try self.allocator.alloc([]const u8, users.len);
        defer {
            for (salt_hex_strs[0..users.len]) |s| {
                self.allocator.free(s);
            }
            self.allocator.free(salt_hex_strs);
        }

        for (users, 0..) |user, i| {
            // Hex-encode salt for JSON storage
            const salt_hex = std.fmt.bytesToHex(user.salt[0..32].*, .lower);
            salt_hex_strs[i] = try self.allocator.dupe(u8, &salt_hex);

            json_users[i] = JsonUser{
                .username = user.username,
                .email = user.email,
                .password_hash = user.password_hash,
                .salt = salt_hex_strs[i],
                .roles = user.roles,
                .created_at = user.created_at,
                .is_active = user.is_active,
            };
        }

        // Encode users to JSON using json library
        const json_str = try json_lib.encode(self.allocator, json_users, .{});
        defer self.allocator.free(json_str);

        // Encrypt the data
        const encrypted_data = try self.encryptData(json_str);
        defer self.allocator.free(encrypted_data);

        // Write to file
        const file = try std.Io.Dir.cwd().createFile(data_path, .{ .mode = 0o600 });
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
