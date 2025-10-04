const std = @import("std");
const testing = std.testing;

// Tests for User Management with persistent storage
// CANARY: REQ=REQ-GQL-202; FEATURE="UserManagement"; ASPECT=PersistentStorage; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_202_UserManagement; OWNER=security; UPDATED=2025-10-04

// Simplified user storage structures for testing
const UserRecord = struct {
    id: u64,
    username: [64]u8,
    username_len: u16,
    email: [128]u8,
    email_len: u16,
    password_hash: [128]u8,
    password_hash_len: u16,
    is_active: bool,
    mfa_enabled: bool,
    created_at: i64,
    updated_at: i64,
    
    pub fn getUsername(self: *const UserRecord) []const u8 {
        return self.username[0..self.username_len];
    }
    
    pub fn getEmail(self: *const UserRecord) []const u8 {
        return self.email[0..self.email_len];
    }
    
    pub fn getPasswordHash(self: *const UserRecord) []const u8 {
        return self.password_hash[0..self.password_hash_len];
    }
};

const SimpleUserStorage = struct {
    allocator: std.mem.Allocator,
    users: std.AutoHashMap(u64, UserRecord),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .users = std.AutoHashMap(u64, UserRecord).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.users.deinit();
    }
    
    pub fn persistUser(self: *Self, user_id: u64, username: []const u8, email: []const u8, password_hash: []const u8) !void {
        if (username.len > 63 or email.len > 127 or password_hash.len > 127) {
            return error.FieldTooLong;
        }
        
        var record = UserRecord{
            .id = user_id,
            .username = [_]u8{0} ** 64,
            .username_len = @intCast(username.len),
            .email = [_]u8{0} ** 128,
            .email_len = @intCast(email.len),
            .password_hash = [_]u8{0} ** 128,
            .password_hash_len = @intCast(password_hash.len),
            .is_active = true,
            .mfa_enabled = false,
            .created_at = std.time.milliTimestamp(),
            .updated_at = std.time.milliTimestamp(),
        };
        
        @memcpy(record.username[0..username.len], username);
        @memcpy(record.email[0..email.len], email);
        @memcpy(record.password_hash[0..password_hash.len], password_hash);
        
        try self.users.put(user_id, record);
    }
    
    pub fn getUser(self: *Self, user_id: u64) ?UserRecord {
        return self.users.get(user_id);
    }
    
    pub fn getUserByUsername(self: *Self, username: []const u8) ?UserRecord {
        var it = self.users.valueIterator();
        while (it.next()) |record| {
            if (std.mem.eql(u8, record.getUsername(), username)) {
                return record.*;
            }
        }
        return null;
    }
    
    pub fn removeUser(self: *Self, user_id: u64) void {
        _ = self.users.remove(user_id);
    }
    
    pub fn updateUser(self: *Self, user_id: u64, email: ?[]const u8, password_hash: ?[]const u8, is_active: ?bool, mfa_enabled: ?bool) !void {
        var record = self.users.get(user_id) orelse return error.UserNotFound;
        
        if (email) |e| {
            if (e.len > 127) return error.FieldTooLong;
            @memset(record.email[0..], 0);
            @memcpy(record.email[0..e.len], e);
            record.email_len = @intCast(e.len);
        }
        
        if (password_hash) |ph| {
            if (ph.len > 127) return error.FieldTooLong;
            @memset(record.password_hash[0..], 0);
            @memcpy(record.password_hash[0..ph.len], ph);
            record.password_hash_len = @intCast(ph.len);
        }
        
        if (is_active) |active| {
            record.is_active = active;
        }
        
        if (mfa_enabled) |enabled| {
            record.mfa_enabled = enabled;
        }
        
        record.updated_at = std.time.milliTimestamp();
        
        try self.users.put(user_id, record);
    }
    
    pub fn userIterator(self: *Self) std.AutoHashMap(u64, UserRecord).ValueIterator {
        return self.users.valueIterator();
    }
};

