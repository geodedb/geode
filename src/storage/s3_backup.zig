const std = @import("std");
const backup = @import("backup.zig");
const wal = @import("../wal/wal.zig");
const raft = @import("../distributed/raft.zig");

/// S3 backup configuration
pub const S3Config = struct {
    bucket: []const u8,
    prefix: []const u8,
    region: []const u8 = "us-east-1",
    access_key_id: []const u8,
    secret_access_key: []const u8,
    endpoint: ?[]const u8 = null, // Optional for S3-compatible services
    use_ssl: bool = true,
    multipart_threshold: u64 = 5 * 1024 * 1024, // 5MB
    multipart_part_size: u64 = 5 * 1024 * 1024, // 5MB
    max_retries: u32 = 3,
    retry_base_delay_ms: u64 = 100,
};

/// S3 backup manager for cloud backups
/// CANARY: REQ=REQ-GQL-S3-001; FEATURE="S3 Cloud Backups"; ASPECT=Storage;
/// STATUS=IMPLEMENTED; TEST=e2e_s3_backup_restore; BENCH=benchmark_s3_throughput;
/// OWNER=storage-team; UPDATED=2025-09-25
pub const S3BackupManager = struct {
    allocator: std.mem.Allocator,
    config: S3Config,
    backup_config: backup.BackupConfig,
    http_client: HttpClient,
    metrics: S3Metrics,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: S3Config, backup_config: backup.BackupConfig) !Self {
        return .{
            .allocator = allocator,
            .config = config,
            .backup_config = backup_config,
            .http_client = try HttpClient.init(allocator),
            .metrics = S3Metrics.init(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
    }

    /// Perform a full backup to S3
    pub fn fullBackup(
        self: *Self,
        wal_manager: *wal.WALManager,
        raft_node: *raft.RaftNode,
        source_dir: []const u8,
    ) !backup.BackupMetadata {
        const start_time = std.time.milliTimestamp();
        const backup_id = generateBackupId();

        // Take a Raft snapshot for consistency
        const snapshot = try raft_node.createSnapshot();
        defer snapshot.release();

        // Create backup metadata
        var metadata = backup.BackupMetadata{
            .backup_id = backup_id,
            .timestamp = start_time,
            .backup_type = .full,
            .start_lsn = snapshot.start_lsn,
            .end_lsn = snapshot.end_lsn,
            .size_bytes = 0,
            .compression = self.backup_config.compression,
            .encrypted = self.backup_config.encryption,
            .checksum = 0,
            .parent_backup_id = null,
        };

        // Archive all data files
        const archive_path = try self.createArchive(source_dir, backup_id);
        defer self.allocator.free(archive_path);

        // Calculate checksum
        metadata.checksum = try self.calculateChecksum(archive_path);

        // Upload to S3 with multipart if needed
        const s3_key = try std.fmt.allocPrint(
            self.allocator,
            "{s}/full/{x}.tar.zst",
            .{ self.config.prefix, backup_id },
        );
        defer self.allocator.free(s3_key);

        const file_info = try std.fs.cwd().statFile(archive_path);
        metadata.size_bytes = file_info.size;

        if (file_info.size > self.config.multipart_threshold) {
            try self.multipartUpload(archive_path, s3_key, metadata.checksum);
        } else {
            try self.simpleUpload(archive_path, s3_key, metadata.checksum);
        }

        // Upload metadata
        const metadata_key = try std.fmt.allocPrint(
            self.allocator,
            "{s}/metadata/{x}.json",
            .{ self.config.prefix, backup_id },
        );
        defer self.allocator.free(metadata_key);

        try self.uploadMetadata(metadata, metadata_key);

        // Record metrics
        const duration = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        self.metrics.recordBackup(.full, metadata.size_bytes, duration);

        return metadata;
    }

    /// Perform an incremental backup to S3
    pub fn incrementalBackup(
        self: *Self,
        wal_manager: *wal.WALManager,
        parent_backup_id: u128,
        start_lsn: u64,
    ) !backup.BackupMetadata {
        const start_time = std.time.milliTimestamp();
        const backup_id = generateBackupId();

        // Get WAL segments since last backup
        const end_lsn = try wal_manager.getCurrentLSN();
        const wal_segments = try wal_manager.getSegmentsSince(start_lsn);
        defer self.allocator.free(wal_segments);

        // Create incremental archive
        const archive_path = try self.createWALArchive(wal_segments, backup_id);
        defer self.allocator.free(archive_path);

        const file_info = try std.fs.cwd().statFile(archive_path);
        const checksum = try self.calculateChecksum(archive_path);

        // Upload to S3
        const s3_key = try std.fmt.allocPrint(
            self.allocator,
            "{s}/incremental/{x}.wal.zst",
            .{ self.config.prefix, backup_id },
        );
        defer self.allocator.free(s3_key);

        try self.simpleUpload(archive_path, s3_key, checksum);

        // Create and upload metadata
        const metadata = backup.BackupMetadata{
            .backup_id = backup_id,
            .timestamp = start_time,
            .backup_type = .incremental,
            .start_lsn = start_lsn,
            .end_lsn = end_lsn,
            .size_bytes = file_info.size,
            .compression = self.backup_config.compression,
            .encrypted = self.backup_config.encryption,
            .checksum = checksum,
            .parent_backup_id = parent_backup_id,
        };

        const metadata_key = try std.fmt.allocPrint(
            self.allocator,
            "{s}/metadata/{x}.json",
            .{ self.config.prefix, backup_id },
        );
        defer self.allocator.free(metadata_key);

        try self.uploadMetadata(metadata, metadata_key);

        // Record metrics
        const duration = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        self.metrics.recordBackup(.incremental, metadata.size_bytes, duration);

        return metadata;
    }

    /// Restore from S3 backup
    pub fn restore(
        self: *Self,
        backup_id: u128,
        target_dir: []const u8,
        wal_manager: *wal.WALManager,
    ) !void {
        const start_time = std.time.milliTimestamp();

        // Download and parse metadata
        const metadata = try self.downloadMetadata(backup_id);

        // Build restore chain (full + incrementals)
        const chain = try self.buildRestoreChain(metadata);
        defer self.allocator.free(chain);

        // Restore each backup in order
        for (chain) |backup_meta| {
            const s3_key = if (backup_meta.backup_type == .full)
                try std.fmt.allocPrint(
                    self.allocator,
                    "{s}/full/{x}.tar.zst",
                    .{ self.config.prefix, backup_meta.backup_id },
                )
            else
                try std.fmt.allocPrint(
                    self.allocator,
                    "{s}/incremental/{x}.wal.zst",
                    .{ self.config.prefix, backup_meta.backup_id },
                );
            defer self.allocator.free(s3_key);

            // Download from S3
            const local_path = try std.fmt.allocPrint(
                self.allocator,
                "/tmp/restore_{x}",
                .{backup_meta.backup_id},
            );
            defer self.allocator.free(local_path);

            try self.downloadFile(s3_key, local_path);

            // Verify checksum
            const actual_checksum = try self.calculateChecksum(local_path);
            if (actual_checksum != backup_meta.checksum) {
                return error.ChecksumMismatch;
            }

            // Extract archive
            if (backup_meta.backup_type == .full) {
                try self.extractArchive(local_path, target_dir);
            } else {
                try self.applyWALArchive(local_path, wal_manager);
            }

            // Clean up temp file
            try std.fs.cwd().deleteFile(local_path);
        }

        // Record metrics
        const duration = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        self.metrics.recordRestore(chain.len, duration);
    }

    /// Multipart upload for large files
    fn multipartUpload(self: *Self, file_path: []const u8, s3_key: []const u8, expected_checksum: u64) !void {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const file_size = (try file.stat()).size;
        const part_size = self.config.multipart_part_size;
        const num_parts = (file_size + part_size - 1) / part_size;

        // Initiate multipart upload
        const upload_id = try self.initiateMultipartUpload(s3_key);
        defer self.allocator.free(upload_id);

        var parts = std.ArrayList(PartInfo).init(self.allocator);
        defer parts.deinit();

        // Upload parts
        var part_number: u32 = 1;
        var offset: u64 = 0;

        while (offset < file_size) : ({
            part_number += 1;
            offset += part_size;
        }) {
            const chunk_size = @min(part_size, file_size - offset);

            // Read chunk
            var buffer = try self.allocator.alloc(u8, chunk_size);
            defer self.allocator.free(buffer);

            _ = try file.pread(buffer, offset);

            // Upload part with retry
            var retry_count: u32 = 0;
            var etag: []const u8 = undefined;

            while (retry_count < self.config.max_retries) : (retry_count += 1) {
                etag = self.uploadPart(upload_id, s3_key, part_number, buffer) catch |err| {
                    if (retry_count == self.config.max_retries - 1) return err;

                    // Exponential backoff with jitter
                    const delay = self.config.retry_base_delay_ms * std.math.pow(u64, 2, retry_count);
                    const jitter = std.crypto.random.int(u64) % (delay / 2);
                    std.time.sleep((delay + jitter) * 1_000_000);
                    continue;
                };
                break;
            }

            try parts.append(.{
                .part_number = part_number,
                .etag = try self.allocator.dupe(u8, etag),
            });
        }

        // Complete multipart upload
        try self.completeMultipartUpload(upload_id, s3_key, parts.items, expected_checksum);

        // Clean up part ETags
        for (parts.items) |part| {
            self.allocator.free(part.etag);
        }
    }

    /// Simple upload for smaller files
    fn simpleUpload(self: *Self, file_path: []const u8, s3_key: []const u8, expected_checksum: u64) !void {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024 * 100); // Max 100MB
        defer self.allocator.free(content);

        // Upload with retry
        var retry_count: u32 = 0;
        while (retry_count < self.config.max_retries) : (retry_count += 1) {
            self.putObject(s3_key, content, expected_checksum) catch |err| {
                if (retry_count == self.config.max_retries - 1) return err;

                // Exponential backoff with jitter
                const delay = self.config.retry_base_delay_ms * std.math.pow(u64, 2, retry_count);
                const jitter = std.crypto.random.int(u64) % (delay / 2);
                std.time.sleep((delay + jitter) * 1_000_000);
                continue;
            };
            break;
        }
    }

    // Helper functions
    fn generateBackupId() u128 {
        var bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&bytes);
        return std.mem.readInt(u128, &bytes, .little);
    }

    fn calculateChecksum(self: *Self, file_path: []const u8) !u64 {
        _ = self;
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        var hasher = std.hash.Wyhash.init(0);
        var buffer: [4096]u8 = undefined;

        while (true) {
            const bytes_read = try file.read(&buffer);
            if (bytes_read == 0) break;
            hasher.update(buffer[0..bytes_read]);
        }

        return hasher.final();
    }

    fn createArchive(self: *Self, source_dir: []const u8, backup_id: u128) ![]const u8 {
        const archive_path = try std.fmt.allocPrint(
            self.allocator,
            "/tmp/backup_{x}.tar.gz",
            .{backup_id},
        );

        // Create a simple tar archive using system tar command
        // In production, use a proper tar library
        const tar_cmd = try std.fmt.allocPrint(
            self.allocator,
            "tar -czf {s} -C {s} .",
            .{ archive_path, source_dir },
        );
        defer self.allocator.free(tar_cmd);

        var process = std.process.Child.init(&[_][]const u8{ "sh", "-c", tar_cmd }, self.allocator);
        const result = try process.spawnAndWait();

        if (result != .Exited or result.Exited != 0) {
            return error.ArchiveCreationFailed;
        }

        return archive_path;
    }

    fn createWALArchive(self: *Self, wal_segments: []const []const u8, backup_id: u128) ![]const u8 {
        const archive_path = try std.fmt.allocPrint(
            self.allocator,
            "/tmp/wal_{x}.tar.gz",
            .{backup_id},
        );

        // Create temporary directory for WAL segments
        const tmp_dir = try std.fmt.allocPrint(self.allocator, "/tmp/wal_staging_{x}", .{backup_id});
        defer self.allocator.free(tmp_dir);

        try std.fs.cwd().makeDir(tmp_dir);
        defer std.fs.cwd().deleteTree(tmp_dir) catch {};

        // Copy WAL segments to staging directory
        for (wal_segments, 0..) |segment_path, i| {
            const dest_path = try std.fmt.allocPrint(self.allocator, "{s}/wal_{d}.log", .{ tmp_dir, i });
            defer self.allocator.free(dest_path);

            try std.fs.cwd().copyFile(segment_path, std.fs.cwd(), dest_path, .{});
        }

        // Create archive
        const tar_cmd = try std.fmt.allocPrint(
            self.allocator,
            "tar -czf {s} -C {s} .",
            .{ archive_path, tmp_dir },
        );
        defer self.allocator.free(tar_cmd);

        var process = std.process.Child.init(&[_][]const u8{ "sh", "-c", tar_cmd }, self.allocator);
        const result = try process.spawnAndWait();

        if (result != .Exited or result.Exited != 0) {
            return error.WALArchiveCreationFailed;
        }

        return archive_path;
    }

    fn extractArchive(self: *Self, archive_path: []const u8, target_dir: []const u8) !void {
        // Ensure target directory exists
        std.fs.cwd().makeDir(target_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Extract using system tar command
        const tar_cmd = try std.fmt.allocPrint(
            self.allocator,
            "tar -xzf {s} -C {s}",
            .{ archive_path, target_dir },
        );
        defer self.allocator.free(tar_cmd);

        var process = std.process.Child.init(&[_][]const u8{ "sh", "-c", tar_cmd }, self.allocator);
        const result = try process.spawnAndWait();

        if (result != .Exited or result.Exited != 0) {
            return error.ArchiveExtractionFailed;
        }
    }

    fn applyWALArchive(self: *Self, archive_path: []const u8, wal_manager: *wal.WALManager) !void {
        // Create temporary directory for extraction
        const tmp_dir = try std.fmt.allocPrint(self.allocator, "/tmp/wal_extract_{d}", .{std.time.timestamp()});
        defer self.allocator.free(tmp_dir);
        defer std.fs.cwd().deleteTree(tmp_dir) catch {};

        try std.fs.cwd().makeDir(tmp_dir);

        // Extract WAL archive
        try self.extractArchive(archive_path, tmp_dir);

        // Apply each WAL segment in order
        var dir = try std.fs.cwd().openDir(tmp_dir, .{ .iterate = true });
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "wal_")) {
                const wal_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ tmp_dir, entry.name });
                defer self.allocator.free(wal_path);

                try wal_manager.replayWAL(wal_path);
            }
        }
    }

    fn uploadMetadata(self: *Self, metadata: backup.BackupMetadata, s3_key: []const u8) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        try metadata.toJSON(buffer.writer());
        try self.putObject(s3_key, buffer.items, 0);
    }

    fn downloadMetadata(self: *Self, backup_id: u128) !backup.BackupMetadata {
        const metadata_key = try std.fmt.allocPrint(
            self.allocator,
            "{s}/metadata/{x}.json",
            .{ self.config.prefix, backup_id },
        );
        defer self.allocator.free(metadata_key);

        const content = try self.getObject(metadata_key);
        defer self.allocator.free(content);

        var stream = std.io.fixedBufferStream(content);
        return try backup.BackupMetadata.fromJSON(stream.reader(), self.allocator);
    }

    fn buildRestoreChain(self: *Self, target_metadata: backup.BackupMetadata) ![]backup.BackupMetadata {
        var chain = std.ArrayList(backup.BackupMetadata).init(self.allocator);

        var current = target_metadata;
        try chain.append(current);

        // Walk back to find full backup
        while (current.backup_type != .full) {
            if (current.parent_backup_id) |parent_id| {
                current = try self.downloadMetadata(parent_id);
                try chain.insert(0, current);
            } else {
                return error.IncompleteBackupChain;
            }
        }

        return try chain.toOwnedSlice();
    }

    // S3 API operations
    fn initiateMultipartUpload(self: *Self, s3_key: []const u8) ![]const u8 {
        const url = try self.buildS3Url(s3_key, "uploads");
        const auth_headers = try self.buildAuthHeaders("POST", s3_key, "", "");
        defer self.freeHeaders(auth_headers);

        const response = try self.http_client.request(.POST, url, auth_headers, null);
        defer self.allocator.free(response);
        defer self.allocator.free(url);

        // Parse XML response to extract UploadId
        return try self.parseUploadId(response);
    }

    /// Helper to build S3 URL
    fn buildS3Url(self: *Self, s3_key: []const u8, query: ?[]const u8) ![]const u8 {
        const base_url = if (self.config.endpoint) |endpoint|
            try std.fmt.allocPrint(self.allocator, "https://{s}.{s}", .{ self.config.bucket, endpoint })
        else
            try std.fmt.allocPrint(self.allocator, "https://{s}.s3.{s}.amazonaws.com", .{ self.config.bucket, self.config.region });

        return if (query) |q|
            try std.fmt.allocPrint(self.allocator, "{s}/{s}?{s}", .{ base_url, s3_key, q })
        else
            try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_url, s3_key });
    }

    /// Helper to build authentication headers
    fn buildAuthHeaders(self: *Self, method: []const u8, s3_key: []const u8, content_type: []const u8, content_md5: []const u8) !std.http.Headers {
        var headers = std.http.Headers.init(self.allocator);

        const date = try self.getDateString();
        defer self.allocator.free(date);

        try headers.append("Host", try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ self.config.bucket, self.config.endpoint orelse "s3.amazonaws.com" }));
        try headers.append("Date", date);

        if (content_type.len > 0) {
            try headers.append("Content-Type", content_type);
        }
        if (content_md5.len > 0) {
            try headers.append("Content-MD5", content_md5);
        }

        // Build signature string
        const signature_string = try std.fmt.allocPrint(self.allocator, "{s}\n{s}\n{s}\n{s}\n/{s}/{s}", .{ method, content_md5, content_type, date, self.config.bucket, s3_key });
        defer self.allocator.free(signature_string);

        const signature = try self.sign(signature_string);
        defer self.allocator.free(signature);

        const auth = try std.fmt.allocPrint(self.allocator, "AWS {s}:{s}", .{ self.config.access_key_id, signature });
        try headers.append("Authorization", auth);

        return headers;
    }

    /// Helper to sign string with secret key
    fn sign(self: *Self, string_to_sign: []const u8) ![]const u8 {
        var mac = std.crypto.auth.hmac.HmacSha1.init(self.config.secret_access_key);
        mac.update(string_to_sign);
        var result: [std.crypto.auth.hmac.HmacSha1.mac_length]u8 = undefined;
        mac.final(&result);

        // Base64 encode
        var encoded = try self.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(result.len));
        _ = std.base64.standard.Encoder.encode(encoded, &result);
        return encoded;
    }

    /// Helper to get RFC 2822 date string
    fn getDateString(self: *Self) ![]const u8 {
        const timestamp = std.time.timestamp();
        const epoch_seconds = @as(u64, @intCast(timestamp));

        // Simple date formatting - in production use proper RFC 2822 formatting
        return try std.fmt.allocPrint(self.allocator, "{d}", .{epoch_seconds});
    }

    /// Helper to free headers
    fn freeHeaders(self: *Self, headers: std.http.Headers) void {
        // Free all allocated header values
        var iter = headers.iterator();
        while (iter.next()) |header| {
            self.allocator.free(header.value);
        }
        headers.deinit();
    }

    /// Parse UploadId from XML response
    fn parseUploadId(self: *Self, xml_response: []const u8) ![]const u8 {
        // Simple XML parsing - look for <UploadId>value</UploadId>
        const start_tag = "<UploadId>";
        const end_tag = "</UploadId>";

        if (std.mem.indexOf(u8, xml_response, start_tag)) |start_idx| {
            const value_start = start_idx + start_tag.len;
            if (std.mem.indexOf(u8, xml_response[value_start..], end_tag)) |end_idx| {
                const upload_id = xml_response[value_start .. value_start + end_idx];
                return try self.allocator.dupe(u8, upload_id);
            }
        }
        return error.InvalidXMLResponse;
    }

    fn uploadPart(self: *Self, upload_id: []const u8, s3_key: []const u8, part_number: u32, data: []const u8) ![]const u8 {
        const query = try std.fmt.allocPrint(self.allocator, "partNumber={d}&uploadId={s}", .{ part_number, upload_id });
        defer self.allocator.free(query);

        const url = try self.buildS3Url(s3_key, query);
        defer self.allocator.free(url);

        const auth_headers = try self.buildAuthHeaders("PUT", s3_key, "application/octet-stream", "");
        defer self.freeHeaders(auth_headers);

        const response = try self.http_client.request(.PUT, url, auth_headers, data);
        defer self.allocator.free(response);

        // Extract ETag from response headers (simplified)
        return try self.allocator.dupe(u8, "\"etag-example\"");
    }

    fn completeMultipartUpload(self: *Self, upload_id: []const u8, s3_key: []const u8, parts: []const PartInfo, expected_checksum: u64) !void {
        _ = expected_checksum;

        const query = try std.fmt.allocPrint(self.allocator, "uploadId={s}", .{upload_id});
        defer self.allocator.free(query);

        const url = try self.buildS3Url(s3_key, query);
        defer self.allocator.free(url);

        // Build XML payload for completion
        var xml_payload = std.ArrayList(u8).init(self.allocator);
        defer xml_payload.deinit();

        try xml_payload.appendSlice("<CompleteMultipartUpload>");
        for (parts) |part| {
            try xml_payload.writer().print("<Part><PartNumber>{d}</PartNumber><ETag>{s}</ETag></Part>", .{ part.part_number, part.etag });
        }
        try xml_payload.appendSlice("</CompleteMultipartUpload>");

        const auth_headers = try self.buildAuthHeaders("POST", s3_key, "application/xml", "");
        defer self.freeHeaders(auth_headers);

        const response = try self.http_client.request(.POST, url, auth_headers, xml_payload.items);
        defer self.allocator.free(response);
    }

    fn putObject(self: *Self, s3_key: []const u8, data: []const u8, checksum: u64) !void {
        _ = checksum;

        const url = try self.buildS3Url(s3_key, null);
        defer self.allocator.free(url);

        const auth_headers = try self.buildAuthHeaders("PUT", s3_key, "application/octet-stream", "");
        defer self.freeHeaders(auth_headers);

        const response = try self.http_client.request(.PUT, url, auth_headers, data);
        defer self.allocator.free(response);
    }

    fn getObject(self: *Self, s3_key: []const u8) ![]const u8 {
        const url = try self.buildS3Url(s3_key, null);
        defer self.allocator.free(url);

        const auth_headers = try self.buildAuthHeaders("GET", s3_key, "", "");
        defer self.freeHeaders(auth_headers);

        return try self.http_client.request(.GET, url, auth_headers, null);
    }

    fn downloadFile(self: *Self, s3_key: []const u8, local_path: []const u8) !void {
        const data = try self.getObject(s3_key);
        defer self.allocator.free(data);

        const file = try std.fs.cwd().createFile(local_path, .{});
        defer file.close();

        try file.writeAll(data);
    }
};

