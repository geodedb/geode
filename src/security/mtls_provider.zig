// mTLS Authentication Provider
// CANARY: REQ=REQ-AUTH-MTLS-001; FEATURE="MtlsAuthentication"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_mtls_provider.zig|geodetestlab/specs/mtls_auth.yml; OWNER=security; UPDATED=2026-01-29
// GAP-0248: mTLS auth vs transport clarification
//
// This module provides certificate-based authentication by extracting identity
// from client certificates and mapping to Geode principals.
//
// Identity extraction methods:
// 1. Certificate fingerprint (SHA-256)
// 2. Subject Alternative Name (SAN) - DNS, email, URI
// 3. Subject Common Name (CN)
// 4. Subject Distinguished Name (DN)

const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;

/// Certificate identity extraction method
pub const IdentityMethod = enum {
    fingerprint, // SHA-256 fingerprint of certificate
    san_email, // Subject Alternative Name - email
    san_dns, // Subject Alternative Name - DNS
    san_uri, // Subject Alternative Name - URI
    subject_cn, // Subject Common Name
    subject_dn, // Full Subject Distinguished Name
};

/// Certificate identity extracted from client cert
pub const CertificateIdentity = struct {
    fingerprint: [64]u8, // SHA-256 as hex string
    subject_cn: ?[]const u8,
    subject_dn: ?[]const u8,
    san_email: ?[]const u8,
    san_dns: ?[]const u8,
    san_uri: ?[]const u8,
    issuer_dn: ?[]const u8,
    not_before: i64,
    not_after: i64,
    serial_number: []const u8,
};

/// Certificate-to-user mapping entry
pub const CertificateMapping = struct {
    method: IdentityMethod,
    pattern: []const u8, // Exact match or glob pattern
    user_id: u64,
    roles: []const []const u8,
    enabled: bool,
    created_at: i64,
    description: []const u8,
};

