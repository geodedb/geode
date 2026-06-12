//! S3 cloud backup manager (GraphStore snapshots).
//!
//! SEC-S3-SIGV2-01 (GAP-0885d): requests are signed with AWS Signature
//! Version 4 (header-based Authorization; see `s3_sigv4.zig`) — the legacy
//! SigV2 HMAC-SHA1 signing was removed. SigV4 is required by AWS and is also
//! supported by S3-compatible targets (DigitalOcean Spaces, MinIO, Ceph RGW),
//! so the existing `S3Config` endpoint/credential plumbing is unchanged.

const std = @import("std");
const geode = @import("geode");
const graph_store = geode.graph_store;
// Named module (build.zig `storage_backup_mod`) — backup.zig is already the
// root of the `storage/backup` module; a relative import would duplicate it.
const backup = @import("storage/backup");
// Named module (see build.zig `s3_sigv4_mod`) — the same file backs the
// SigV4 KAT suite, so a relative import here would split it across modules.
const sigv4 = @import("s3_sigv4");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

// Zig 0.16 compat: std.time.milliTimestamp/timestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}

// Zig 0.16 compat: std.time.sleep removed. Raw nanosleep on Linux, libc elsewhere.
fn compat_sleepMs(ms: u64) void {
    if (ms == 0) return;
    const ns: u64 = ms * std.time.ns_per_ms;
    if (comptime @import("builtin").os.tag == .linux) {
        const req = std.os.linux.timespec{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        };
        var rem: std.os.linux.timespec = undefined;
        _ = std.os.linux.nanosleep(&req, &rem);
    } else {
        const req = std.c.timespec{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
    }
}

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
// CANARY: REQ=REQ-GQL-S3-001; FEATURE="S3 Cloud Backups"; ASPECT=Storage; STATUS=TESTED; TEST=tests/test_s3_sigv4.zig; OWNER=storage; UPDATED=2026-06-10
// CANARY: REQ=REQ-SEC-S3-SIGV4-001; FEATURE="S3 SigV4 Signing"; ASPECT=Integration; STATUS=TESTED; TEST=tests/test_s3_sigv4.zig; OWNER=security; UPDATED=2026-06-10
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
            .http_client = HttpClient{ .allocator = allocator },
            .metrics = S3Metrics.init(),
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Perform a full backup to S3 (GraphStore snapshots only).
    pub fn fullBackup(
        self: *Self,
        store: *graph_store.GraphStore,
        backup_dir: []const u8,
    ) !backup.BackupMetadata {
        const start_time = compat_milliTimestamp();

        var mgr = try backup.BackupManager.init(self.allocator, backup_dir, self.backup_config, store);
        defer mgr.deinit();

        const metadata = try mgr.createFullBackup();

        const backup_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/full_{x}.backup",
            .{ backup_dir, metadata.backup_id },
        );
        defer self.allocator.free(backup_path);

        const s3_key = try std.fmt.allocPrint(
            self.allocator,
            "{s}/full/{x}.backup",
            .{ self.config.prefix, metadata.backup_id },
        );
        defer self.allocator.free(s3_key);

        const io = std.Io.Threaded.global_single_threaded.io();
        const file_info = try std.Io.Dir.cwd().statFile(io, backup_path, .{});
        if (file_info.size > self.config.multipart_threshold) {
            try self.multipartUpload(backup_path, s3_key, metadata.checksum);
        } else {
            try self.simpleUpload(backup_path, s3_key, metadata.checksum);
        }

        const metadata_key = try std.fmt.allocPrint(
            self.allocator,
            "{s}/metadata/{x}.json",
            .{ self.config.prefix, metadata.backup_id },
        );
        defer self.allocator.free(metadata_key);

        try self.uploadMetadata(metadata, metadata_key);

        const duration = @as(u64, @intCast(compat_milliTimestamp() - start_time));
        self.metrics.recordBackup(.full, metadata.size_bytes, duration);

        return metadata;
    }

    /// Restore from S3 backup (GraphStore snapshots only).
    pub fn restore(
        self: *Self,
        backup_id: u64,
        target_dir: []const u8,
        store: *graph_store.GraphStore,
    ) !void {
        const start_time = compat_milliTimestamp();

        const metadata = try self.downloadMetadata(backup_id);

        const io = std.Io.Threaded.global_single_threaded.io();
        const tmp_dir = try std.fmt.allocPrint(self.allocator, "/tmp/geode_s3_restore_{x}", .{backup_id});
        defer self.allocator.free(tmp_dir);
        std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        // error-policy: A — best-effort cleanup of the restore staging dir
        // under /tmp; a leftover tree affects nothing but disk hygiene.
        defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

        const s3_key = try std.fmt.allocPrint(
            self.allocator,
            "{s}/full/{x}.backup",
            .{ self.config.prefix, metadata.backup_id },
        );
        defer self.allocator.free(s3_key);

        const local_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/full_{x}.backup",
            .{ tmp_dir, metadata.backup_id },
        );
        defer self.allocator.free(local_path);

        try self.downloadFile(s3_key, local_path);

        // Write metadata log expected by BackupManager
        const metadata_path = try std.fmt.allocPrint(self.allocator, "{s}/metadata.json", .{tmp_dir});
        defer self.allocator.free(metadata_path);
        {
            const file = try std.Io.Dir.cwd().createFile(io, metadata_path, .{});
            defer file.close(io);
            const json_str = try std.json.Stringify.valueAlloc(self.allocator, &[_]backup.BackupMetadata{metadata}, .{});
            defer self.allocator.free(json_str);
            try file.writePositionalAll(io, json_str, 0);
        }

        var mgr = try backup.BackupManager.init(self.allocator, tmp_dir, self.backup_config, store);
        defer mgr.deinit();
        try mgr.restoreToPointInTime(target_dir, metadata.timestamp);

        const duration = @as(u64, @intCast(compat_milliTimestamp() - start_time));
        self.metrics.recordRestore(1, duration);
    }

    /// Multipart upload for large files
    fn multipartUpload(self: *Self, file_path: []const u8, s3_key: []const u8, expected_checksum: u64) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
        defer file.close(io);

        const file_size = (try file.stat(io)).size;
        const part_size = self.config.multipart_part_size;

        // Initiate multipart upload
        const upload_id = try self.initiateMultipartUpload(s3_key);
        defer self.allocator.free(upload_id);

        var parts: std.ArrayList(PartInfo) = .empty;
        defer {
            for (parts.items) |part| self.allocator.free(part.etag);
            parts.deinit(self.allocator);
        }

        // Upload parts
        var part_number: u32 = 1;
        var offset: u64 = 0;

        while (offset < file_size) : ({
            part_number += 1;
            offset += part_size;
        }) {
            const chunk_size = @min(part_size, file_size - offset);

            // Read chunk
            const buffer = try self.allocator.alloc(u8, @intCast(chunk_size));
            defer self.allocator.free(buffer);

            const n = try file.readPositionalAll(io, buffer, offset);
            if (n != buffer.len) return error.UnexpectedEndOfFile;

            // Upload part with retry (exponential backoff with jitter)
            const etag = try self.uploadPartWithRetry(upload_id, s3_key, part_number, buffer);
            errdefer self.allocator.free(etag);

            try parts.append(self.allocator, .{
                .part_number = part_number,
                .etag = etag,
            });
        }

        // Complete multipart upload
        try self.completeMultipartUpload(upload_id, s3_key, parts.items, expected_checksum);
    }

    fn uploadPartWithRetry(self: *Self, upload_id: []const u8, s3_key: []const u8, part_number: u32, data: []const u8) ![]const u8 {
        var retry_count: u32 = 0;
        while (true) : (retry_count += 1) {
            return self.uploadPart(upload_id, s3_key, part_number, data) catch |err| {
                if (retry_count + 1 >= self.config.max_retries) return err;
                self.backoff(retry_count);
                continue;
            };
        }
    }

    fn backoff(self: *Self, retry_count: u32) void {
        const delay = self.config.retry_base_delay_ms * std.math.pow(u64, 2, retry_count);
        const jitter = blk: {
            var rng_buf: [8]u8 = undefined;
            compat_fillRandom(&rng_buf);
            break :blk std.mem.readInt(u64, &rng_buf, .little) % @max(delay / 2, 1);
        };
        compat_sleepMs(delay + jitter);
    }

    /// Simple upload for smaller files
    fn simpleUpload(self: *Self, file_path: []const u8, s3_key: []const u8, expected_checksum: u64) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
        defer file.close(io);

        const stat = try file.stat(io);
        if (stat.size > 1024 * 1024 * 100) return error.FileTooLarge; // Max 100MB
        const content = try self.allocator.alloc(u8, @intCast(stat.size));
        defer self.allocator.free(content);
        const n = try file.readPositionalAll(io, content, 0);
        if (n != content.len) return error.UnexpectedEndOfFile;

        // Upload with retry
        var retry_count: u32 = 0;
        while (retry_count < self.config.max_retries) : (retry_count += 1) {
            self.putObject(s3_key, content, expected_checksum) catch |err| {
                if (retry_count == self.config.max_retries - 1) return err;
                self.backoff(retry_count);
                continue;
            };
            break;
        }
    }

    fn uploadMetadata(self: *Self, metadata: backup.BackupMetadata, s3_key: []const u8) !void {
        const json_str = try std.json.Stringify.valueAlloc(self.allocator, metadata, .{});
        defer self.allocator.free(json_str);
        try self.putObject(s3_key, json_str, 0);
    }

    fn downloadMetadata(self: *Self, backup_id: u64) !backup.BackupMetadata {
        const metadata_key = try std.fmt.allocPrint(
            self.allocator,
            "{s}/metadata/{x}.json",
            .{ self.config.prefix, backup_id },
        );
        defer self.allocator.free(metadata_key);

        const content = try self.getObject(metadata_key);
        defer self.allocator.free(content);

        const parsed = try std.json.parseFromSlice(backup.BackupMetadata, self.allocator, content, .{});
        defer parsed.deinit();
        return parsed.value;
    }

    // ------------------------------------------------------------------
    // SigV4 request signing (SEC-S3-SIGV2-01)
    // ------------------------------------------------------------------

    /// Owned strings backing one signed request.
    const SignedRequest = struct {
        url: []u8,
        host: []u8,
        amz_date: []u8,
        payload_hash: []u8,
        authorization: []u8,

        fn deinit(self: *const SignedRequest, allocator: std.mem.Allocator) void {
            allocator.free(self.url);
            allocator.free(self.host);
            allocator.free(self.amz_date);
            allocator.free(self.payload_hash);
            allocator.free(self.authorization);
        }

        /// x-amz-* headers to send (Authorization rides the typed slot).
        fn extraHeaders(self: *const SignedRequest) [2]std.http.Header {
            return .{
                .{ .name = "x-amz-date", .value = self.amz_date },
                .{ .name = "x-amz-content-sha256", .value = self.payload_hash },
            };
        }
    };

    /// Build the request URL and the SigV4 Authorization header for one
    /// S3 operation. The signed header set is host + x-amz-content-sha256 +
    /// x-amz-date (the S3 minimum); the canonical URI/query used for signing
    /// are byte-identical to the URL actually requested.
    fn signRequest(
        self: *Self,
        method: []const u8,
        s3_key: []const u8,
        query_params: []const sigv4.QueryParam,
        payload: []const u8,
    ) !SignedRequest {
        const allocator = self.allocator;

        const encoded_key = try sigv4.uriEncodePath(allocator, s3_key);
        defer allocator.free(encoded_key);
        const canonical_uri = try std.fmt.allocPrint(allocator, "/{s}", .{encoded_key});
        defer allocator.free(canonical_uri);
        const canonical_query = try sigv4.buildCanonicalQuery(allocator, query_params);
        defer allocator.free(canonical_query);

        const host = if (self.config.endpoint) |endpoint|
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ self.config.bucket, endpoint })
        else
            try std.fmt.allocPrint(allocator, "{s}.s3.{s}.amazonaws.com", .{ self.config.bucket, self.config.region });
        errdefer allocator.free(host);

        const now: u64 = @intCast(@max(compat_timestamp(), 0));
        const amz_date_buf = sigv4.formatAmzDate(now);
        const amz_date = try allocator.dupe(u8, &amz_date_buf);
        errdefer allocator.free(amz_date);

        const payload_hash_buf = sigv4.hashPayloadHex(payload);
        const payload_hash = try allocator.dupe(u8, &payload_hash_buf);
        errdefer allocator.free(payload_hash);

        const signed_headers = [_]sigv4.Header{
            .{ .name = "host", .value = host },
            .{ .name = "x-amz-content-sha256", .value = payload_hash },
            .{ .name = "x-amz-date", .value = amz_date },
        };

        const authorization = try sigv4.authorizationHeader(allocator, .{
            .method = method,
            .canonical_uri = canonical_uri,
            .canonical_query = canonical_query,
            .headers = &signed_headers,
            .payload_hash_hex = payload_hash,
            .amz_date = amz_date,
            .region = self.config.region,
            .service = "s3",
            .access_key_id = self.config.access_key_id,
            .secret_access_key = self.config.secret_access_key,
        });
        errdefer allocator.free(authorization);

        const scheme: []const u8 = if (self.config.use_ssl) "https" else "http";
        const url = if (canonical_query.len > 0)
            try std.fmt.allocPrint(allocator, "{s}://{s}{s}?{s}", .{ scheme, host, canonical_uri, canonical_query })
        else
            try std.fmt.allocPrint(allocator, "{s}://{s}{s}", .{ scheme, host, canonical_uri });

        return .{
            .url = url,
            .host = host,
            .amz_date = amz_date,
            .payload_hash = payload_hash,
            .authorization = authorization,
        };
    }

    // ------------------------------------------------------------------
    // S3 API operations
    // ------------------------------------------------------------------

    fn initiateMultipartUpload(self: *Self, s3_key: []const u8) ![]const u8 {
        const params = [_]sigv4.QueryParam{.{ .name = "uploads", .value = "" }};
        const sr = try self.signRequest("POST", s3_key, &params, "");
        defer sr.deinit(self.allocator);
        const extra = sr.extraHeaders();

        var response = try self.http_client.doRequest(.POST, sr.url, sr.authorization, &extra, null, null);
        defer response.deinit(self.allocator);

        // Parse XML response to extract UploadId
        return try self.parseUploadId(response.body);
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
        var part_buf: [10]u8 = undefined;
        // error-policy: D — a u32 prints at most 10 decimal digits; part_buf is [10]u8.
        const part_str = std.fmt.bufPrint(&part_buf, "{d}", .{part_number}) catch unreachable;
        const params = [_]sigv4.QueryParam{
            .{ .name = "partNumber", .value = part_str },
            .{ .name = "uploadId", .value = upload_id },
        };
        const sr = try self.signRequest("PUT", s3_key, &params, data);
        defer sr.deinit(self.allocator);
        const extra = sr.extraHeaders();

        var response = try self.http_client.doRequest(.PUT, sr.url, sr.authorization, &extra, "application/octet-stream", data);
        defer response.deinit(self.allocator);

        // The part ETag from the response header is required to complete the
        // multipart upload.
        const etag = response.etag orelse return error.MissingPartETag;
        return try self.allocator.dupe(u8, etag);
    }

    fn completeMultipartUpload(self: *Self, upload_id: []const u8, s3_key: []const u8, parts: []const PartInfo, expected_checksum: u64) !void {
        _ = expected_checksum;

        // Build XML payload for completion
        var xml_payload: std.ArrayList(u8) = .empty;
        defer xml_payload.deinit(self.allocator);

        try xml_payload.appendSlice(self.allocator, "<CompleteMultipartUpload>");
        for (parts) |part| {
            const part_xml = try std.fmt.allocPrint(
                self.allocator,
                "<Part><PartNumber>{d}</PartNumber><ETag>{s}</ETag></Part>",
                .{ part.part_number, part.etag },
            );
            defer self.allocator.free(part_xml);
            try xml_payload.appendSlice(self.allocator, part_xml);
        }
        try xml_payload.appendSlice(self.allocator, "</CompleteMultipartUpload>");

        const params = [_]sigv4.QueryParam{.{ .name = "uploadId", .value = upload_id }};
        const sr = try self.signRequest("POST", s3_key, &params, xml_payload.items);
        defer sr.deinit(self.allocator);
        const extra = sr.extraHeaders();

        var response = try self.http_client.doRequest(.POST, sr.url, sr.authorization, &extra, "application/xml", xml_payload.items);
        defer response.deinit(self.allocator);
    }

    fn putObject(self: *Self, s3_key: []const u8, data: []const u8, checksum: u64) !void {
        _ = checksum;

        const sr = try self.signRequest("PUT", s3_key, &.{}, data);
        defer sr.deinit(self.allocator);
        const extra = sr.extraHeaders();

        var response = try self.http_client.doRequest(.PUT, sr.url, sr.authorization, &extra, "application/octet-stream", data);
        defer response.deinit(self.allocator);
    }

    fn getObject(self: *Self, s3_key: []const u8) ![]const u8 {
        const sr = try self.signRequest("GET", s3_key, &.{}, "");
        defer sr.deinit(self.allocator);
        const extra = sr.extraHeaders();

        const response = try self.http_client.doRequest(.GET, sr.url, sr.authorization, &extra, null, null);
        if (response.etag) |etag| self.allocator.free(etag);
        return response.body;
    }

    fn downloadFile(self: *Self, s3_key: []const u8, local_path: []const u8) !void {
        const data = try self.getObject(s3_key);
        defer self.allocator.free(data);

        const io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(io, local_path, .{});
        defer file.close(io);

        try file.writePositionalAll(io, data, 0);
    }
};

