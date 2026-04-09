// Append-only binary log storage for Raft consensus entries.
//
// Binary record format (little-endian):
//   [entry_len: u32]     — total size of header + command_bytes (excludes entry_len and crc)
//   [term: u64]
//   [index: u64]
//   [timestamp: i64]
//   [client_id: u64]     — 0 encodes null
//   [serial_number: u64] — 0 encodes null
//   [command_bytes: var]  — serialized via serializeCommand
//   [crc32: u32]         — CRC of bytes from term through command_bytes
//
// Fixed header = 40 bytes (5 x 8-byte fields).
//
// CANARY: REQ=REQ-GQL-RAFT-LOG-PERSIST; FEATURE="Raft Log Persistence"; ASPECT=FileFormat; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-09

const std = @import("std");
const Allocator = std.mem.Allocator;
const Crc32 = std.hash.crc.Crc32;
const raft_consensus = @import("raft_consensus.zig");
const LogEntry = raft_consensus.LogEntry;
const Command = raft_consensus.Command;
const serializeCommand = raft_consensus.serializeCommand;
const deserializeCommand = raft_consensus.deserializeCommand;

const HEADER_SIZE: usize = 40; // 5 x u64/i64 = 40 bytes

pub const LogStorage = struct {
    allocator: Allocator,
    file_path: []const u8,
    file: std.fs.File,

    /// Open or create the log file at `file_path`.
    pub fn init(allocator: Allocator, file_path: []const u8) !LogStorage {
        const file = std.fs.cwd().createFile(file_path, .{
            .truncate = false,
            .read = true,
        }) catch |err| {
            if (err == error.FileNotFound) {
                // Parent directory may not exist — try to create it.
                if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |sep| {
                    try std.fs.cwd().makePath(file_path[0..sep]);
                    return LogStorage{
                        .allocator = allocator,
                        .file_path = file_path,
                        .file = try std.fs.cwd().createFile(file_path, .{
                            .truncate = false,
                            .read = true,
                        }),
                    };
                }
            }
            return err;
        };

        return LogStorage{
            .allocator = allocator,
            .file_path = file_path,
            .file = file,
        };
    }

    /// Close the log file.
    pub fn deinit(self: *LogStorage) void {
        self.file.close();
    }

    /// Append a single entry to the log with fsync.
    /// CANARY: REQ=REQ-GQL-RAFT-LOG-PERSIST; FEATURE="Raft Log Persistence"; ASPECT=Append; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-09
    pub fn appendEntry(self: *LogStorage, entry: LogEntry) !void {
        // Serialize the command
        const cmd_bytes = try serializeCommand(self.allocator, entry.command);
        defer self.allocator.free(cmd_bytes);

        const record_len: u32 = @intCast(HEADER_SIZE + cmd_bytes.len);

        // Build the record body (header + command) for CRC computation
        var body_buf = try self.allocator.alloc(u8, HEADER_SIZE + cmd_bytes.len);
        defer self.allocator.free(body_buf);

        var pos: usize = 0;
        std.mem.writeInt(u64, body_buf[pos..][0..8], entry.term, .little);
        pos += 8;
        std.mem.writeInt(u64, body_buf[pos..][0..8], entry.index, .little);
        pos += 8;
        std.mem.writeInt(i64, body_buf[pos..][0..8], entry.timestamp, .little);
        pos += 8;
        std.mem.writeInt(u64, body_buf[pos..][0..8], entry.client_id orelse 0, .little);
        pos += 8;
        std.mem.writeInt(u64, body_buf[pos..][0..8], entry.serial_number orelse 0, .little);
        pos += 8;
        @memcpy(body_buf[pos..], cmd_bytes);

        const crc = Crc32.hash(body_buf);

        // Seek to end of file
        try self.file.seekFromEnd(0);

        // Write entry_len
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, record_len, .little);
        try self.file.writeAll(&len_buf);

        // Write body (header + command)
        try self.file.writeAll(body_buf);

        // Write CRC32
        var crc_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_buf, crc, .little);
        try self.file.writeAll(&crc_buf);

        // Fsync for durability
        try self.file.sync();
    }

    /// Read all entries from the log, verifying CRC for each record.
    /// Caller owns the returned slice and must free each entry's command data
    /// (for .write variants) and the slice itself.
    /// CANARY: REQ=REQ-GQL-RAFT-LOG-PERSIST; FEATURE="Raft Log Persistence"; ASPECT=ReadAll; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-09
    pub fn readAllEntries(self: *LogStorage, allocator: Allocator) ![]LogEntry {
        try self.file.seekTo(0);

        var entries: std.ArrayList(LogEntry) = .empty;
        errdefer {
            for (entries.items) |e| {
                freeEntryCommand(allocator, e);
            }
            entries.deinit(allocator);
        }

        while (true) {
            // Read entry_len
            var len_buf: [4]u8 = undefined;
            const len_read = self.file.readAll(&len_buf) catch break;
            if (len_read == 0) break; // EOF
            if (len_read < 4) return error.UnexpectedEof;

            const record_len = std.mem.readInt(u32, &len_buf, .little);
            if (record_len < HEADER_SIZE) return error.InvalidRecordLength;

            // Read body (header + command_bytes)
            const body = try allocator.alloc(u8, record_len);
            defer allocator.free(body);

            const body_read = try self.file.readAll(body);
            if (body_read < record_len) return error.UnexpectedEof;

            // Read CRC
            var crc_buf: [4]u8 = undefined;
            const crc_read = try self.file.readAll(&crc_buf);
            if (crc_read < 4) return error.UnexpectedEof;

            const stored_crc = std.mem.readInt(u32, &crc_buf, .little);
            const computed_crc = Crc32.hash(body);
            if (stored_crc != computed_crc) return error.CrcMismatch;

            // Parse header fields
            const term = std.mem.readInt(u64, body[0..8], .little);
            const index = std.mem.readInt(u64, body[8..16], .little);
            const timestamp = std.mem.readInt(i64, body[16..24], .little);
            const raw_client_id = std.mem.readInt(u64, body[24..32], .little);
            const raw_serial = std.mem.readInt(u64, body[32..40], .little);

            const client_id: ?u64 = if (raw_client_id == 0) null else raw_client_id;
            const serial_number: ?u64 = if (raw_serial == 0) null else raw_serial;

            // Deserialize command — the returned Command borrows from body, so
            // we must make an owned copy of the command bytes for .write payloads.
            const cmd_data = body[HEADER_SIZE..];
            const raw_cmd = try deserializeCommand(cmd_data);

            const command: Command = switch (raw_cmd) {
                .write => |data| blk: {
                    const owned = try allocator.alloc(u8, data.len);
                    @memcpy(owned, data);
                    break :blk .{ .write = owned };
                },
                else => raw_cmd,
            };

            try entries.append(allocator, .{
                .term = term,
                .index = index,
                .command = command,
                .timestamp = timestamp,
                .client_id = client_id,
                .serial_number = serial_number,
            });
        }

        return entries.toOwnedSlice(allocator);
    }

    /// Remove all entries with index > last_index.
    /// Re-reads the log to find the byte offset of the first entry past last_index,
    /// then truncates the file.
    /// CANARY: REQ=REQ-GQL-RAFT-LOG-PERSIST; FEATURE="Raft Log Persistence"; ASPECT=Truncate; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-09
    pub fn truncateAfter(self: *LogStorage, last_index: u64, allocator: Allocator) !void {
        try self.file.seekTo(0);

        var truncate_offset: u64 = 0;

        while (true) {
            // Record current position — this is where the current record starts
            const record_start = try self.file.getPos();

            // Read entry_len
            var len_buf: [4]u8 = undefined;
            const len_read = self.file.readAll(&len_buf) catch break;
            if (len_read == 0) break;
            if (len_read < 4) break;

            const record_len = std.mem.readInt(u32, &len_buf, .little);
            if (record_len < HEADER_SIZE) break;

            // Read body
            const body = try allocator.alloc(u8, record_len);
            defer allocator.free(body);

            const body_read = try self.file.readAll(body);
            if (body_read < record_len) break;

            // Skip CRC
            try self.file.seekBy(4);

            // Parse index from body (offset 8..16)
            const index = std.mem.readInt(u64, body[8..16], .little);

            if (index <= last_index) {
                // This record is kept — update truncate offset to after this record
                truncate_offset = record_start + 4 + record_len + 4; // entry_len + body + crc
            } else {
                // This record and everything after should be removed.
                // We already know the truncate point from the previous iteration.
                break;
            }
        }

        // Truncate the file
        try self.file.setEndPos(truncate_offset);

        try self.file.sync();
    }

    /// Return the index of the last entry, or 0 if the log is empty.
    /// CANARY: REQ=REQ-GQL-RAFT-LOG-PERSIST; FEATURE="Raft Log Persistence"; ASPECT=LastIndex; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-09
    pub fn lastIndex(self: *LogStorage, allocator: Allocator) !u64 {
        try self.file.seekTo(0);

        var last: u64 = 0;

        while (true) {
            var len_buf: [4]u8 = undefined;
            const len_read = self.file.readAll(&len_buf) catch break;
            if (len_read == 0) break;
            if (len_read < 4) break;

            const record_len = std.mem.readInt(u32, &len_buf, .little);
            if (record_len < HEADER_SIZE) break;

            // Read body to extract index
            const body = try allocator.alloc(u8, record_len);
            defer allocator.free(body);

            const body_read = try self.file.readAll(body);
            if (body_read < record_len) break;

            // Skip CRC
            try self.file.seekBy(4);

            const index = std.mem.readInt(u64, body[8..16], .little);
            if (index > last) {
                last = index;
            }
        }

        return last;
    }

    /// Free command data that was allocated during readAllEntries.
    fn freeEntryCommand(allocator: Allocator, entry: LogEntry) void {
        switch (entry.command) {
            .write => |data| allocator.free(data),
            else => {},
        }
    }
};
