//! AWS Signature Version 4 (SigV4) request signing.
//!
//! Implements the canonical-request -> string-to-sign -> HMAC-SHA256 signing
//! key chain (kSecret -> kDate -> kRegion -> kService -> kSigning) for
//! header-based (Authorization header) request signing, per the AWS
//! "Signature Version 4 signing process" specification. Replaces the legacy
//! SigV2 (HMAC-SHA1) signing previously used by `s3_backup.zig`
//! (SEC-S3-SIGV2-01).
//!
//! SigV4 is the current AWS requirement and is also supported by
//! S3-compatible services (DigitalOcean Spaces, MinIO, Ceph RGW), so the
//! existing endpoint/credential plumbing in `S3Config` keeps working.
//!
//! Verified against the published AWS documentation test vectors in
//! `tests/test_s3_sigv4.zig` (`zig build test-s3-sigv4`).
//
// CANARY: REQ=REQ-SEC-S3-SIGV4-001; FEATURE="S3 SigV4 Signing"; ASPECT=Crypto; STATUS=TESTED; TEST=tests/test_s3_sigv4.zig; OWNER=security; UPDATED=2026-06-10

const std = @import("std");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// SHA-256 of the empty string — the x-amz-content-sha256 value for
/// payload-less requests (GET/DELETE/POST-without-body).
pub const empty_payload_hash_hex = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

/// A request header to be included in the canonical (signed) header set.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// A query-string parameter (pre-encoding values are fine; they are
/// RFC 3986 percent-encoded by `buildCanonicalQuery`).
pub const QueryParam = struct {
    name: []const u8,
    value: []const u8,
};

/// Everything needed to sign one request.
pub const SignInput = struct {
    /// HTTP method, uppercase ("GET", "PUT", "POST", ...).
    method: []const u8,
    /// URI-encoded absolute path ("/" for bucket root). Must already be
    /// encoded (see `uriEncodePath`).
    canonical_uri: []const u8 = "/",
    /// Canonical query string (sorted, encoded; see `buildCanonicalQuery`).
    /// Empty string when the request has no query.
    canonical_query: []const u8 = "",
    /// Headers to sign. MUST include Host, x-amz-date, and (for S3)
    /// x-amz-content-sha256. Names are lowercased and sorted internally.
    headers: []const Header,
    /// Lowercase hex SHA-256 of the request payload
    /// (`empty_payload_hash_hex` for no body).
    payload_hash_hex: []const u8,
    /// ISO 8601 basic timestamp "YYYYMMDDTHHMMSSZ" (see `formatAmzDate`).
    amz_date: []const u8,
    region: []const u8,
    service: []const u8 = "s3",
    access_key_id: []const u8,
    secret_access_key: []const u8,
};

