//! SONNY-6571: the cluster's Raft storage under TDE.
//!
//! The pinned raft library's `FileStorage` writes the Raft log
//! (`entries.wal`), hard state and snapshots under `<data_dir>/raft`. The log
//! carries every replicated write (labels, property keys and values), so with
//! `GEODE_TDE_KEY` set it must not reach the disk in plaintext. The library's
//! `Storage` is a vtable, so this module puts a `Storage` in front of the
//! `FileStorage` that encrypts what it is given and decrypts what it returns:
//!
//! * entry data and snapshot data are sealed with AES-256-GCM (through the
//!   crypto_backend FIPS seam, as `tde_file_encryption` does); everything else
//!   - durability, fsync order, truncation, compaction, recovery - is the
//!   unchanged `FileStorage` (temp file, fsync, rename and directory fsync for
//!   the hard state and snapshots; the wal library's fdatasync for the log).
//! * The hard state (`hard_state`: current term and vote, two integers) holds
//!   no graph data and is passed through as `FileStorage` writes it, so the
//!   SONNY-6563 rule (no message leaves before the hard state is durable)
//!   rests on exactly the code it rested on before.
//!
//! Keys and nonces. Nothing is sealed under `GEODE_TDE_KEY` itself. Each open
//! of the directory draws a random 16-byte salt and derives a session key
//! `HKDF-SHA256(ikm = GEODE_TDE_KEY, salt, info = "geode/raft-storage/v1/
//! aes-256-gcm")`; the nonce is a 64-bit counter that starts at 0 for that
//! session and grows by one per seal (the counter is never reset within a
//! session and the seal is refused before it could wrap). A (key, nonce) pair
//! therefore repeats only if two sessions draw the same 128-bit salt
//! (probability about n^2 / 2^129 over n opens) - independent of how many
//! records are written, and of every other user of GEODE_TDE_KEY (the storage
//! engine's pages and WAL use the key directly, never these derived keys, so
//! their nonces cannot collide with these). Each record carries its salt, so
//! records of every earlier session stay readable.
//!
//! Each entry is authenticated together with its index, term and kind, and
//! the snapshot with a fixed context string, so a record copied to another
//! index, or a log entry presented as a snapshot, fails to open.
//!
//! Snapshots (SONNY-6670) are staged off the Raft node lock like plaintext
//! ones: the data is sealed as it is staged, in segments of at most
//! `SEGMENT_BYTES`, each a record as above authenticated with its position
//! and whether it is the last (so segments cannot be reordered, dropped or
//! cut off), written to FileStorage's staged file, synced there, and
//! committed by FileStorage's renames under the lock. The file starts with
//! `STREAM_MAGIC`; a snapshot saved whole (`saveSnapshot`) is one record,
//! as before, and both read back.
//!
//! The directory records that it is encrypted in `tde.marker` (written before
//! any Raft state, by temp file, fsync, rename and directory fsync), with a
//! key check value derived from GEODE_TDE_KEY. On open:
//!
//! | GEODE_TDE_KEY | tde.marker | Raft state present | result |
//! | --- | --- | --- | --- |
//! | set | present, key matches | any | open, encrypted |
//! | set | present, other key | any | refuse: RaftStorageTdeKeyMismatch |
//! | set | absent | no | write the marker, open, encrypted |
//! | set | absent | yes (written without TDE) | refuse: RaftStoragePlaintextUnderTde |
//! | unset | present | any | refuse: RaftStorageNeedsTdeKey |
//! | unset | absent | any | open, plaintext (as before) |
//!
//! A plaintext directory is refused, not migrated: rewriting a live Raft log
//! in place is not crash-safe without a second copy, and the plaintext
//! already on the disk would stay in freed blocks either way. The operator
//! rebuilds the node from the cluster (docs/TDE_FILE_LEVEL_ENCRYPTION.md).
//
// CANARY: REQ=REQ-SONNY-6571-TDE-RAFT-AT-REST; FEATURE="TDEFileLevelEncryption"; ASPECT=RaftStorage; STATUS=TESTED; TEST=tests/test_sonny6571_raft_tde_storage.zig; OWNER=distributed; UPDATED=2026-11-15

const std = @import("std");
const raft_lib = @import("raft");
const cb = @import("crypto_backend");

pub const KEY_BYTES: usize = 32;
const SALT_BYTES: usize = 16;
const NONCE_BYTES: usize = 12;
const TAG_BYTES: usize = 16;