const PartInfo = struct {
    part_number: u32,
    etag: []const u8,
};

/// Response from one S3 HTTP exchange. Body and ETag are caller-owned.
const HttpResponse = struct {
    status: std.http.Status,
    body: []u8,
    etag: ?[]u8,

    fn deinit(self: *HttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        if (self.etag) |etag| allocator.free(etag);
        self.* = undefined;
    }
};

/// Minimal HTTP client for the S3 API (Zig 0.16 std.http.Client).
const HttpClient = struct {
    allocator: std.mem.Allocator,

    /// Perform one signed S3 request. Non-2xx statuses surface as
    /// error.S3RequestFailed so the caller's retry loop can re-attempt.
    fn doRequest(
        self: *HttpClient,
        method: std.http.Method,
        url: []const u8,
        authorization: []const u8,
        extra_headers: []const std.http.Header,
        content_type: ?[]const u8,
        payload: ?[]const u8,
    ) !HttpResponse {
        const uri = try std.Uri.parse(url);

        const io = std.Io.Threaded.global_single_threaded.io();
        var client = std.http.Client{ .allocator = self.allocator, .io = io };
        defer client.deinit();

        var req = try client.request(method, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .authorization = .{ .override = authorization },
                .content_type = if (content_type) |ct| .{ .override = ct } else .default,
            },
            .extra_headers = extra_headers,
            .keep_alive = false,
        });
        defer req.deinit();

        if (payload) |p| {
            req.transfer_encoding = .{ .content_length = p.len };
            var body = try req.sendBodyUnflushed(&.{});
            try body.writer.writeAll(p);
            try body.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }

        var response = try req.receiveHead(&.{});

        // Capture the ETag before the body stream invalidates head pointers.
        var etag: ?[]u8 = null;
        errdefer if (etag) |e| self.allocator.free(e);
        var header_it = response.head.iterateHeaders();
        while (header_it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "etag")) {
                etag = try self.allocator.dupe(u8, header.value);
                break;
            }
        }
        const status = response.head.status;

        var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_writer.deinit();
        var transfer_buffer: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        _ = reader.streamRemaining(&body_writer.writer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };

        const code = @intFromEnum(status);
        if (code < 200 or code >= 300) {
            return error.S3RequestFailed;
        }

        return .{
            .status = status,
            .body = try body_writer.toOwnedSlice(),
            .etag = etag,
        };
    }
};

/// S3 backup metrics
const S3Metrics = struct {
    full_backups: u64,
    total_bytes_uploaded: u64,
    total_bytes_downloaded: u64,
    upload_errors: u64,
    download_errors: u64,

    fn init() S3Metrics {
        return .{
            .full_backups = 0,
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
        }
        self.total_bytes_uploaded += size_bytes;
    }

    fn recordRestore(self: *S3Metrics, num_backups: usize, duration_ms: u64) void {
        _ = self;
        _ = num_backups;
        _ = duration_ms;
    }
};
