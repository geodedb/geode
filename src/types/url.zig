const std = @import("std");

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
        if (url_str.len == 0) return Error.InvalidUrl;

        var remaining = url_str;

        const scheme_end = std.mem.indexOf(u8, remaining, "://") orelse return Error.InvalidUrl;
        const scheme = try std.ascii.allocLowerString(allocator, remaining[0..scheme_end]);
        remaining = remaining[scheme_end + 3 ..];

        var authority_end = remaining.len;
        if (std.mem.indexOfAny(u8, remaining, "/?#")) |pos| {
            authority_end = pos;
        }

        const authority = remaining[0..authority_end];
        remaining = remaining[authority_end..];

        var host_str: []const u8 = authority;
        var port: ?u16 = null;

        if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon_pos| {
            const port_str = authority[colon_pos + 1 ..];
            port = std.fmt.parseInt(u16, port_str, 10) catch null;
            if (port != null) {
                host_str = authority[0..colon_pos];
            }
        }

        const host = try std.ascii.allocLowerString(allocator, host_str);

        if (isDefaultPort(scheme, port)) {
            port = null;
        }

        var path_str: []const u8 = "/";
        var query_str: ?[]const u8 = null;
        var fragment_str: ?[]const u8 = null;

        if (remaining.len > 0) {
            if (remaining[0] == '/') {
                var path_end = remaining.len;
                if (std.mem.indexOfAny(u8, remaining, "?#")) |pos| {
                    path_end = pos;
                }
                path_str = remaining[0..path_end];
                remaining = remaining[path_end..];
            }

            if (remaining.len > 0 and remaining[0] == '?') {
                var query_end = remaining.len;
                if (std.mem.indexOfScalar(u8, remaining, '#')) |pos| {
                    query_end = pos;
                }
                query_str = remaining[1..query_end];
                remaining = remaining[query_end..];
            }

            if (remaining.len > 0 and remaining[0] == '#') {
                fragment_str = remaining[1..];
            }
        }

        return Url{
            .scheme = scheme,
            .host = host,
            .port = port,
            .path = path_str,
            .query = query_str,
            .fragment = fragment_str,
        };
    }

    pub fn toString(self: Url, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        try std.fmt.format(result.writer(), "{s}://{s}", .{ self.scheme, self.host });

        if (self.port) |p| {
            try std.fmt.format(result.writer(), ":{d}", .{p});
        }

        try result.appendSlice(self.path);

        if (self.query) |q| {
            try std.fmt.format(result.writer(), "?{s}", .{q});
        }

        if (self.fragment) |f| {
            try std.fmt.format(result.writer(), "#{s}", .{f});
        }

        return result.toOwnedSlice();
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
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        try std.fmt.format(result.writer(), "{s}://{s}", .{ self.scheme, self.host });

        if (self.port) |p| {
            if (!isDefaultPort(self.scheme, p)) {
                try std.fmt.format(result.writer(), ":{d}", .{p});
            }
        }

        return result.toOwnedSlice();
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
        if (domain_str.len == 0 or domain_str.len > 253) return Error.InvalidDomain;

        var labels = std.ArrayList([]const u8).init(allocator);
        defer labels.deinit();

        var label_iter = std.mem.split(u8, domain_str, ".");
        while (label_iter.next()) |label| {
            if (label.len == 0 or label.len > 63) return Error.InvalidDomain;

            for (label) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '-') return Error.InvalidDomain;
            }

            if (label[0] == '-' or label[label.len - 1] == '-') return Error.InvalidDomain;

            const lower_label = try std.ascii.allocLowerString(allocator, label);
            try labels.append(lower_label);
        }

        return Domain{ .labels = try labels.toOwnedSlice() };
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

test "url normalization" {
    const allocator = std.testing.allocator;
    const url = try Url.fromString(allocator, "HTTP://ExAmple.com:80/a%2F?x=1#f");
    defer {
        allocator.free(url.scheme);
        allocator.free(url.host);
    }

    const normalized = try url.toString(allocator);
    defer allocator.free(normalized);

    std.testing.expectEqualSlices(u8, normalized, "http://example.com/a%2F?x=1#f") catch unreachable;
}

test "domain punycode" {
    const allocator = std.testing.allocator;
    const domain = try Domain.fromString(allocator, "xn--mnich-kva.example");
    defer domain.deinit(allocator);

    const domain_str = try domain.toString(allocator);
    defer allocator.free(domain_str);

    std.testing.expectEqualSlices(u8, domain_str, "xn--mnich-kva.example") catch unreachable;
}
