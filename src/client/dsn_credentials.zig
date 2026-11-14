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
//! SONNY-6550: these rules are geode-client-zig's `config.redact` (v0.3.17
//! took them from this file); the names below are that module's, so the
//! CLI, the REPL and the client library read and print a DSN with one
//! implementation. Its decoder checks the text before allocating and
//! allocates the result at its exact size, so no resized copy of a
//! credential is freed unzeroed.

const std = @import("std");
const redact = @import("geode_client_zig").config.redact;

pub const Error = redact.Error;
pub const Authority = redact.Authority;
pub const splitAuthority = redact.splitAuthority;
pub const schemeEnd = redact.schemeEnd;
pub const Credentials = redact.Credentials;
pub const decodeUserinfo = redact.decodeUserinfo;
pub const percentDecode = redact.percentDecode;
pub const redacted_marker = redact.redacted_marker;
pub const Redacted = redact.Redacted;
pub const redacted = redact.redacted;
pub const isSecretKey = redact.isSecretKey;

/// SONNY-6551: the credentials of a DSN's query parameters (docs/DSN.md,
/// "Query Parameter Credentials"): `username` or `user`, `password` or
/// `pass`, percent-decoded like the userinfo (`+` is a literal plus). The
/// last occurrence of a key wins. `deinit` zeroes them before freeing.
pub const QueryCredentials = struct {
    username: ?[]u8 = null,
    password: ?[]u8 = null,

    pub fn deinit(self: *QueryCredentials, allocator: std.mem.Allocator) void {
        freeSecret(allocator, self.username);
        freeSecret(allocator, self.password);
        self.* = .{};
    }
};

fn freeSecret(allocator: std.mem.Allocator, value: ?[]u8) void {
    if (value) |v| {
        std.crypto.secureZero(u8, v);
        allocator.free(v);
    }
}

/// Read the credential parameters of `rest` (`Authority.rest`: empty, or
/// starting with `/`, `?` or `#`); other parameters are skipped.
pub fn decodeQueryCredentials(allocator: std.mem.Allocator, rest: []const u8) Error!QueryCredentials {
    var out: QueryCredentials = .{};
    errdefer out.deinit(allocator);
    const q = std.mem.indexOfScalar(u8, rest, '?') orelse return out;
    const end = std.mem.indexOfScalarPos(u8, rest, q, '#') orelse rest.len;
    var params = std.mem.splitScalar(u8, rest[q + 1 .. end], '&');
    while (params.next()) |param| {
        const eq = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        const key = param[0..eq];
        const slot: *?[]u8 = if (std.mem.eql(u8, key, "username") or std.mem.eql(u8, key, "user"))
            &out.username
        else if (std.mem.eql(u8, key, "password") or std.mem.eql(u8, key, "pass"))
            &out.password
        else
            continue;
        const value = try percentDecode(allocator, param[eq + 1 ..]);
        freeSecret(allocator, slot.*);
        slot.* = value;
    }
    return out;
}