/// Lowercase hex SHA-256 of a payload, for the x-amz-content-sha256 header.
pub fn hashPayloadHex(payload: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(payload, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Derive the SigV4 signing key:
/// kSigning = HMAC(HMAC(HMAC(HMAC("AWS4"+secret, date), region), service), "aws4_request")
pub fn signingKey(
    secret_access_key: []const u8,
    date_yyyymmdd: []const u8,
    region: []const u8,
    service: []const u8,
) [32]u8 {
    // Runtime-checked (not just debug-asserted): a >256-byte secret in a
    // ReleaseFast build must not overflow the stack buffer. Real AWS
    // secrets are 40 bytes; truncate-and-sign would produce a wrong
    // (rejected) signature rather than UB.
    var prefixed: [4 + 256]u8 = undefined;
    prefixed[0..4].* = "AWS4".*;
    const key_len = @min(secret_access_key.len, 256);
    std.debug.assert(secret_access_key.len == key_len); // surface misconfig in safe builds
    @memcpy(prefixed[4..][0..key_len], secret_access_key[0..key_len]);

    var k_date: [32]u8 = undefined;
    HmacSha256.create(&k_date, date_yyyymmdd, prefixed[0 .. 4 + key_len]);
    var k_region: [32]u8 = undefined;
    HmacSha256.create(&k_region, region, &k_date);
    var k_service: [32]u8 = undefined;
    HmacSha256.create(&k_service, service, &k_region);
    var k_signing: [32]u8 = undefined;
    HmacSha256.create(&k_signing, "aws4_request", &k_service);
    return k_signing;
}

/// Canonical header block + signed-headers list, both caller-owned.
pub const CanonicalHeaders = struct {
    /// "name1:value1\nname2:value2\n" — lowercase names, sorted, each line
    /// terminated by '\n'.
    canonical: []u8,
    /// "name1;name2" — lowercase, sorted, ';'-joined.
    signed: []u8,

    pub fn deinit(self: CanonicalHeaders, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical);
        allocator.free(self.signed);
    }
};

/// Lowercase, sort, and normalize the header set per the SigV4 spec
/// (values trimmed; sequential interior spaces collapsed to one).
pub fn canonicalizeHeaders(allocator: std.mem.Allocator, headers: []const Header) !CanonicalHeaders {
    const Entry = struct { name: []u8, value: []u8 };
    const entries = try allocator.alloc(Entry, headers.len);
    var initialized: usize = 0;
    defer {
        for (entries[0..initialized]) |e| {
            allocator.free(e.name);
            allocator.free(e.value);
        }
        allocator.free(entries);
    }
    for (headers, 0..) |h, i| {
        const name = try std.ascii.allocLowerString(allocator, h.name);
        errdefer allocator.free(name);
        const value = try normalizeHeaderValue(allocator, h.value);
        entries[i] = .{ .name = name, .value = value };
        initialized = i + 1;
    }

    std.mem.sort(Entry, entries, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    var canonical: std.ArrayList(u8) = .empty;
    errdefer canonical.deinit(allocator);
    var signed: std.ArrayList(u8) = .empty;
    errdefer signed.deinit(allocator);

    for (entries, 0..) |e, i| {
        try canonical.appendSlice(allocator, e.name);
        try canonical.append(allocator, ':');
        try canonical.appendSlice(allocator, e.value);
        try canonical.append(allocator, '\n');
        if (i != 0) try signed.append(allocator, ';');
        try signed.appendSlice(allocator, e.name);
    }

    const canonical_owned = try canonical.toOwnedSlice(allocator);
    errdefer allocator.free(canonical_owned);
    const signed_owned = try signed.toOwnedSlice(allocator);
    return .{ .canonical = canonical_owned, .signed = signed_owned };
}

/// Trim leading/trailing whitespace and collapse runs of interior spaces.
fn normalizeHeaderValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var prev_space = false;
    for (trimmed) |c| {
        const is_space = (c == ' ' or c == '\t');
        if (is_space) {
            if (!prev_space) try out.append(allocator, ' ');
        } else {
            try out.append(allocator, c);
        }
        prev_space = is_space;
    }
    return out.toOwnedSlice(allocator);
}

/// Build the canonical request:
///   Method \n CanonicalURI \n CanonicalQuery \n CanonicalHeaders \n
///   SignedHeaders \n HashedPayload
pub fn buildCanonicalRequest(allocator: std.mem.Allocator, in: SignInput) ![]u8 {
    const ch = try canonicalizeHeaders(allocator, in.headers);
    defer ch.deinit(allocator);
    // ch.canonical already ends with '\n'; the extra '\n' below produces the
    // required blank line between the header block and the signed list.
    return std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{
        in.method,
        in.canonical_uri,
        in.canonical_query,
        ch.canonical,
        ch.signed,
        in.payload_hash_hex,
    });
}

/// Build the string to sign:
///   AWS4-HMAC-SHA256 \n amz-date \n date/region/service/aws4_request \n
///   hex(sha256(canonical_request))
pub fn buildStringToSign(allocator: std.mem.Allocator, in: SignInput, canonical_request: []const u8) ![]u8 {
    std.debug.assert(in.amz_date.len >= 8);
    var cr_hash: [32]u8 = undefined;
    Sha256.hash(canonical_request, &cr_hash, .{});
    const cr_hex = std.fmt.bytesToHex(cr_hash, .lower);
    return std.fmt.allocPrint(allocator, "AWS4-HMAC-SHA256\n{s}\n{s}/{s}/{s}/aws4_request\n{s}", .{
        in.amz_date,
        in.amz_date[0..8],
        in.region,
        in.service,
        &cr_hex,
    });
}