/// "Geode Raft TDE Entry": every sealed entry or snapshot starts with it.
const RECORD_MAGIC = [4]u8{ 'G', 'R', 'T', 'E' };
const RECORD_VERSION: u8 = 1;
const HEADER_BYTES: usize = RECORD_MAGIC.len + 1 + SALT_BYTES + NONCE_BYTES + TAG_BYTES;
/// Bytes a sealed record adds to the data it seals.
pub const RECORD_OVERHEAD: usize = HEADER_BYTES;

pub const MARKER_FILE = "tde.marker";
const MARKER_TMP = "tde.marker.tmp";
const MARKER_MAGIC = [8]u8{ 'G', 'R', 'T', 'D', 'E', 'M', 'K', '1' };
const MARKER_BYTES: usize = MARKER_MAGIC.len + SALT_BYTES + KEY_BYTES;

const SESSION_KEY_INFO = "geode/raft-storage/v1/aes-256-gcm";
const KEY_CHECK_INFO = "geode/raft-storage/v1/key-check";
const ENTRY_AAD_CONTEXT = "geode-raft-entry-v1";
const SNAPSHOT_AAD_CONTEXT = "geode-raft-snapshot-v1";
const SEGMENT_AAD_CONTEXT = "geode-raft-snapshot-segment-v1";
/// "Geode Raft TDE Stream": a snapshot sealed in segments (SONNY-6670).
const STREAM_MAGIC = [4]u8{ 'G', 'R', 'T', 'S' };
const STREAM_VERSION: u8 = 1;
/// The plaintext bytes in each sealed segment but the last.
pub const SEGMENT_BYTES: usize = 64 * 1024;

/// The files `FileStorage` keeps Raft state in.
const RAFT_STATE_FILES = [_][]const u8{ "hard_state", "entries.wal", "snapshot.meta", "snapshot.data" };

pub const Error = error{
    /// GEODE_TDE_KEY is set and the directory holds Raft state written
    /// without it (plaintext).
    RaftStoragePlaintextUnderTde,
    /// The directory is encrypted and GEODE_TDE_KEY is not set.
    RaftStorageNeedsTdeKey,
    /// The directory was encrypted under another GEODE_TDE_KEY.
    RaftStorageTdeKeyMismatch,
    /// A sealed record or the marker is malformed.
    RaftStorageCorrupt,
    /// A sealed record does not authenticate (tampered, or moved).
    RaftStorageAuthenticationFailed,
    /// The session's nonce counter is spent (2^64 seals; not reachable).
    RaftStorageNonceExhausted,
};

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn deriveKey(master_key: *const [KEY_BYTES]u8, salt: *const [SALT_BYTES]u8, info: []const u8) ![KEY_BYTES]u8 {
    var out: [KEY_BYTES]u8 = undefined;
    try cb.Kdf.hkdf(.sha256, master_key, salt, info, &out);
    return out;
}

fn fileExists(dir: std.Io.Dir, name: []const u8) bool {
    dir.access(io(), name, .{}) catch return false;
    return true;
}

/// True when the directory holds Raft state `FileStorage` wrote.
fn hasRaftState(dir: std.Io.Dir) bool {
    for (RAFT_STATE_FILES) |name| {
        if (fileExists(dir, name)) return true;
    }
    return false;
}

/// fsync the directory so a rename into it survives power loss
/// (FileStorage.syncDir).
fn syncDir(dir: std.Io.Dir) !void {
    const fd = try std.posix.openat(dir.handle, ".", .{ .DIRECTORY = true }, 0);
    defer _ = std.c.close(fd);
    if (std.c.fdatasync(fd) != 0) return error.InputOutput;
}

/// The no-key path: refuse a directory that is encrypted.
pub fn refuseIfEncrypted(fs: *raft_lib.FileStorage) Error!void {
    if (fileExists(fs.dir, MARKER_FILE)) return error.RaftStorageNeedsTdeKey;
}

