const std = @import("std");
const fulltext = @import("fulltext.zig");
const tde = @import("../storage/tde_file_encryption.zig");

const FullTextIndex = fulltext.FullTextIndex;
const Document = FullTextIndex.Document;
const Token = FullTextIndex.Token;
const PostingList = FullTextIndex.PostingList;
const PostingEntry = FullTextIndex.PostingEntry;

// CANARY: REQ=REQ-TDE-FILELEVEL-001; FEATURE="TDEFileLevelEncryption"; ASPECT=FullTextIndex; STATUS=IMPL; OWNER=security; UPDATED=2026-04-07

const MAGIC = "GFTS";
const VERSION: u16 = 1;

// Sanity limits to prevent corrupted files from triggering huge allocations.
const MAX_DOCS: u64 = 10_000_000;
const MAX_TOKENS_PER_DOC: u64 = 100_000;
const MAX_CONTENT_LEN: u64 = 10 * 1024 * 1024; // 10 MB
const MAX_TERMS: u64 = 10_000_000;
const MAX_POSITIONS_PER_ENTRY: u64 = 100_000;
const MAX_VEC_LEN: u64 = 100_000;

/// Serialize a FullTextIndex to disk at `{dir_path}/fulltext.idx`.
/// Uses TDE-aware file writing for encryption-at-rest support.
pub fn save(index: *const FullTextIndex, dir_path: []const u8) !void {
    const path = try std.fmt.allocPrint(index.allocator, "{s}/fulltext.idx", .{dir_path});
    defer index.allocator.free(path);

    var buffer = try std.ArrayList(u8).initCapacity(index.allocator, 4096);
    defer buffer.deinit(index.allocator);

    // Write magic and version
    try buffer.appendSlice(index.allocator, MAGIC);
    try buffer.appendSlice(index.allocator, std.mem.asBytes(&VERSION));

    // Write document count
    const doc_count: u64 = index.documents.count();
    try buffer.appendSlice(index.allocator, std.mem.asBytes(&doc_count));

    // Write documents section
    var doc_it = index.documents.iterator();
    while (doc_it.next()) |entry| {
        const doc = entry.value_ptr.*;
        try writeDocument(index.allocator, &buffer, &doc);
    }

    // Write inverted index count
    const term_count: u64 = index.inverted_index.count();
    try buffer.appendSlice(index.allocator, std.mem.asBytes(&term_count));

    // Write inverted index section
    var idx_it = index.inverted_index.iterator();
    while (idx_it.next()) |entry| {
        const posting_list = entry.value_ptr.*;
        try writePostingList(index.allocator, &buffer, &posting_list);
    }

    // Write via TDE (handles encryption if enabled, plain write otherwise)
    try tde.writeEncryptedFile(index.allocator, path, buffer.items);
}

fn writeDocument(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), doc: *const Document) !void {
    // doc_id
    try buffer.appendSlice(allocator, std.mem.asBytes(&doc.id));

    // content (length-prefixed)
    const content_len: u64 = doc.content.len;
    try buffer.appendSlice(allocator, std.mem.asBytes(&content_len));
    try buffer.appendSlice(allocator, doc.content);

    // tokens count
    const token_count: u64 = doc.tokens.len;
    try buffer.appendSlice(allocator, std.mem.asBytes(&token_count));

    // tokens
    for (doc.tokens) |token| {
        try writeToken(allocator, buffer, &token);
    }

    // vector (optional, prefixed with 1/0 flag)
    if (doc.vector) |vec| {
        const has_vec: u8 = 1;
        try buffer.appendSlice(allocator, std.mem.asBytes(&has_vec));
        const vec_len: u64 = vec.len;
        try buffer.appendSlice(allocator, std.mem.asBytes(&vec_len));
        try buffer.appendSlice(allocator, std.mem.sliceAsBytes(vec));
    } else {
        const has_vec: u8 = 0;
        try buffer.appendSlice(allocator, std.mem.asBytes(&has_vec));
    }
}

fn writeToken(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), token: *const Token) !void {
    // text (length-prefixed)
    const text_len: u64 = token.text.len;
    try buffer.appendSlice(allocator, std.mem.asBytes(&text_len));
    try buffer.appendSlice(allocator, token.text);

    // position, offset, length
    const position: u64 = token.position;
    try buffer.appendSlice(allocator, std.mem.asBytes(&position));
    const offset: u64 = token.offset;
    try buffer.appendSlice(allocator, std.mem.asBytes(&offset));
    const length: u64 = token.length;
    try buffer.appendSlice(allocator, std.mem.asBytes(&length));
}

fn writePostingList(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), pl: *const PostingList) !void {
    // term (length-prefixed)
    const term_len: u64 = pl.term.len;
    try buffer.appendSlice(allocator, std.mem.asBytes(&term_len));
    try buffer.appendSlice(allocator, pl.term);

    // idf
    try buffer.appendSlice(allocator, std.mem.asBytes(&pl.idf));

    // posting entries count
    const entry_count: u64 = pl.documents.len;
    try buffer.appendSlice(allocator, std.mem.asBytes(&entry_count));

    // posting entries
    for (pl.documents) |pe| {
        try writePostingEntry(allocator, buffer, &pe);
    }
}