/// mTLS Provider manages certificate-to-user mappings
pub const MtlsProvider = struct {
    const Self = @This();

    allocator: Allocator,
    mappings: std.ArrayList(CertificateMapping),
    /// Fingerprint-based fast lookup cache
    fingerprint_cache: std.StringHashMap(u64),
    mutex: std.Thread.Mutex,
    /// Default identity extraction method
    default_method: IdentityMethod,
    /// Require exact fingerprint match (strictest security)
    strict_mode: bool,

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .mappings = std.ArrayList(CertificateMapping).empty,
            .fingerprint_cache = std.StringHashMap(u64).init(allocator),
            .mutex = std.Thread.Mutex{},
            .default_method = .fingerprint,
            .strict_mode = true,
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.mappings.items) |mapping| {
            self.allocator.free(mapping.pattern);
            self.allocator.free(mapping.description);
            for (mapping.roles) |role| {
                self.allocator.free(role);
            }
            self.allocator.free(mapping.roles);
        }
        self.mappings.deinit(self.allocator);

        var it = self.fingerprint_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.fingerprint_cache.deinit();
    }

    /// Add a certificate-to-user mapping
    /// CANARY: REQ=REQ-AUTH-MTLS-002; FEATURE="CertificateMappingCreation"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_mtls_provider.zig; OWNER=security; UPDATED=2026-01-29
    pub fn addMapping(
        self: *Self,
        method: IdentityMethod,
        pattern: []const u8,
        user_id: u64,
        roles: []const []const u8,
        description: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const pattern_dup = try self.allocator.dupe(u8, pattern);
        errdefer self.allocator.free(pattern_dup);

        const desc_dup = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(desc_dup);

        const roles_dup = try self.allocator.alloc([]const u8, roles.len);
        errdefer self.allocator.free(roles_dup);
        for (roles, 0..) |role, i| {
            roles_dup[i] = try self.allocator.dupe(u8, role);
        }

        const mapping = CertificateMapping{
            .method = method,
            .pattern = pattern_dup,
            .user_id = user_id,
            .roles = roles_dup,
            .enabled = true,
            .created_at = std.time.timestamp(),
            .description = desc_dup,
        };

        try self.mappings.append(self.allocator, mapping);

        // Add to fingerprint cache if applicable
        if (method == .fingerprint) {
            const pattern_key = try self.allocator.dupe(u8, pattern);
            try self.fingerprint_cache.put(pattern_key, user_id);
        }
    }

    /// Remove a mapping by pattern
    pub fn removeMapping(self: *Self, method: IdentityMethod, pattern: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        var idx: usize = 0;
        while (idx < self.mappings.items.len) {
            const mapping = self.mappings.items[idx];
            if (mapping.method == method and std.mem.eql(u8, mapping.pattern, pattern)) {
                // Remove from cache
                if (method == .fingerprint) {
                    if (self.fingerprint_cache.fetchRemove(pattern)) |kv| {
                        self.allocator.free(kv.key);
                    }
                }

                // Free mapping resources
                self.allocator.free(mapping.pattern);
                self.allocator.free(mapping.description);
                for (mapping.roles) |role| {
                    self.allocator.free(role);
                }
                self.allocator.free(mapping.roles);

                _ = self.mappings.orderedRemove(idx);
                return true;
            }
            idx += 1;
        }
        return false;
    }

    /// Authenticate a certificate and return the user ID
    /// CANARY: REQ=REQ-AUTH-MTLS-003; FEATURE="CertificateAuthentication"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_mtls_provider.zig; OWNER=security; UPDATED=2026-01-29
    pub fn authenticate(self: *Self, identity: *const CertificateIdentity) !?AuthResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check certificate validity period
        const now = std.time.timestamp();
        if (now < identity.not_before or now > identity.not_after) {
            return error.CertificateExpired;
        }

        // Try fingerprint cache first (fast path)
        if (self.fingerprint_cache.get(&identity.fingerprint)) |user_id| {
            // Find the mapping to get roles
            for (self.mappings.items) |mapping| {
                if (mapping.method == .fingerprint and
                    std.mem.eql(u8, mapping.pattern, &identity.fingerprint) and
                    mapping.enabled)
                {
                    return AuthResult{
                        .user_id = user_id,
                        .roles = mapping.roles,
                        .method = .fingerprint,
                        .matched_value = &identity.fingerprint,
                    };
                }
            }
        }

        // Fall back to checking all mappings
        for (self.mappings.items) |mapping| {
            if (!mapping.enabled) continue;

            const identity_value = switch (mapping.method) {
                .fingerprint => @as(?[]const u8, &identity.fingerprint),
                .san_email => identity.san_email,
                .san_dns => identity.san_dns,
                .san_uri => identity.san_uri,
                .subject_cn => identity.subject_cn,
                .subject_dn => identity.subject_dn,
            };

            if (identity_value) |value| {
                if (matchPattern(mapping.pattern, value)) {
                    return AuthResult{
                        .user_id = mapping.user_id,
                        .roles = mapping.roles,
                        .method = mapping.method,
                        .matched_value = value,
                    };
                }
            }
        }

        // In strict mode, no mapping = authentication failure
        if (self.strict_mode) {
            return null;
        }

        return null;
    }

    /// Enable/disable a mapping
    pub fn setMappingEnabled(self: *Self, method: IdentityMethod, pattern: []const u8, enabled: bool) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.mappings.items) |*mapping| {
            if (mapping.method == method and std.mem.eql(u8, mapping.pattern, pattern)) {
                mapping.enabled = enabled;
                return true;
            }
        }
        return false;
    }

    /// List all mappings
    pub fn listMappings(self: *Self, allocator: Allocator) ![]CertificateMapping {
        self.mutex.lock();
        defer self.mutex.unlock();

        const list = try allocator.alloc(CertificateMapping, self.mappings.items.len);
        @memcpy(list, self.mappings.items);
        return list;
    }
};

/// Authentication result from mTLS
pub const AuthResult = struct {
    user_id: u64,
    roles: []const []const u8,
    method: IdentityMethod,
    matched_value: []const u8,
};