fn writeMarker(dir: std.Io.Dir, master_key: *const [KEY_BYTES]u8) !void {
    var buf: [MARKER_BYTES]u8 = undefined;
    @memcpy(buf[0..MARKER_MAGIC.len], &MARKER_MAGIC);
    const salt = buf[MARKER_MAGIC.len..][0..SALT_BYTES];
    try cb.Csprng.bytes(salt);
    const check = try deriveKey(master_key, salt, KEY_CHECK_INFO);
    @memcpy(buf[MARKER_MAGIC.len + SALT_BYTES ..], &check);

    var tmp = try dir.createFile(io(), MARKER_TMP, .{});
    errdefer {
        tmp.close(io());
        dir.deleteFile(io(), MARKER_TMP) catch {};
    }
    try tmp.writeStreamingAll(io(), &buf);
    try tmp.sync(io());
    tmp.close(io());
    try dir.rename(MARKER_TMP, dir, MARKER_FILE, io());
    try syncDir(dir);
}

fn verifyMarker(dir: std.Io.Dir, master_key: *const [KEY_BYTES]u8) !void {
    var buf: [MARKER_BYTES + 1]u8 = undefined;
    const file = try dir.openFile(io(), MARKER_FILE, .{});
    defer file.close(io());
    const n = try file.readPositionalAll(io(), &buf, 0);
    if (n != MARKER_BYTES or !std.mem.eql(u8, buf[0..MARKER_MAGIC.len], &MARKER_MAGIC)) return error.RaftStorageCorrupt;
    const salt = buf[MARKER_MAGIC.len..][0..SALT_BYTES];
    const want = try deriveKey(master_key, salt, KEY_CHECK_INFO);
    if (!cb.timingSafeEql(&want, buf[MARKER_MAGIC.len + SALT_BYTES ..][0..KEY_BYTES])) return error.RaftStorageTdeKeyMismatch;
}