fn writePostingEntry(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), pe: *const PostingEntry) !void {
    // doc_id
    try buffer.appendSlice(allocator, std.mem.asBytes(&pe.doc_id));

    // tf, tf_idf
    try buffer.appendSlice(allocator, std.mem.asBytes(&pe.tf));
    try buffer.appendSlice(allocator, std.mem.asBytes(&pe.tf_idf));

    // positions (length-prefixed)
    const pos_count: u64 = pe.positions.len;
    try buffer.appendSlice(allocator, std.mem.asBytes(&pos_count));
    for (pe.positions) |pos| {
        const p: u64 = pos;
        try buffer.appendSlice(allocator, std.mem.asBytes(&p));
    }
}

/// Deserialize a FullTextIndex from `{dir_path}/fulltext.idx`.
/// Returns a fresh empty index if the file does not exist.
pub fn load(allocator: std.mem.Allocator, dir_path: []const u8) !FullTextIndex {
    const path = try std.fmt.allocPrint(allocator, "{s}/fulltext.idx", .{dir_path});
    defer allocator.free(path);

    // Read and decrypt file via TDE
    const data = tde.readDecryptedFile(allocator, path) catch |err| {
        if (err == error.FileNotFound) {
            return try FullTextIndex.init(allocator);
        }
        return err;
    };
    defer allocator.free(data);

    var stream = std.io.fixedBufferStream(data);
    const reader = stream.reader();

    // Verify magic
    var magic: [4]u8 = undefined;
    _ = try reader.readAll(&magic);
    if (!std.mem.eql(u8, &magic, MAGIC)) return error.InvalidMagic;

    // Verify version
    var version: u16 = undefined;
    _ = try reader.readAll(std.mem.asBytes(&version));
    if (version != VERSION) return error.InvalidVersion;

    // Create index (initializes stopwords)
    var index = try FullTextIndex.init(allocator);
    errdefer index.deinit();

    // Read documents
    var doc_count: u64 = undefined;
    _ = try reader.readAll(std.mem.asBytes(&doc_count));
    if (doc_count > MAX_DOCS) return error.CorruptedIndex;

    var i: u64 = 0;
    while (i < doc_count) : (i += 1) {
        const doc = try readDocument(allocator, reader);
        try index.documents.put(doc.id, doc);
    }

    // Read inverted index
    var term_count: u64 = undefined;
    _ = try reader.readAll(std.mem.asBytes(&term_count));
    if (term_count > MAX_TERMS) return error.CorruptedIndex;

    i = 0;
    while (i < term_count) : (i += 1) {
        const pl = try readPostingList(allocator, reader);
        try index.inverted_index.put(pl.term, pl);
    }

    return index;
}

fn readDocument(allocator: std.mem.Allocator, reader: anytype) !Document {
    // doc_id
    var doc_id: u64 = undefined;
    _ = try reader.readAll(std.mem.asBytes(&doc_id));

    // content
    var content_len: u64 = undefined;
    _ = try reader.readAll(std.mem.asBytes(&content_len));
    if (content_len > MAX_CONTENT_LEN) return error.CorruptedIndex;
    const content = try allocator.alloc(u8, content_len);
    errdefer allocator.free(content);
    _ = try reader.readAll(content);

    // tokens — read serialized text but reconstruct slices pointing into content
    // to match the original memory layout (deinit frees content, not individual token.text)
    var token_count: u64 = undefined;
    _ = try reader.readAll(std.mem.asBytes(&token_count));
    if (token_count > MAX_TOKENS_PER_DOC) return error.CorruptedIndex;
    const tokens = try allocator.alloc(Token, token_count);
    errdefer allocator.free(tokens);
    for (tokens) |*token| {
        token.* = try readToken(allocator, reader, content);
    }

    // vector
    var has_vec: u8 = undefined;
    _ = try reader.readAll(std.mem.asBytes(&has_vec));
    const vector: ?[]f32 = if (has_vec == 1) blk: {
        var vec_len: u64 = undefined;
        _ = try reader.readAll(std.mem.asBytes(&vec_len));
        if (vec_len > MAX_VEC_LEN) return error.CorruptedIndex;
        const vec = try allocator.alloc(f32, vec_len);
        errdefer allocator.free(vec);
        _ = try reader.readAll(std.mem.sliceAsBytes(vec));
        break :blk vec;
    } else null;

    return Document{
        .id = doc_id,
        .content = content,
        .tokens = tokens,
        .vector = vector,
    };
}