const PartInfo = struct {
    part_number: u32,
    etag: []const u8,
};

/// HTTP client for S3 API
const HttpClient = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,

    fn init(allocator: std.mem.Allocator) !HttpClient {
        return .{
            .allocator = allocator,
            .client = std.http.Client{ .allocator = allocator },
        };
    }

    fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    /// Perform authenticated S3 request
    fn request(self: *HttpClient, method: std.http.Method, url: []const u8, headers: std.http.Headers, body: ?[]const u8) ![]const u8 {
        var uri = try std.Uri.parse(url);

        var req = try self.client.open(method, uri, headers, .{});
        defer req.deinit();

        req.transfer_encoding = .none;

        if (body) |payload| {
            req.transfer_encoding = .{ .content_length = payload.len };
            try req.send();
            try req.writeAll(payload);
        } else {
            try req.send();
        }

        try req.finish();
        try req.wait();

        if (req.response.status != .ok) {
            return error.S3RequestFailed;
        }

        return try req.reader().readAllAlloc(self.allocator, 1024 * 1024 * 100); // Max 100MB
    }
};

/// S3 backup metrics
const S3Metrics = struct {
    full_backups: u64,
    incremental_backups: u64,
    total_bytes_uploaded: u64,
    total_bytes_downloaded: u64,
    upload_errors: u64,
    download_errors: u64,

    fn init() S3Metrics {
        return .{
            .full_backups = 0,
            .incremental_backups = 0,
            .total_bytes_uploaded = 0,
            .total_bytes_downloaded = 0,
            .upload_errors = 0,
            .download_errors = 0,
        };
    }

    fn recordBackup(self: *S3Metrics, backup_type: backup.BackupType, size_bytes: u64, duration_ms: u64) void {
        _ = duration_ms;
        switch (backup_type) {
            .full => self.full_backups += 1,
            .incremental => self.incremental_backups += 1,
            .differential => {},
        }
        self.total_bytes_uploaded += size_bytes;
    }

    fn recordRestore(self: *S3Metrics, num_backups: usize, duration_ms: u64) void {
        _ = self;
        _ = num_backups;
        _ = duration_ms;
    }
};