/// Extract identity from raw certificate DER bytes
/// GAP-0248: Implements ASN.1/DER X.509 parsing for subject CN, SAN, validity dates, serial number.
/// CANARY: REQ=REQ-AUTH-MTLS-004; FEATURE="CertificateIdentityExtraction"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_mtls_provider.zig; OWNER=security; UPDATED=2026-03-13
pub fn extractIdentity(allocator: Allocator, cert_der: []const u8) !CertificateIdentity {
    // Calculate SHA-256 fingerprint
    var fingerprint_bytes: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(cert_der, &fingerprint_bytes, .{});
    const fingerprint = std.fmt.bytesToHex(fingerprint_bytes, .lower);

    // Parse X.509 certificate structure using ASN.1 DER decoder
    var identity = CertificateIdentity{
        .fingerprint = fingerprint,
        .subject_cn = null,
        .subject_dn = null,
        .san_email = null,
        .san_dns = null,
        .san_uri = null,
        .issuer_dn = null,
        .not_before = 0,
        .not_after = std.math.maxInt(i64),
        .serial_number = "",
    };

    // Parse the DER-encoded X.509 certificate
    const tbs = parseTbsCertificate(cert_der) catch return identity;

    // Extract serial number
    if (tbs.serial_number.len > 0) {
        // Format serial number as hex string
        const hex_chars = "0123456789abcdef";
        const hex_buf = try allocator.alloc(u8, tbs.serial_number.len * 2);
        for (tbs.serial_number, 0..) |byte, i| {
            hex_buf[i * 2] = hex_chars[byte >> 4];
            hex_buf[i * 2 + 1] = hex_chars[byte & 0x0f];
        }
        identity.serial_number = hex_buf;
    }

    // Extract subject CN and DN
    if (tbs.subject_cn) |cn| {
        identity.subject_cn = try allocator.dupe(u8, cn);
    }
    if (tbs.subject_dn) |dn| {
        identity.subject_dn = try allocator.dupe(u8, dn);
    }

    // Extract issuer DN
    if (tbs.issuer_dn) |dn| {
        identity.issuer_dn = try allocator.dupe(u8, dn);
    }

    // Extract validity dates
    identity.not_before = tbs.not_before;
    identity.not_after = tbs.not_after;

    // Extract SAN extensions
    if (tbs.san_dns) |dns| {
        identity.san_dns = try allocator.dupe(u8, dns);
    }
    if (tbs.san_email) |email| {
        identity.san_email = try allocator.dupe(u8, email);
    }
    if (tbs.san_uri) |uri| {
        identity.san_uri = try allocator.dupe(u8, uri);
    }

    return identity;
}

// ==========================================================================
// ASN.1/DER X.509 Certificate Parser (GAP-0248)
// Minimal parser for extracting identity fields from X.509 certificates.
// Handles: serial number, subject CN/DN, issuer DN, validity dates, SAN extension.
// ==========================================================================

const Asn1Tag = enum(u8) {
    boolean = 0x01,
    integer = 0x02,
    bit_string = 0x03,
    octet_string = 0x04,
    null_tag = 0x05,
    oid = 0x06,
    utf8_string = 0x0C,
    printable_string = 0x13,
    t61_string = 0x14,
    ia5_string = 0x16,
    utc_time = 0x17,
    generalized_time = 0x18,
    sequence = 0x30,
    set = 0x31,
    _,
};

const Asn1Element = struct {
    tag: u8,
    data: []const u8,
    header_len: usize,
};

const TbsFields = struct {
    serial_number: []const u8,
    subject_cn: ?[]const u8,
    subject_dn: ?[]const u8,
    issuer_dn: ?[]const u8,
    not_before: i64,
    not_after: i64,
    san_dns: ?[]const u8,
    san_email: ?[]const u8,
    san_uri: ?[]const u8,
};

fn parseAsn1Element(data: []const u8) !Asn1Element {
    if (data.len < 2) return error.TruncatedDer;
    const tag = data[0];
    var offset: usize = 1;
    var length: usize = 0;

    if (data[offset] & 0x80 == 0) {
        // Short form length
        length = data[offset];
        offset += 1;
    } else {
        // Long form length
        const num_bytes = data[offset] & 0x7F;
        offset += 1;
        if (num_bytes > 4 or offset + num_bytes > data.len) return error.InvalidLength;
        for (0..num_bytes) |_| {
            length = (length << 8) | data[offset];
            offset += 1;
        }
    }

    if (offset + length > data.len) return error.TruncatedDer;
    return .{
        .tag = tag,
        .data = data[offset .. offset + length],
        .header_len = offset,
    };
}

