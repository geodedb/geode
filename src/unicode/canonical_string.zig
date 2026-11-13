//! The canonical form of a character string for equality, ordering, hashing
//! and keys (SONNY-3055).
//!
//! Two strings are equal when their Normalization Form C (Unicode Standard
//! Annex #15) forms are byte-equal: a precomposed 'é' (U+00E9) equals 'e'
//! followed by U+0301 COMBINING ACUTE ACCENT. ISO/IEC 39075:2024 4.16.x
//! (character strings) leaves the result of an operation on an unnormalized
//! string implementation-defined (IA003) and compares strings by a collation
//! (19.3 General Rule 3b, 22.16 Determination of collation); Geode's
//! collation compares the NFC forms by their UTF-8 bytes, i.e. by code point.
//!
//! Every site that decides string identity uses `canonical`: `=` and the order
//! operators (eval), `execution.valuesEqual` (inline property maps, MERGE),
//! the stored-property matcher of the persisted read paths, GROUP BY and
//! DISTINCT keys (distinct_set, also the planned read's hash-join key), the
//! exact node-property index and MERGE's property index and tuple locks. A
//! string that is not valid UTF-8 is its own canonical form (it equals only
//! the same bytes; no valid string has its bytes).
//!
//! NFC is computed by the `strings` dependency's UAX #15 implementation
//! (Unicode 15.1 tables). ASCII is its own NFC form, so ASCII strings never
//! allocate and keep their bytes.

// CANARY: REQ=REQ-SONNY-3055-NFC-STRING-IDENTITY; FEATURE="UnicodeEval"; ASPECT=CanonicalNfcForm; STATUS=TESTED; TEST=tests/test_sonny3055_nfc_string_identity.zig; OWNER=unicode; UPDATED=2026-11-13

const std = @import("std");
const strings = @import("strings");

/// A string's canonical (NFC) form: `bytes` is the input itself when it is
/// already canonical, or memory owned by the `Canonical`.
pub const Canonical = struct {
    bytes: []const u8,
    owned: ?[]u8 = null,

    pub fn deinit(self: Canonical, allocator: std.mem.Allocator) void {
        if (self.owned) |o| allocator.free(o);
    }
};

/// Whether every byte of `s` is 7-bit ASCII.
pub fn isAscii(s: []const u8) bool {
    for (s) |c| {
        if (c >= 0x80) return false;
    }
    return true;
}

/// Whether `s` is its own canonical form, without allocating: ASCII, invalid
/// UTF-8, or valid UTF-8 the NFC quick check accepts. A false answer means
/// "possibly not": `canonical` decides.
pub fn isCanonical(s: []const u8) bool {
    if (isAscii(s)) return true;
    if (!std.unicode.utf8ValidateSlice(s)) return true;
    return strings.normalization.isNormalized(s, .nfc);
}

/// The canonical form of `s`. Allocates only for a valid UTF-8 string the NFC
/// quick check does not accept.
pub fn canonical(allocator: std.mem.Allocator, s: []const u8) error{OutOfMemory}!Canonical {
    if (isCanonical(s)) return .{ .bytes = s };
    const nfc = strings.normalization.normalize(allocator, s, .nfc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A decomposition past the library's expansion bound (a
        // normalization bomb) or a sequence it rejects: the string is keyed
        // by its own bytes, as invalid UTF-8 is.
        else => return .{ .bytes = s },
    };
    if (std.mem.eql(u8, nfc, s)) {
        allocator.free(nfc);
        return .{ .bytes = s };
    }
    return .{ .bytes = nfc, .owned = nfc };
}

/// The order of `a` and `b` by their canonical forms' bytes.
pub fn order(allocator: std.mem.Allocator, a: []const u8, b: []const u8) error{OutOfMemory}!std.math.Order {
    if (isAscii(a) and isAscii(b)) return std.mem.order(u8, a, b);
    const ca = try canonical(allocator, a);
    defer ca.deinit(allocator);
    const cb = try canonical(allocator, b);
    defer cb.deinit(allocator);
    return std.mem.order(u8, ca.bytes, cb.bytes);
}

/// Whether `a` and `b` are equal strings (equal canonical forms).
pub fn eql(allocator: std.mem.Allocator, a: []const u8, b: []const u8) error{OutOfMemory}!bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (isAscii(a) and isAscii(b)) return false;
    return (try order(allocator, a, b)) == .eq;
}

/// Writes the canonical form of `s` to `w` (a key's bytes).
pub fn writeCanonical(w: *std.Io.Writer, s: []const u8) (std.Io.Writer.Error || error{OutOfMemory})!void {
    if (isCanonical(s)) return w.writeAll(s);
    var sfa = std.heap.stackFallback(1024, std.heap.smp_allocator);
    const a = sfa.get();
    const c = try canonical(a, s);
    defer c.deinit(a);
    try w.writeAll(c.bytes);
}

/// `order` for a caller with no allocator (a sort comparator); out of memory
/// orders by the raw bytes.
pub fn orderNoAlloc(a: []const u8, b: []const u8) std.math.Order {
    if (isAscii(a) and isAscii(b)) return std.mem.order(u8, a, b);
    var sfa = std.heap.stackFallback(1024, std.heap.smp_allocator);
    return order(sfa.get(), a, b) catch std.mem.order(u8, a, b);
}

/// `eql` for a caller with no allocator (a hot comparator): the canonical
/// forms are built in a stack buffer, or the process allocator for a long
/// string. Out of memory is taken as "not equal" only when the bytes differ
/// and a canonical form could not be built, which needs a string of many
/// kilobytes under memory exhaustion.
pub fn eqlNoAlloc(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (isAscii(a) and isAscii(b)) return false;
    var sfa = std.heap.stackFallback(1024, std.heap.smp_allocator);
    return eql(sfa.get(), a, b) catch false;
}
