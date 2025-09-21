const std = @import("std");

// CANARY: REQ=REQ-GQL-050; FEATURE="Multi-Tenancy"; ASPECT=TenantRegistry; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_050_TenantRegistryBasic; OWNER=dist; UPDATED=2025-09-21

pub const TenantId = u64;

pub const TenantInfo = struct {
    id: TenantId,
    name: []const u8,
    created_at_ns: u64,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMap(TenantId, TenantInfo),
    next_id: TenantId,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator, .map = std.AutoHashMap(TenantId, TenantInfo).init(allocator), .next_id = 1 };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            _ = entry; // names are slices referencing original input (caller-owned or duped?)
        }
        self.map.deinit();
    }

    pub fn createTenant(self: *Registry, name: []const u8) !TenantInfo {
        // duplicate name for owned storage
        const dup = try self.allocator.dupe(u8, name);
        const info = TenantInfo{ .id = self.next_id, .name = dup, .created_at_ns = std.time.nanoTimestamp() };
        try self.map.put(info.id, info);
        self.next_id += 1;
        return info;
    }

    pub fn get(self: *Registry, id: TenantId) ?TenantInfo {
        if (self.map.get(id)) |info| return info;
        return null;
    }

    pub fn list(self: *Registry, allocator: std.mem.Allocator) ![]TenantInfo {
        var tmp_list = std.ArrayList(TenantInfo).init(allocator);
        var it = self.map.iterator();
        while (it.next()) |entry| {
            try tmp_list.append(entry.value_ptr.*);
        }
        return try tmp_list.toOwnedSlice();
    }
};