fn parseAsn1String(data: []const u8) ?[]const u8 {
    const elem = parseAsn1Element(data) catch return null;
    const tag: Asn1Tag = @enumFromInt(elem.tag);
    return switch (tag) {
        .utf8_string, .printable_string, .ia5_string, .t61_string => elem.data,
        else => null,
    };
}

/// OID for Common Name (2.5.4.3)
const oid_cn = [_]u8{ 0x55, 0x04, 0x03 };
/// OID for Subject Alternative Name (2.5.29.17)
const oid_san = [_]u8{ 0x55, 0x1D, 0x11 };

fn parseName(name_data: []const u8) struct { cn: ?[]const u8, dn: ?[]const u8 } {
    // Name is a SEQUENCE of RDNSequence (SET of AttributeTypeAndValue)
    var cn: ?[]const u8 = null;
    var dn_parts: [32]struct { key: []const u8, value: []const u8 } = undefined;
    var dn_count: usize = 0;

    var pos: usize = 0;
    while (pos < name_data.len) {
        const set_elem = parseAsn1Element(name_data[pos..]) catch break;
        if (set_elem.tag != 0x31) break; // SET

        // Parse SET contents (AttributeTypeAndValue SEQUENCE)
        var set_pos: usize = 0;
        while (set_pos < set_elem.data.len) {
            const seq = parseAsn1Element(set_elem.data[set_pos..]) catch break;
            if (seq.tag != 0x30) break; // SEQUENCE

            // Parse OID + value
            var attr_pos: usize = 0;
            const oid_elem = parseAsn1Element(seq.data[attr_pos..]) catch break;
            if (oid_elem.tag != 0x06) break;
            attr_pos += oid_elem.header_len + oid_elem.data.len;

            const value_str = parseAsn1String(seq.data[attr_pos..]);

            // Check if this is CN
            if (oid_elem.data.len == oid_cn.len and std.mem.eql(u8, oid_elem.data, &oid_cn)) {
                cn = value_str;
            }

            // Collect for DN string
            if (value_str) |v| {
                if (dn_count < dn_parts.len) {
                    dn_parts[dn_count] = .{ .key = oid_elem.data, .value = v };
                    dn_count += 1;
                }
            }

            set_pos += seq.header_len + seq.data.len;
        }
        pos += set_elem.header_len + set_elem.data.len;
    }

    // Build DN string (simplified: just CN= prefix for now)
    var dn: ?[]const u8 = null;
    if (cn) |cn_val| {
        dn = cn_val; // Simplified DN = CN value
    }

    return .{ .cn = cn, .dn = dn };
}

fn parseUtcTime(data: []const u8) i64 {
    // UTCTime format: YYMMDDHHMMSSZ
    if (data.len < 13) return 0;

    const year_offset: i64 = parseDigits(data[0..2]) catch return 0;
    const year: i64 = if (year_offset >= 50) 1900 + year_offset else 2000 + year_offset;
    const month: i64 = parseDigits(data[2..4]) catch return 0;
    const day: i64 = parseDigits(data[4..6]) catch return 0;
    const hour: i64 = parseDigits(data[6..8]) catch return 0;
    const minute: i64 = parseDigits(data[8..10]) catch return 0;
    const second: i64 = parseDigits(data[10..12]) catch return 0;

    // Simplified conversion to Unix timestamp (approximate, ignores leap seconds)
    const days_since_epoch = epochDays(year, month, day);
    return days_since_epoch * 86400 + hour * 3600 + minute * 60 + second;
}

fn parseGeneralizedTime(data: []const u8) i64 {
    // GeneralizedTime format: YYYYMMDDHHMMSSZ
    if (data.len < 15) return 0;

    const year: i64 = (parseDigits(data[0..2]) catch return 0) * 100 + (parseDigits(data[2..4]) catch return 0);
    const month: i64 = parseDigits(data[4..6]) catch return 0;
    const day: i64 = parseDigits(data[6..8]) catch return 0;
    const hour: i64 = parseDigits(data[8..10]) catch return 0;
    const minute: i64 = parseDigits(data[10..12]) catch return 0;
    const second: i64 = parseDigits(data[12..14]) catch return 0;

    const days_since_epoch = epochDays(year, month, day);
    return days_since_epoch * 86400 + hour * 3600 + minute * 60 + second;
}