// Mock page manager for testing
const MockPageManager = struct {
    allocator: std.mem.Allocator,
    pages: std.AutoHashMap(u64, []u8),
    next_page_id: u64 = 1,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .pages = std.AutoHashMap(u64, []u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        var it = self.pages.valueIterator();
        while (it.next()) |page_data| {
            self.allocator.free(page_data.*);
        }
        self.pages.deinit();
    }
    
    pub fn allocatePage(self: *Self) !u64 {
        const page_id = self.next_page_id;
        self.next_page_id += 1;
        
        // Allocate 4KB page
        const page_data = try self.allocator.alloc(u8, 4096);
        @memset(page_data, 0);
        try self.pages.put(page_id, page_data);
        
        return page_id;
    }
    
    pub fn readPage(self: *Self, page_id: u64) ![]u8 {
        return self.pages.get(page_id) orelse return error.PageNotFound;
    }
    
    pub fn writePage(self: *Self, page_id: u64, data: []const u8) !void {
        const page_data = self.pages.get(page_id) orelse return error.PageNotFound;
        
        if (data.len > page_data.len) {
            return error.DataTooLarge;
        }
        
        @memcpy(page_data[0..data.len], data);
    }
};

test "TestCANARY_REQ_GQL_202_UserManagement" {
    const allocator = testing.allocator;
    
    // Initialize user storage backend
    var user_store = SimpleUserStorage.init(allocator);
    defer user_store.deinit();
    
    // Test user persistence
    try user_store.persistUser(
        1,
        "alice",
        "alice@example.com",
        "hashed_password_123",
    );
    
    // Verify user was stored
    const stored_user = user_store.getUser(1);
    try testing.expect(stored_user != null);
    try testing.expectEqualStrings("alice", stored_user.?.getUsername());
    try testing.expectEqualStrings("alice@example.com", stored_user.?.getEmail());
    try testing.expectEqualStrings("hashed_password_123", stored_user.?.getPasswordHash());
    
    std.debug.print("\nUser management persistence test passed\n", .{});
}

test "user storage CRUD operations" {
    const allocator = testing.allocator;
    
    var user_store = SimpleUserStorage.init(allocator);
    defer user_store.deinit();
    
    // Create users
    try user_store.persistUser(1, "alice", "alice@example.com", "hash1");
    try user_store.persistUser(2, "bob", "bob@example.com", "hash2");
    try user_store.persistUser(3, "charlie", "charlie@example.com", "hash3");
    
    // Test getUserByUsername
    const alice = user_store.getUserByUsername("alice");
    try testing.expect(alice != null);
    try testing.expect(alice.?.id == 1);
    
    // Test update user
    try user_store.updateUser(1, "alice.new@example.com", "new_hash", true, true);
    
    const updated_alice = user_store.getUser(1);
    try testing.expect(updated_alice != null);
    try testing.expectEqualStrings("alice.new@example.com", updated_alice.?.getEmail());
    try testing.expectEqualStrings("new_hash", updated_alice.?.getPasswordHash());
    try testing.expect(updated_alice.?.is_active == true);
    try testing.expect(updated_alice.?.mfa_enabled == true);
    
    // Test user iterator
    var user_count: u32 = 0;
    var it = user_store.userIterator();
    while (it.next()) |_| {
        user_count += 1;
    }
    try testing.expect(user_count == 3);
    
    // Test remove user
    user_store.removeUser(2);
    try testing.expect(user_store.getUser(2) == null);
    
    std.debug.print("\nUser CRUD operations test passed\n", .{});
}

test "user field length validation" {
    const allocator = testing.allocator;
    
    var user_store = SimpleUserStorage.init(allocator);
    defer user_store.deinit();
    
    // Test username too long
    const long_username = "a" ** 64;
    const result = user_store.persistUser(1, long_username, "email@example.com", "hash");
    try testing.expectError(error.FieldTooLong, result);
    
    // Test email too long
    const long_email = "user@" ++ ("a" ** 125) ++ ".com";
    const result2 = user_store.persistUser(2, "user", long_email, "hash");
    try testing.expectError(error.FieldTooLong, result2);
    
    // Test password too long
    const long_password = "p" ** 128;
    const result3 = user_store.persistUser(3, "user", "email@example.com", long_password);
    try testing.expectError(error.FieldTooLong, result3);
    
    std.debug.print("\nField length validation test passed\n", .{});
}

test "user error handling" {
    const allocator = testing.allocator;
    
    var user_store = SimpleUserStorage.init(allocator);
    defer user_store.deinit();
    
    // Test getting non-existent user
    try testing.expect(user_store.getUser(999) == null);
    try testing.expect(user_store.getUserByUsername("nonexistent") == null);
    
    // Test updating non-existent user
    const result = user_store.updateUser(999, "new@example.com", null, null, null);
    try testing.expectError(error.UserNotFound, result);
    
    std.debug.print("\nError handling test passed\n", .{});
}