/// Compute the final lowercase-hex request signature.
pub fn signatureHex(allocator: std.mem.Allocator, in: SignInput) ![64]u8 {
    const cr = try buildCanonicalRequest(allocator, in);
    defer allocator.free(cr);
    const sts = try buildStringToSign(allocator, in, cr);
    defer allocator.free(sts);

    const key = signingKey(in.secret_access_key, in.amz_date[0..8], in.region, in.service);
    var mac: [32]u8 = undefined;
    HmacSha256.create(&mac, sts, &key);
    return std.fmt.bytesToHex(mac, .lower);
}

/// Build the full `Authorization` header value (header-based signing):
///   AWS4-HMAC-SHA256 Credential=AK/date/region/service/aws4_request,
///   SignedHeaders=...,Signature=...
pub fn authorizationHeader(allocator: std.mem.Allocator, in: SignInput) ![]u8 {
    const sig = try signatureHex(allocator, in);
    const ch = try canonicalizeHeaders(allocator, in.headers);
    defer ch.deinit(allocator);
    return std.fmt.allocPrint(
        allocator,
        "AWS4-HMAC-SHA256 Credential={s}/{s}/{s}/{s}/aws4_request,SignedHeaders={s},Signature={s}",
        .{ in.access_key_id, in.amz_date[0..8], in.region, in.service, ch.signed, &sig },
    );
}

/// Format an epoch-seconds timestamp as the SigV4 "YYYYMMDDTHHMMSSZ" form
/// used for both the x-amz-date header and the credential-scope date.
pub fn formatAmzDate(epoch_seconds: u64) [16]u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();
    var out: [16]u8 = undefined;
    // error-policy: D — the amz-date format is exactly 16 bytes
    // (YYYYMMDD'T'HHMMSS'Z') for any 4-digit year; out is [16]u8.
    _ = std.fmt.bufPrint(&out, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch unreachable;
    return out;
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
}

const hex_upper = "0123456789ABCDEF";

fn appendEncoded(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8, keep_slash: bool) !void {
    for (s) |c| {
        if (isUnreserved(c) or (keep_slash and c == '/')) {
            try out.append(allocator, c);
        } else {
            try out.appendSlice(allocator, &[3]u8{ '%', hex_upper[c >> 4], hex_upper[c & 0xF] });
        }
    }
}

/// RFC 3986 percent-encode a URI path, preserving '/' segment separators.
pub fn uriEncodePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendEncoded(&out, allocator, path, true);
    return out.toOwnedSlice(allocator);
}

/// Build the canonical query string: parameters percent-encoded, sorted by
/// encoded name (then value), joined "name=value" with '&'. Parameters with
/// empty values keep a trailing '=' (e.g. "uploads=").
pub fn buildCanonicalQuery(allocator: std.mem.Allocator, params: []const QueryParam) ![]u8 {
    if (params.len == 0) return allocator.alloc(u8, 0);

    const Encoded = struct { name: []u8, value: []u8 };
    const encoded = try allocator.alloc(Encoded, params.len);
    var initialized: usize = 0;
    defer {
        for (encoded[0..initialized]) |e| {
            allocator.free(e.name);
            allocator.free(e.value);
        }
        allocator.free(encoded);
    }
    for (params, 0..) |p, i| {
        var name_list: std.ArrayList(u8) = .empty;
        errdefer name_list.deinit(allocator);
        try appendEncoded(&name_list, allocator, p.name, false);
        const name = try name_list.toOwnedSlice(allocator);
        errdefer allocator.free(name);

        var value_list: std.ArrayList(u8) = .empty;
        errdefer value_list.deinit(allocator);
        try appendEncoded(&value_list, allocator, p.value, false);
        const value = try value_list.toOwnedSlice(allocator);

        encoded[i] = .{ .name = name, .value = value };
        initialized = i + 1;
    }

    std.mem.sort(Encoded, encoded, {}, struct {
        fn lessThan(_: void, a: Encoded, b: Encoded) bool {
            if (std.mem.eql(u8, a.name, b.name)) return std.mem.lessThan(u8, a.value, b.value);
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (encoded, 0..) |e, i| {
        if (i != 0) try out.append(allocator, '&');
        try out.appendSlice(allocator, e.name);
        try out.append(allocator, '=');
        try out.appendSlice(allocator, e.value);
    }
    return out.toOwnedSlice(allocator);
}