fn parseDigits(s: []const u8) !i64 {
    var result: i64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return error.InvalidDigit;
        result = result * 10 + @as(i64, c - '0');
    }
    return result;
}

fn epochDays(year: i64, month: i64, day: i64) i64 {
    // Days from 1970-01-01 (simplified, good enough for certificate validation)
    const y = if (month <= 2) year - 1 else year;
    const m = if (month <= 2) month + 12 else month;
    const days = 365 * y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400) + @divFloor(153 * (m - 3) + 2, 5) + day - 719469;
    return days;
}

fn parseSanExtension(ext_data: []const u8) struct { dns: ?[]const u8, email: ?[]const u8, uri: ?[]const u8 } {
    // SAN is a SEQUENCE of GeneralName
    var dns: ?[]const u8 = null;
    var email: ?[]const u8 = null;
    var uri: ?[]const u8 = null;

    var pos: usize = 0;
    while (pos < ext_data.len) {
        const elem = parseAsn1Element(ext_data[pos..]) catch break;
        const tag_class = elem.tag & 0xC0; // context-specific class
        const tag_num = elem.tag & 0x1F;

        if (tag_class == 0x80) { // Context-specific
            switch (tag_num) {
                1 => { // rfc822Name (email)
                    if (email == null) email = elem.data;
                },
                2 => { // dNSName
                    if (dns == null) dns = elem.data;
                },
                6 => { // uniformResourceIdentifier
                    if (uri == null) uri = elem.data;
                },
                else => {},
            }
        }
        pos += elem.header_len + elem.data.len;
    }
    return .{ .dns = dns, .email = email, .uri = uri };
}