/// A `raft_lib.Storage` over a `FileStorage` whose entry and snapshot data are
/// sealed under keys derived from GEODE_TDE_KEY.
pub const TdeRaftStorage = struct {
    allocator: std.mem.Allocator,
    inner: *raft_lib.FileStorage,
    master_key: [KEY_BYTES]u8,
    session_salt: [SALT_BYTES]u8,
    session_key: [KEY_BYTES]u8,
    next_nonce: std.atomic.Value(u64) = .init(0),

    /// Check (or, for an empty directory, write) the marker of the opened
    /// `inner` and start a session. Takes ownership of `inner` (heap, from
    /// `allocator`) only on success; on error the caller still owns it.
    pub fn adopt(allocator: std.mem.Allocator, inner: *raft_lib.FileStorage, master_key: [KEY_BYTES]u8) !TdeRaftStorage {
        if (fileExists(inner.dir, MARKER_FILE)) {
            try verifyMarker(inner.dir, &master_key);
        } else if (hasRaftState(inner.dir)) {
            return error.RaftStoragePlaintextUnderTde;
        } else {
            try writeMarker(inner.dir, &master_key);
        }
        var salt: [SALT_BYTES]u8 = undefined;
        try cb.Csprng.bytes(&salt);
        return .{
            .allocator = allocator,
            .inner = inner,
            .master_key = master_key,
            .session_salt = salt,
            .session_key = try deriveKey(&master_key, &salt, SESSION_KEY_INFO),
        };
    }

    /// Closes the `FileStorage` (releasing its flock) and wipes the keys.
    pub fn deinit(self: *TdeRaftStorage) void {
        cb.secureZero(&self.master_key);
        cb.secureZero(&self.session_key);
        self.inner.deinit();
        self.allocator.destroy(self.inner);
    }

    pub fn storage(self: *TdeRaftStorage) raft_lib.Storage {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable_inst };
    }

    const vtable_inst = raft_lib.Storage.VTable{
        .saveHardState = saveHardState,
        .loadHardState = loadHardState,
        .appendEntries = appendEntries,
        .entries = entries,
        .term = term,
        .lastIndex = lastIndex,
        .saveSnapshot = saveSnapshot,
        .loadSnapshot = loadSnapshot,
        .compact = compact,
        .stageSnapshot = stageSnapshot,
        .commitStagedSnapshot = commitStagedSnapshot,
        .discardStagedSnapshot = discardStagedSnapshot,
        .beginStagedSnapshot = beginStagedSnapshot,
        .appendStagedSnapshot = appendStagedSnapshot,
        .syncStagedSnapshot = syncStagedSnapshot,
        .loadSnapshotMetadata = loadSnapshotMetadata,
    };

    fn cast(ptr: *anyopaque) *TdeRaftStorage {
        return @ptrCast(@alignCast(ptr));
    }

    fn innerStorage(self: *TdeRaftStorage) raft_lib.Storage {
        return self.inner.storage();
    }

    fn entryAad(buf: *[ENTRY_AAD_CONTEXT.len + 17]u8, index: u64, entry_term: u64, kind: raft_lib.EntryKind) []const u8 {
        @memcpy(buf[0..ENTRY_AAD_CONTEXT.len], ENTRY_AAD_CONTEXT);
        std.mem.writeInt(u64, buf[ENTRY_AAD_CONTEXT.len..][0..8], index, .little);
        std.mem.writeInt(u64, buf[ENTRY_AAD_CONTEXT.len + 8 ..][0..8], entry_term, .little);
        buf[ENTRY_AAD_CONTEXT.len + 16] = @intFromEnum(kind);
        return buf;
    }

    /// Seal `plaintext` into a new record (caller frees with `allocator`).
    fn seal(self: *TdeRaftStorage, plaintext: []const u8, aad: []const u8) ![]u8 {
        const counter = self.next_nonce.fetchAdd(1, .monotonic);
        if (counter == std.math.maxInt(u64)) return error.RaftStorageNonceExhausted;
        const out = try self.allocator.alloc(u8, HEADER_BYTES + plaintext.len);
        errdefer self.allocator.free(out);
        @memcpy(out[0..RECORD_MAGIC.len], &RECORD_MAGIC);
        out[RECORD_MAGIC.len] = RECORD_VERSION;
        const salt_at = RECORD_MAGIC.len + 1;
        @memcpy(out[salt_at..][0..SALT_BYTES], &self.session_salt);
        const nonce = out[salt_at + SALT_BYTES ..][0..NONCE_BYTES];
        @memset(nonce[0..4], 0);
        std.mem.writeInt(u64, nonce[4..12], counter, .big);
        const tag = out[salt_at + SALT_BYTES + NONCE_BYTES ..][0..TAG_BYTES];
        try cb.Aead.seal(.aes_256_gcm, &self.session_key, nonce, aad, plaintext, out[HEADER_BYTES..], tag);
        return out;
    }

    /// Open a sealed record into a new buffer (caller frees with `allocator`;
    /// an empty plaintext is the static empty slice, as FileStorage returns).
    fn open(self: *TdeRaftStorage, record: []const u8, aad: []const u8) ![]const u8 {
        if (record.len < HEADER_BYTES or !std.mem.eql(u8, record[0..RECORD_MAGIC.len], &RECORD_MAGIC) or record[RECORD_MAGIC.len] != RECORD_VERSION) {
            return error.RaftStorageCorrupt;
        }
        const salt_at = RECORD_MAGIC.len + 1;
        const salt = record[salt_at..][0..SALT_BYTES];
        const nonce = record[salt_at + SALT_BYTES ..][0..NONCE_BYTES];
        const tag = record[salt_at + SALT_BYTES + NONCE_BYTES ..][0..TAG_BYTES];
        const ciphertext = record[HEADER_BYTES..];

        var key = if (std.mem.eql(u8, salt, &self.session_salt))
            self.session_key
        else
            try deriveKey(&self.master_key, salt, SESSION_KEY_INFO);
        defer cb.secureZero(&key);

        if (ciphertext.len == 0) {
            var none: [0]u8 = .{};
            cb.Aead.open(.aes_256_gcm, &key, nonce, aad, ciphertext, tag, &none) catch return error.RaftStorageAuthenticationFailed;
            return &.{};
        }
        const plaintext = try self.allocator.alloc(u8, ciphertext.len);
        errdefer self.allocator.free(plaintext);
        cb.Aead.open(.aes_256_gcm, &key, nonce, aad, ciphertext, tag, plaintext) catch return error.RaftStorageAuthenticationFailed;
        return plaintext;
    }

    fn saveHardState(ptr: *anyopaque, hs: raft_lib.HardState) anyerror!void {
        return cast(ptr).innerStorage().saveHardState(hs);
    }

    fn loadHardState(ptr: *anyopaque) anyerror!raft_lib.HardState {
        return cast(ptr).innerStorage().loadHardState();
    }

    fn appendEntries(ptr: *anyopaque, ents: []const raft_lib.Entry) anyerror!void {
        const self = cast(ptr);
        if (ents.len == 0) return;
        const sealed = try self.allocator.alloc(raft_lib.Entry, ents.len);
        var sealed_count: usize = 0;
        defer {
            for (sealed[0..sealed_count]) |e| self.allocator.free(e.data);
            self.allocator.free(sealed);
        }
        for (ents, sealed) |e, *out| {
            var aad_buf: [ENTRY_AAD_CONTEXT.len + 17]u8 = undefined;
            out.* = .{
                .index = e.index,
                .term = e.term,
                .kind = e.kind,
                .data = try self.seal(e.data, entryAad(&aad_buf, e.index, e.term, e.kind)),
            };
            sealed_count += 1;
        }
        return self.innerStorage().appendEntries(sealed);
    }

    fn entries(ptr: *anyopaque, lo: u64, hi: u64) anyerror![]raft_lib.Entry {
        const self = cast(ptr);
        const got = try self.innerStorage().entries(lo, hi);
        // FileStorage returns a static empty slice for an empty range.
        if (got.len == 0) return got;
        // On an error, the entries before the failing one hold plaintext
        // (allocated, or the static empty slice) and the rest the records
        // read: free whichever is allocated.
        errdefer {
            for (got) |e| {
                if (e.data.len > 0) self.allocator.free(e.data);
            }
            self.allocator.free(got);
        }
        for (got) |*e| {
            var aad_buf: [ENTRY_AAD_CONTEXT.len + 17]u8 = undefined;
            const plaintext = try self.open(e.data, entryAad(&aad_buf, e.index, e.term, e.kind));
            if (e.data.len > 0) self.allocator.free(e.data);
            e.data = plaintext;
        }
        return got;
    }

    fn term(ptr: *anyopaque, index: u64) anyerror!u64 {
        return cast(ptr).innerStorage().term(index);
    }

    fn lastIndex(ptr: *anyopaque) anyerror!u64 {
        return cast(ptr).innerStorage().lastIndex();
    }

    fn saveSnapshot(ptr: *anyopaque, snap: raft_lib.Snapshot) anyerror!void {
        const self = cast(ptr);
        const sealed = try self.seal(snap.data, SNAPSHOT_AAD_CONTEXT);
        defer self.allocator.free(sealed);
        var copy = snap;
        copy.data = sealed;
        return self.innerStorage().saveSnapshot(copy);
    }

    fn loadSnapshot(ptr: *anyopaque) anyerror!?raft_lib.Snapshot {
        const self = cast(ptr);
        var snap = (try self.innerStorage().loadSnapshot()) orelse return null;
        errdefer raft_lib.freeSnapshot(self.allocator, snap);
        const plaintext = try self.openSnapshotData(snap.data);
        if (snap.data.len > 0) self.allocator.free(snap.data);
        snap.data = plaintext;
        return snap;
    }

    /// SONNY-6665: the committed snapshot, decrypted, read WITHOUT the node
    /// lock (`FileStorage.openSnapshotReader`) for a leader to stream it to
    /// a follower; `loadSnapshot` may finish an interrupted commit and needs
    /// the lock. The sealed record is checked against the digest committed
    /// with it, then opened. Null when there is no snapshot. Free it with
    /// `raft_lib.freeSnapshot`.
    pub fn loadSnapshotUnlocked(self: *TdeRaftStorage) !?raft_lib.Snapshot {
        var reader = (try self.inner.openSnapshotReader()) orelse return null;
        defer reader.close();
        const sealed = try self.allocator.alloc(u8, @intCast(reader.size));
        defer self.allocator.free(sealed);
        if (try reader.readAt(sealed, 0) != sealed.len) return error.SnapshotChanged;
        if (reader.expected_digest) |want| {
            var got: [32]u8 = undefined;
            // fips-exempt: non-security — raft's snapshot-data integrity digest.
            std.crypto.hash.Blake3.hash(sealed, &got, .{});
            if (!std.mem.eql(u8, &got, &want)) return error.SnapshotChanged;
        }
        const plaintext = try self.openSnapshotData(sealed);
        errdefer if (plaintext.len > 0) self.allocator.free(plaintext);
        const cfg = reader.metadata.config;
        const voters = try self.allocator.dupe(u64, cfg.voters);
        errdefer self.allocator.free(voters);
        const outgoing = try self.allocator.dupe(u64, cfg.voters_outgoing);
        return .{
            .metadata = .{ .index = reader.metadata.index, .term = reader.metadata.term, .config = .{
                .voters = voters,
                .voters_outgoing = outgoing,
                .is_joint = cfg.is_joint,
            } },
            .data = plaintext,
        };
    }

    // CANARY: REQ=REQ-SONNY-6670-TDE-STAGED-SNAPSHOT; FEATURE="TDEFileLevelEncryption"; ASPECT=StagedSealedSegments; STATUS=TESTED; TEST=tests/test_sonny6670_tde_staged_snapshot.zig; OWNER=distributed; UPDATED=2026-11-16
    /// SONNY-6670: a snapshot's data, sealed in one record (`saveSnapshot`)
    /// or in segments (staged), opened. The caller frees it.
    fn openSnapshotData(self: *TdeRaftStorage, sealed: []const u8) ![]const u8 {
        if (sealed.len < STREAM_MAGIC.len or !std.mem.eql(u8, sealed[0..STREAM_MAGIC.len], &STREAM_MAGIC)) {
            return self.open(sealed, SNAPSHOT_AAD_CONTEXT);
        }
        if (sealed.len < STREAM_MAGIC.len + 1 or sealed[STREAM_MAGIC.len] != STREAM_VERSION) return error.RaftStorageCorrupt;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        var pos: usize = STREAM_MAGIC.len + 1;
        var index: u64 = 0;
        while (true) : (index += 1) {
            if (sealed.len - pos < 4) return error.RaftStorageCorrupt;
            const len = std.mem.readInt(u32, sealed[pos..][0..4], .little);
            pos += 4;
            if (sealed.len - pos < len) return error.RaftStorageCorrupt;
            const record = sealed[pos..][0..len];
            pos += len;
            const last = pos == sealed.len;
            var aad_buf: [SEGMENT_AAD_CONTEXT.len + 9]u8 = undefined;
            const plain = try self.open(record, segmentAad(&aad_buf, index, last));
            defer if (plain.len > 0) self.allocator.free(plain);
            try out.appendSlice(self.allocator, plain);
            if (last) break;
        }
        // An empty snapshot is the static empty slice, as FileStorage returns.
        if (out.items.len == 0) {
            out.deinit(self.allocator);
            return &.{};
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn segmentAad(buf: *[SEGMENT_AAD_CONTEXT.len + 9]u8, index: u64, last: bool) []const u8 {
        @memcpy(buf[0..SEGMENT_AAD_CONTEXT.len], SEGMENT_AAD_CONTEXT);
        std.mem.writeInt(u64, buf[SEGMENT_AAD_CONTEXT.len..][0..8], index, .little);
        buf[SEGMENT_AAD_CONTEXT.len + 8] = @intFromBool(last);
        return buf;
    }

    /// SONNY-6670: the TDE side of a staged snapshot: FileStorage's staged
    /// snapshot of the sealed segments (its digest and size are the sealed
    /// bytes', which FileStorage records and checks), and the plaintext not
    /// sealed yet. The outer `StagedSnapshot` (whose digest is the
    /// plaintext's, which raft compares with the leader's) holds its
    /// address in `payload`.
    const Stage = struct {
        inner: raft_lib.StagedSnapshot,
        pending: std.ArrayList(u8) = .empty,
        segments: u64 = 0,
    };

    fn stageOf(staged: *raft_lib.StagedSnapshot) !*Stage {
        if (staged.payload.len != @sizeOf(usize)) return error.StagedSnapshotForeign;
        return @ptrFromInt(std.mem.readInt(usize, staged.payload[0..@sizeOf(usize)], .little));
    }

    fn freeStage(self: *TdeRaftStorage, st: *Stage) void {
        st.inner.deinit();
        st.pending.deinit(self.allocator);
        self.allocator.destroy(st);
    }

    /// Write `bytes` at the end of the inner staged file.
    fn appendSealed(self: *TdeRaftStorage, st: *Stage, bytes: []const u8) !void {
        try self.inner.appendStagedSnapshot(&st.inner, bytes);
        st.inner.noteAppended(bytes);
    }

    /// Seal `plain` as the next segment (`last`: the final one) and append it.
    fn sealSegment(self: *TdeRaftStorage, st: *Stage, plain: []const u8, last: bool) !void {
        var aad_buf: [SEGMENT_AAD_CONTEXT.len + 9]u8 = undefined;
        const record = try self.seal(plain, segmentAad(&aad_buf, st.segments, last));
        defer self.allocator.free(record);
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(record.len), .little);
        try self.appendSealed(st, &len);
        try self.appendSealed(st, record);
        st.segments += 1;
    }

    fn beginStagedSnapshot(ptr: *anyopaque, meta: raft_lib.SnapshotMetadata) anyerror!raft_lib.StagedSnapshot {
        const self = cast(ptr);
        const st = try self.allocator.create(Stage);
        errdefer self.allocator.destroy(st);
        st.* = .{ .inner = try self.inner.beginStagedSnapshot(meta) };
        errdefer {
            self.inner.storage().vtable.discardStagedSnapshot.?(@ptrCast(self.inner), &st.inner);
            st.inner.deinit();
        }
        try self.appendSealed(st, &(STREAM_MAGIC ++ [_]u8{STREAM_VERSION}));
        var outer = try raft_lib.StagedSnapshot.initMetadata(self.allocator, @ptrCast(self), meta);
        errdefer outer.deinit();
        var addr: [@sizeOf(usize)]u8 = undefined;
        std.mem.writeInt(usize, &addr, @intFromPtr(st), .little);
        outer.payload = try self.allocator.dupe(u8, &addr);
        return outer;
    }

    /// Seals every full segment that more data follows; the rest waits.
    /// No lock needed (FileStorage writes only the staged file).
    fn appendStagedSnapshot(ptr: *anyopaque, staged: *raft_lib.StagedSnapshot, bytes: []const u8) anyerror!void {
        const self = cast(ptr);
        const st = try stageOf(staged);
        try st.pending.appendSlice(self.allocator, bytes);
        var done: usize = 0;
        while (st.pending.items.len - done > SEGMENT_BYTES) : (done += SEGMENT_BYTES) {
            try self.sealSegment(st, st.pending.items[done..][0..SEGMENT_BYTES], false);
        }
        if (done > 0) {
            const rest = st.pending.items.len - done;
            std.mem.copyForwards(u8, st.pending.items[0..rest], st.pending.items[done..]);
            st.pending.shrinkRetainingCapacity(rest);
        }
    }

    /// Seals the last segment, then syncs the staged file and writes its
    /// metadata (FileStorage). No lock needed.
    fn syncStagedSnapshot(ptr: *anyopaque, staged: *raft_lib.StagedSnapshot) anyerror!void {
        const self = cast(ptr);
        const st = try stageOf(staged);
        if (!st.inner.finished) {
            try self.sealSegment(st, st.pending.items, true);
            st.pending.clearAndFree(self.allocator);
            _ = st.inner.finish();
        }
        try self.inner.syncStagedSnapshot(&st.inner);
        staged.synced = true;
    }

    /// Seal and stage a whole snapshot (a node's own), off the lock.
    fn stageSnapshot(ptr: *anyopaque, snap: raft_lib.Snapshot) anyerror!raft_lib.StagedSnapshot {
        const self = cast(ptr);
        var staged = try beginStagedSnapshot(ptr, snap.metadata);
        errdefer self.storage().releaseStagedSnapshot(&staged);
        try appendStagedSnapshot(ptr, &staged, snap.data);
        staged.noteAppended(snap.data);
        _ = staged.finish();
        try syncStagedSnapshot(ptr, &staged);
        return staged;
    }

    /// FileStorage's commit (renames, directory syncs, log compaction),
    /// under the lock.
    fn commitStagedSnapshot(ptr: *anyopaque, staged: *raft_lib.StagedSnapshot) anyerror!void {
        const self = cast(ptr);
        const st = try stageOf(staged);
        if (!staged.synced) try syncStagedSnapshot(ptr, staged);
        const committed = self.inner.commitStagedSnapshot(&st.inner);
        // Past FileStorage's commit point the snapshot stands, error or not.
        if (st.inner.committed) {
            staged.committed = true;
            self.freeStage(st);
        }
        return committed;
    }

    /// Removes an uncommitted staged snapshot's files (FileStorage).
    fn discardStagedSnapshot(ptr: *anyopaque, staged: *raft_lib.StagedSnapshot) void {
        const self = cast(ptr);
        const st = stageOf(staged) catch return;
        if (!st.inner.committed) self.inner.storage().vtable.discardStagedSnapshot.?(@ptrCast(self.inner), &st.inner);
        self.freeStage(st);
    }

    /// The metadata is not sealed: FileStorage reads it alone.
    fn loadSnapshotMetadata(ptr: *anyopaque) anyerror!?raft_lib.SnapshotMetadata {
        const self = cast(ptr);
        return self.innerStorage().loadSnapshotMetadata(self.allocator);
    }

    fn compact(ptr: *anyopaque, index: u64) anyerror!void {
        return cast(ptr).innerStorage().compact(index);
    }
};
