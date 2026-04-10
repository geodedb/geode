const std = @import("std");
const advanced_types = @import("advanced_types_lib");

pub const ExtUrl = advanced_types.Url;
pub const ExtDomain = advanced_types.Domain;
pub const DomainLabelIterator = advanced_types.url.DomainLabelIterator;

pub const Url = struct {
    scheme: []const u8,
    host: []const u8,
    port: ?u16,
    path: []const u8,
    query: ?[]const u8,
    fragment: ?[]const u8,

    pub const Error = error{
        InvalidUrl,
        OutOfMemory,
    };

    pub fn fromString(allocator: std.mem.Allocator, url_str: []const u8) Error!Url {
        const parsed = advanced_types.Url.parse(url_str) catch return Error.InvalidUrl;
        const scheme = try std.ascii.allocLowerString(allocator, parsed.scheme);
        errdefer allocator.free(scheme);
        const host = try std.ascii.allocLowerString(allocator, parsed.host);
        errdefer allocator.free(host);
        const path = try allocator.dupe(u8, parsed.path);
        errdefer allocator.free(path);
        const query = if (parsed.query) |q| try allocator.dupe(u8, q) else null;
        errdefer if (query) |q| allocator.free(q);
        const fragment = if (parsed.fragment) |f| try allocator.dupe(u8, f) else null;
        errdefer if (fragment) |f| allocator.free(f);

        return .{
            .scheme = scheme,
            .host = host,
            .port = if (isDefaultPort(scheme, parsed.port)) null else parsed.port,
            .path = path,
            .query = query,
            .fragment = fragment,
        };
    }

    pub fn toString(self: Url, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{f}", .{advanced_types.Url{
            .raw = "",
            .scheme = self.scheme,
            .host = self.host,
            .port = self.port,
            .path = self.path,
            .query = self.query,
            .fragment = self.fragment,
        }});
    }

    pub fn getScheme(self: Url) []const u8 {
        return self.scheme;
    }

    pub fn getHost(self: Url) []const u8 {
        return self.host;
    }

    pub fn getPath(self: Url) []const u8 {
        return self.path;
    }

    pub fn getQuery(self: Url) ?[]const u8 {
        return self.query;
    }

    pub fn getOrigin(self: Url, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).empty;
        defer result.deinit(allocator);

        try std.fmt.format(result.writer(allocator), "{s}://{s}", .{ self.scheme, self.host });
        if (self.port) |p| {
            if (!isDefaultPort(self.scheme, p)) {
                try std.fmt.format(result.writer(allocator), ":{d}", .{p});
            }
        }
        return result.toOwnedSlice(allocator);
    }

    fn isDefaultPort(scheme: []const u8, port: ?u16) bool {
        const p = port orelse return true;
        return (std.mem.eql(u8, scheme, "http") and p == 80) or
            (std.mem.eql(u8, scheme, "https") and p == 443) or
            (std.mem.eql(u8, scheme, "ftp") and p == 21);
    }
};

pub const Domain = struct {
    labels: [][]const u8,

    pub const Error = error{
        InvalidDomain,
        OutOfMemory,
    };

    pub fn fromString(allocator: std.mem.Allocator, domain_str: []const u8) Error!Domain {
        const parsed = advanced_types.Domain.parse(domain_str) catch return Error.InvalidDomain;

        var labels = std.ArrayList([]const u8).empty;
        defer labels.deinit(allocator);

        var iter = parsed.labels();
        while (iter.next()) |label| {
            try labels.append(allocator, try std.ascii.allocLowerString(allocator, label));
        }

        return .{ .labels = try labels.toOwnedSlice(allocator) };
    }

    pub fn toString(self: Domain, allocator: std.mem.Allocator) ![]u8 {
        return std.mem.join(allocator, ".", self.labels);
    }

    pub fn getLabels(self: Domain) [][]const u8 {
        return self.labels;
    }

    pub fn deinit(self: Domain, allocator: std.mem.Allocator) void {
        for (self.labels) |label| {
            allocator.free(label);
        }
        allocator.free(self.labels);
    }
};