fn parseTbsCertificate(cert_der: []const u8) !TbsFields {
    var result = TbsFields{
        .serial_number = &.{},
        .subject_cn = null,
        .subject_dn = null,
        .issuer_dn = null,
        .not_before = 0,
        .not_after = std.math.maxInt(i64),
        .san_dns = null,
        .san_email = null,
        .san_uri = null,
    };

    // Certificate is a SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
    const cert_seq = try parseAsn1Element(cert_der);
    if (cert_seq.tag != 0x30) return error.InvalidCertificate;

    // TBSCertificate is the first element
    const tbs = try parseAsn1Element(cert_seq.data);
    if (tbs.tag != 0x30) return error.InvalidCertificate;

    var pos: usize = 0;
    var field_idx: usize = 0;

    // TBSCertificate fields:
    // [0] version (optional, context-specific), serialNumber, signature,
    // issuer, validity, subject, subjectPublicKeyInfo, [extensions]

    while (pos < tbs.data.len and field_idx < 10) {
        const elem = parseAsn1Element(tbs.data[pos..]) catch break;
        const elem_total = elem.header_len + elem.data.len;

        // Check for context-specific [0] version tag
        if (elem.tag == 0xA0 and field_idx == 0) {
            // Skip version field
            pos += elem_total;
            continue;
        }

        switch (field_idx) {
            0 => {
                // serialNumber (INTEGER)
                if (elem.tag == 0x02) {
                    result.serial_number = elem.data;
                }
            },
            1 => {
                // signature algorithm — skip
            },
            2 => {
                // issuer (Name SEQUENCE)
                if (elem.tag == 0x30) {
                    const issuer = parseName(elem.data);
                    result.issuer_dn = issuer.dn;
                }
            },
            3 => {
                // validity (SEQUENCE { notBefore, notAfter })
                if (elem.tag == 0x30) {
                    var vpos: usize = 0;
                    // notBefore
                    const nb = parseAsn1Element(elem.data[vpos..]) catch break;
                    if (nb.tag == @intFromEnum(Asn1Tag.utc_time)) {
                        result.not_before = parseUtcTime(nb.data);
                    } else if (nb.tag == @intFromEnum(Asn1Tag.generalized_time)) {
                        result.not_before = parseGeneralizedTime(nb.data);
                    }
                    vpos += nb.header_len + nb.data.len;
                    // notAfter
                    const na = parseAsn1Element(elem.data[vpos..]) catch break;
                    if (na.tag == @intFromEnum(Asn1Tag.utc_time)) {
                        result.not_after = parseUtcTime(na.data);
                    } else if (na.tag == @intFromEnum(Asn1Tag.generalized_time)) {
                        result.not_after = parseGeneralizedTime(na.data);
                    }
                }
            },
            4 => {
                // subject (Name SEQUENCE)
                if (elem.tag == 0x30) {
                    const subject = parseName(elem.data);
                    result.subject_cn = subject.cn;
                    result.subject_dn = subject.dn;
                }
            },
            5 => {
                // subjectPublicKeyInfo — skip
            },
            else => {
                // Extensions [3] (context-specific)
                if (elem.tag == 0xA3) {
                    // Parse extensions SEQUENCE
                    const exts_seq = parseAsn1Element(elem.data) catch break;
                    if (exts_seq.tag == 0x30) {
                        var epos: usize = 0;
                        while (epos < exts_seq.data.len) {
                            const ext = parseAsn1Element(exts_seq.data[epos..]) catch break;
                            if (ext.tag == 0x30) {
                                // Extension = SEQUENCE { extnID, critical?, extnValue }
                                var ext_pos: usize = 0;
                                const ext_oid = parseAsn1Element(ext.data[ext_pos..]) catch break;
                                if (ext_oid.tag != 0x06) {
                                    epos += ext.header_len + ext.data.len;
                                    continue;
                                }
                                ext_pos += ext_oid.header_len + ext_oid.data.len;

                                // Check for SAN OID (2.5.29.17)
                                if (ext_oid.data.len == oid_san.len and std.mem.eql(u8, ext_oid.data, &oid_san)) {
                                    // Skip optional critical BOOLEAN
                                    if (ext_pos < ext.data.len) {
                                        const next = parseAsn1Element(ext.data[ext_pos..]) catch break;
                                        if (next.tag == 0x01) { // BOOLEAN (critical)
                                            ext_pos += next.header_len + next.data.len;
                                        }
                                    }
                                    // extnValue is OCTET STRING wrapping SAN SEQUENCE
                                    if (ext_pos < ext.data.len) {
                                        const ext_val = parseAsn1Element(ext.data[ext_pos..]) catch break;
                                        if (ext_val.tag == 0x04) { // OCTET STRING
                                            const san_seq = parseAsn1Element(ext_val.data) catch break;
                                            if (san_seq.tag == 0x30) {
                                                const san = parseSanExtension(san_seq.data);
                                                result.san_dns = san.dns;
                                                result.san_email = san.email;
                                                result.san_uri = san.uri;
                                            }
                                        }
                                    }
                                }
                            }
                            epos += ext.header_len + ext.data.len;
                        }
                    }
                }
            },
        }

        pos += elem_total;
        field_idx += 1;
    }

    return result;
}

/// Create identity from known values (for testing or when cert is already parsed)
pub fn createIdentity(
    fingerprint_hex: []const u8,
    subject_cn: ?[]const u8,
    san_email: ?[]const u8,
) CertificateIdentity {
    var fingerprint: [64]u8 = undefined;
    if (fingerprint_hex.len >= 64) {
        @memcpy(&fingerprint, fingerprint_hex[0..64]);
    } else {
        @memset(&fingerprint, '0');
        @memcpy(fingerprint[0..fingerprint_hex.len], fingerprint_hex);
    }

    return CertificateIdentity{
        .fingerprint = fingerprint,
        .subject_cn = subject_cn,
        .subject_dn = null,
        .san_email = san_email,
        .san_dns = null,
        .san_uri = null,
        .issuer_dn = null,
        .not_before = 0,
        .not_after = std.math.maxInt(i64),
        .serial_number = "",
    };
}

