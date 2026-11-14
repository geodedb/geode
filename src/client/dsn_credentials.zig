// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 CodePros
// CANARY: REQ=REQ-SONNY-6544-DSN-USERINFO; FEATURE="DSN credentials"; ASPECT=UserinfoAndRedaction; STATUS=TESTED; TEST=tests/test_sonny6544_dsn_redaction.zig; OWNER=cli; UPDATED=2026-11-14

//! SONNY-6544: the credentials in a DSN, and the one way an address or DSN
//! is printed.
//!
//! RFC 3986 §3.2: the authority runs from after `scheme://` to the first
//! `/`, `?` or `#`; its userinfo is everything before the LAST `@` of the
//! authority (a raw `@` in a password is therefore read correctly), and
//! splits into user and password at its FIRST `:` (a user name cannot hold
//! a raw `:`). Both are percent-decoded (§2.1): `%` must be followed by two
//! hex digits, and `+` is a literal plus.
//!
//! `redacted(text)` prints an address or DSN with its userinfo removed and
//! the value of every secret-looking query parameter (`pass=`,
//! `password=`, `token=`, ...) replaced by `***`. Every client-side place
//! that prints a server address or a DSN goes through it.
//!
//! The module depends only on std so every build module can compile it.

const std = @import("std");

pub const Error = error{
    /// A `%` not followed by two hex digits.
    InvalidPercentEncoding,
    /// An `@` after the authority: a credential holding an unencoded `/`,
    /// `?` or `#`, whose end cannot be found.
    UnencodedCredentialDelimiter,
    OutOfMemory,
};

pub const Authority = struct {
    /// Before the last `@` of the authority; null when it has none.
    userinfo: ?[]const u8,
    /// The authority after the userinfo: `host[:port]`.
    host_port: []const u8,
    /// Everything after the authority: empty, or starting with `/`, `?` or
    /// `#`.
    rest: []const u8,
};

/// Split `text` (a DSN without its `scheme://`) into userinfo, host:port and
/// the rest. `error.UnencodedCredentialDelimiter` when an `@` follows the
/// authority.
pub fn splitAuthority(text: []const u8) error{UnencodedCredentialDelimiter}!Authority {
    const end = std.mem.indexOfAny(u8, text, "/?#") orelse text.len;
    const authority = text[0..end];
    const rest = text[end..];
    if (std.mem.indexOfScalar(u8, rest, '@') != null) return error.UnencodedCredentialDelimiter;
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
        return .{ .userinfo = authority[0..at], .host_port = authority[at + 1 ..], .rest = rest };
    }
    return .{ .userinfo = null, .host_port = authority, .rest = rest };
}

/// A decoded user name and password; `deinit` zeroes them before freeing.
pub const Credentials = struct {
    username: []u8,
    password: ?[]u8,

    pub fn deinit(self: *Credentials, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, self.username);
        allocator.free(self.username);
        if (self.password) |p| {
            std.crypto.secureZero(u8, p);
            allocator.free(p);
        }
        self.* = undefined;
    }
};

/// Decode `userinfo` (`user[:password]`, percent-encoded).
pub fn decodeUserinfo(allocator: std.mem.Allocator, userinfo: []const u8) Error!Credentials {
    const colon = std.mem.indexOfScalar(u8, userinfo, ':');
    const user_text = if (colon) |c| userinfo[0..c] else userinfo;
    const username = try percentDecode(allocator, user_text);
    errdefer {
        std.crypto.secureZero(u8, username);
        allocator.free(username);
    }
    const password = if (colon) |c| try percentDecode(allocator, userinfo[c + 1 ..]) else null;
    return .{ .username = username, .password = password };
}

/// RFC 3986 §2.1 percent-decoding. The caller owns the result.
pub fn percentDecode(allocator: std.mem.Allocator, text: []const u8) Error![]u8 {
    const out = try allocator.alloc(u8, text.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '%') {
            out[n] = text[i];
            n += 1;
            i += 1;
            continue;
        }
        const hi = if (i + 1 < text.len) hexValue(text[i + 1]) else null;
        const lo = if (i + 2 < text.len) hexValue(text[i + 2]) else null;
        if (hi == null or lo == null) {
            std.crypto.secureZero(u8, out);
            allocator.free(out);
            return error.InvalidPercentEncoding;
        }
        out[n] = (hi.? << 4) | lo.?;
        n += 1;
        i += 3;
    }
    if (n == out.len) return out;
    const shrunk = allocator.realloc(out, n) catch {
        std.crypto.secureZero(u8, out);
        allocator.free(out);
        return error.OutOfMemory;
    };
    return shrunk;
}

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Printed instead of an address or DSN whose credentials cannot be told
/// apart from the rest of it.
pub const redacted_marker = "<address redacted>";

/// `{f}` formatter: `text` without credentials. See the module comment.
pub const Redacted = struct {
    text: []const u8,

    pub fn format(self: Redacted, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var text = self.text;
        if (std.mem.indexOf(u8, text, "://")) |sep| {
            if (std.mem.indexOfAny(u8, text[0..sep], "/?#@") == null) {
                try w.writeAll(text[0 .. sep + 3]);
                text = text[sep + 3 ..];
            }
        }
        const a = splitAuthority(text) catch return w.writeAll(redacted_marker);
        try w.writeAll(a.host_port);
        var rest = a.rest;
        const path_end = std.mem.indexOfAny(u8, rest, "?#") orelse rest.len;
        try w.writeAll(rest[0..path_end]);
        rest = rest[path_end..];
        if (rest.len == 0 or rest[0] != '?') return; // a fragment is not shown
        const query_end = std.mem.indexOfScalar(u8, rest, '#') orelse rest.len;
        try w.writeByte('?');
        var params = std.mem.splitScalar(u8, rest[1..query_end], '&');
        var first = true;
        while (params.next()) |param| {
            if (!first) try w.writeByte('&');
            first = false;
            const eq = std.mem.indexOfScalar(u8, param, '=') orelse {
                try w.writeAll(param);
                continue;
            };
            try w.writeAll(param[0 .. eq + 1]);
            try w.writeAll(if (isSecretKey(param[0..eq])) "***" else param[eq + 1 ..]);
        }
    }
};

/// `text` (an address, `host:port`, or a DSN) for printing: `{f}`.
pub fn redacted(text: []const u8) Redacted {
    return .{ .text = text };
}

/// A query parameter whose value is or may be a secret.
pub fn isSecretKey(key: []const u8) bool {
    const words = [_][]const u8{ "pass", "pwd", "secret", "token", "auth", "credential", "key", "session", "cookie", "signature" };
    for (words) |word| {
        if (std.ascii.findIgnoreCase(key, word) != null) return true;
    }
    return false;
}