fn readToken(allocator: std.mem.Allocator, reader: anytype, content: []const u8) !Token {
    _ = allocator;

    // text — skip the serialized text bytes (we reconstruct from content + offset/length)
    var text_len: u64 = undefined;
    _ = try reader.readAll(std.mem.asBytes(&text_len));
    try reader.skipBytes(text_len, .{});

    // position, offset, length
    var position: u64 = undefined;
    _ = try reader.readAll(std.mem.asBytes(&position));
    var offset: u64 = undefined;
    _ = try reader.readAll(std.mem.asBytes(&offset));
    var length: u64 = undefined;
    _ = try reader.readAll(std.mem.asBytes(&length));

    // Reconstruct text as a slice into content (matches original memory layout)
    const end = @min(offset + length, content.len);
    const text = if (offset <= content.len) content[offset..end] else content[0..0];

    return Token{
        .text = text,
        .position = position,
        .offset = offset,
        .length = length,
    };
}

fn readPostingList(allocator: std.mem.Allocator, reader: anytype) !PostingList {
    // term
    var term_len: u64 = undefined;
    _ = try reader.readAll(std.mem.asBytes(&term_len));
    if (term_len > MAX_CONTENT_LEN) return error.CorruptedIndex;
    const term = try allocator.alloc(u8, term_len);
    errdefer allocator.free(term);
    _ = try reader.readAll(term);

    // idf
    var idf: f32 = undefined;
    _ = try reader.readAll(std.mem.asBytes(&idf));

    // posting entries
    var entry_count: u64 = undefined;
    _ = try reader.readAll(std.mem.asBytes(&entry_count));
    if (entry_count > MAX_DOCS) return error.CorruptedIndex;
    const entries = try allocator.alloc(PostingEntry, entry_count);
    errdefer allocator.free(entries);
    for (entries) |*pe| {
        pe.* = try readPostingEntry(allocator, reader);
    }

    return PostingList{
        .term = term,
        .documents = entries,
        .idf = idf,
    };
}

fn readPostingEntry(allocator: std.mem.Allocator, reader: anytype) !PostingEntry {
    // doc_id
    var doc_id: u64 = undefined;
    _ = try reader.readAll(std.mem.asBytes(&doc_id));

    // tf, tf_idf
    var tf: f32 = undefined;
    _ = try reader.readAll(std.mem.asBytes(&tf));
    var tf_idf: f32 = undefined;
    _ = try reader.readAll(std.mem.asBytes(&tf_idf));

    // positions
    var pos_count: u64 = undefined;
    _ = try reader.readAll(std.mem.asBytes(&pos_count));
    if (pos_count > MAX_POSITIONS_PER_ENTRY) return error.CorruptedIndex;
    const positions = try allocator.alloc(usize, pos_count);
    errdefer allocator.free(positions);
    for (positions) |*pos| {
        var p: u64 = undefined;
        _ = try reader.readAll(std.mem.asBytes(&p));
        pos.* = p;
    }

    return PostingEntry{
        .doc_id = doc_id,
        .positions = positions,
        .tf = tf,
        .tf_idf = tf_idf,
    };
}

// Round-trip test: create index, index a document, save, load, verify
test "fulltext_persist round-trip" {
    const allocator = std.testing.allocator;

    // Create a temp directory for the test
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(dir_path);

    // Create and populate index
    var index = try FullTextIndex.init(allocator);
    defer index.deinit();

    try index.indexDocument(1, "hello world graph database");
    try index.indexDocument(2, "graph query language");

    // Verify document count before save
    try std.testing.expectEqual(@as(u32, 2), index.documents.count());

    // Save to disk
    try save(&index, dir_path);

    // Load from disk
    var loaded = try load(allocator, dir_path);
    defer loaded.deinit();

    // Verify document count
    try std.testing.expectEqual(@as(u32, 2), loaded.documents.count());

    // Verify document 1 content
    const doc1 = loaded.documents.get(1) orelse return error.DocNotFound;
    try std.testing.expectEqualStrings("hello world graph database", doc1.content);

    // Verify document 2 content
    const doc2 = loaded.documents.get(2) orelse return error.DocNotFound;
    try std.testing.expectEqualStrings("graph query language", doc2.content);

    // Verify inverted index was restored (search relies on it)
    try std.testing.expect(loaded.inverted_index.count() > 0);
    // "graph" should be in the inverted index with postings for both docs
    const posting = loaded.inverted_index.get("graph") orelse return error.TermNotFound;
    try std.testing.expectEqual(@as(usize, 2), posting.documents.len);
}

test "fulltext_persist load missing file returns fresh index" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(dir_path);

    // Load from non-existent file should return fresh index
    var index = try load(allocator, dir_path);
    defer index.deinit();

    try std.testing.expectEqual(@as(u32, 0), index.documents.count());
    try std.testing.expectEqual(@as(u32, 0), index.inverted_index.count());
}

test "fulltext_persist invalid magic" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(dir_path);

    const path = try std.fmt.allocPrint(allocator, "{s}/fulltext.idx", .{dir_path});
    defer allocator.free(path);

    // Write garbage data
    const garbage = "BADMAGICDATA1234567890";
    try tde.writeEncryptedFile(allocator, path, garbage);

    // Should fail with InvalidMagic
    const result = load(allocator, dir_path);
    try std.testing.expectError(error.InvalidMagic, result);
}