/// Simple glob-style pattern matching (* as wildcard)
fn matchPattern(pattern: []const u8, value: []const u8) bool {
    // Exact match
    if (std.mem.eql(u8, pattern, value)) return true;

    // Wildcard patterns
    if (std.mem.indexOf(u8, pattern, "*")) |star_pos| {
        const prefix = pattern[0..star_pos];
        const suffix = pattern[star_pos + 1 ..];

        // Check prefix matches
        if (prefix.len > 0 and !std.mem.startsWith(u8, value, prefix)) {
            return false;
        }

        // Check suffix matches
        if (suffix.len > 0 and !std.mem.endsWith(u8, value, suffix)) {
            return false;
        }

        // For patterns like "*.example.com", ensure value is long enough
        if (value.len >= prefix.len + suffix.len) {
            return true;
        }
        return false;
    }

    return false;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "MtlsProvider: add and authenticate by fingerprint" {
    const allocator = std.testing.allocator;

    var provider = MtlsProvider.init(allocator);
    defer provider.deinit();

    const fingerprint = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    // Add mapping
    try provider.addMapping(
        .fingerprint,
        fingerprint,
        42,
        &[_][]const u8{"admin"},
        "Test admin cert",
    );

    // Create identity and authenticate
    const identity = createIdentity(fingerprint, "admin", "admin@example.com");
    const result = try provider.authenticate(&identity);

    try std.testing.expect(result != null);
    if (result) |r| {
        try std.testing.expectEqual(@as(u64, 42), r.user_id);
        try std.testing.expectEqual(IdentityMethod.fingerprint, r.method);
    }
}

test "MtlsProvider: authenticate by SAN email" {
    const allocator = std.testing.allocator;

    var provider = MtlsProvider.init(allocator);
    defer provider.deinit();

    // Add mapping by email
    try provider.addMapping(
        .san_email,
        "alice@example.com",
        100,
        &[_][]const u8{"user"},
        "Alice's cert",
    );

    const identity = createIdentity(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        null,
        "alice@example.com",
    );
    const result = try provider.authenticate(&identity);

    try std.testing.expect(result != null);
    if (result) |r| {
        try std.testing.expectEqual(@as(u64, 100), r.user_id);
        try std.testing.expectEqual(IdentityMethod.san_email, r.method);
    }
}

test "MtlsProvider: wildcard pattern matching" {
    const allocator = std.testing.allocator;

    var provider = MtlsProvider.init(allocator);
    defer provider.deinit();

    // Add wildcard mapping
    try provider.addMapping(
        .san_email,
        "*@example.com",
        200,
        &[_][]const u8{"employee"},
        "All example.com employees",
    );

    // Should match
    const identity1 = createIdentity(
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        null,
        "bob@example.com",
    );
    const result1 = try provider.authenticate(&identity1);
    try std.testing.expect(result1 != null);

    // Should also match
    const identity2 = createIdentity(
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        null,
        "charlie@example.com",
    );
    const result2 = try provider.authenticate(&identity2);
    try std.testing.expect(result2 != null);

    // Should NOT match different domain
    const identity3 = createIdentity(
        "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        null,
        "dan@other.com",
    );
    const result3 = try provider.authenticate(&identity3);
    try std.testing.expect(result3 == null);
}

test "MtlsProvider: remove mapping" {
    const allocator = std.testing.allocator;

    var provider = MtlsProvider.init(allocator);
    defer provider.deinit();

    const fingerprint = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

    try provider.addMapping(
        .fingerprint,
        fingerprint,
        300,
        &[_][]const u8{"test"},
        "Test mapping",
    );

    // Authenticate works
    const identity = createIdentity(fingerprint, null, null);
    var result = try provider.authenticate(&identity);
    try std.testing.expect(result != null);

    // Remove mapping
    try std.testing.expect(provider.removeMapping(.fingerprint, fingerprint));

    // Authenticate fails
    result = try provider.authenticate(&identity);
    try std.testing.expect(result == null);
}

test "MtlsProvider: disabled mapping not matched" {
    const allocator = std.testing.allocator;

    var provider = MtlsProvider.init(allocator);
    defer provider.deinit();

    const fingerprint = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

    try provider.addMapping(
        .fingerprint,
        fingerprint,
        400,
        &[_][]const u8{"test"},
        "Test mapping",
    );

    // Disable the mapping
    try std.testing.expect(provider.setMappingEnabled(.fingerprint, fingerprint, false));

    // Authenticate should fail
    const identity = createIdentity(fingerprint, null, null);
    const result = try provider.authenticate(&identity);
    try std.testing.expect(result == null);
}

test "matchPattern: exact match" {
    try std.testing.expect(matchPattern("test", "test"));
    try std.testing.expect(!matchPattern("test", "test2"));
}

test "matchPattern: wildcard prefix" {
    try std.testing.expect(matchPattern("*@example.com", "user@example.com"));
    try std.testing.expect(matchPattern("*@example.com", "admin@example.com"));
    try std.testing.expect(!matchPattern("*@example.com", "user@other.com"));
}

test "matchPattern: wildcard suffix" {
    try std.testing.expect(matchPattern("admin*", "admin"));
    try std.testing.expect(matchPattern("admin*", "administrator"));
    try std.testing.expect(!matchPattern("admin*", "user"));
}

test "matchPattern: wildcard middle" {
    try std.testing.expect(matchPattern("admin*@example.com", "admin@example.com"));
    try std.testing.expect(matchPattern("admin*@example.com", "admin123@example.com"));
    try std.testing.expect(!matchPattern("admin*@example.com", "user@example.com"));
}

test "extractIdentity: computes fingerprint" {
    const allocator = std.testing.allocator;

    // Use some test bytes as "certificate"
    const test_cert = "test certificate data";
    const identity = try extractIdentity(allocator, test_cert);

    // Fingerprint should be 64 hex characters
    try std.testing.expectEqual(@as(usize, 64), identity.fingerprint.len);

    // Should only contain hex characters
    for (identity.fingerprint) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

// GAP-0248: ASN.1/DER parser unit tests
test "parseAsn1Element: short form length" {
    // SEQUENCE tag (0x30) with 2-byte payload
    const data = [_]u8{ 0x30, 0x02, 0xAA, 0xBB };
    const elem = try parseAsn1Element(&data);
    try std.testing.expectEqual(@as(u8, 0x30), elem.tag);
    try std.testing.expectEqual(@as(usize, 2), elem.data.len);
    try std.testing.expectEqual(@as(u8, 0xAA), elem.data[0]);
}

test "parseAsn1Element: long form length" {
    // INTEGER tag (0x02), long form: 1 length byte indicating 130 bytes
    var data: [134]u8 = undefined;
    data[0] = 0x02; // INTEGER
    data[1] = 0x81; // Long form, 1 byte length
    data[2] = 0x80; // 128 bytes
    @memset(data[3..], 0x42);
    const elem = try parseAsn1Element(&data);
    try std.testing.expectEqual(@as(u8, 0x02), elem.tag);
    try std.testing.expectEqual(@as(usize, 128), elem.data.len);
}

test "parseUtcTime: valid UTC time" {
    // 250101120000Z = 2025-01-01 12:00:00 UTC
    const utc = "250101120000Z";
    const ts = parseUtcTime(utc);
    // Should be a positive timestamp in 2025
    try std.testing.expect(ts > 1735689600); // 2025-01-01 00:00:00
    try std.testing.expect(ts < 1735776000 + 86400); // within reasonable range
}

test "epochDays: known date" {
    // 1970-01-01 should be day 0
    const days = epochDays(1970, 1, 1);
    try std.testing.expectEqual(@as(i64, 0), days);
}

test "epochDays: Y2K" {
    // 2000-01-01 should be day 10957
    const days = epochDays(2000, 1, 1);
    try std.testing.expectEqual(@as(i64, 10957), days);
}

test "parseSanExtension: DNS name" {
    // Context-specific [2] dNSName = "example.com"
    const dns_name = "example.com";
    var san_data: [2 + dns_name.len]u8 = undefined;
    san_data[0] = 0x82; // context-specific [2] (dNSName)
    san_data[1] = @intCast(dns_name.len);
    @memcpy(san_data[2..], dns_name);
    const san = parseSanExtension(&san_data);
    try std.testing.expect(san.dns != null);
    try std.testing.expectEqualStrings("example.com", san.dns.?);
}

test "extractIdentity: gracefully handles non-certificate data" {
    const allocator = std.testing.allocator;
    // Non-DER data should still return a valid identity with fingerprint only
    const garbage = "not a certificate";
    const identity = try extractIdentity(allocator, garbage);
    try std.testing.expectEqual(@as(usize, 64), identity.fingerprint.len);
    // All parsed fields should be null/default (graceful degradation)
    try std.testing.expect(identity.subject_cn == null);
    try std.testing.expect(identity.san_dns == null);
}
