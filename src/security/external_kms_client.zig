const std = @import("std");
const cb = @import("crypto_backend");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

const builtin = @import("builtin");
const logging = @import("logging");
const log = logging.scoped("security");
const Attr = logging.Attr;

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-005; FEATURE="External Library Migration"; ASPECT=ExternalKMS; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-24
// External JSON library for RFC 8259 compliant encoding in KMS API requests
const json_lib = @import("json");
// SONNY-6465: AWS KMS requests are SigV4-signed with the same core the S3
// client uses (checked against the published AWS vectors in test-s3-sigv4).
const sigv4 = @import("s3_sigv4");

/// JSON structure for Vault Transit decrypt request
const VaultDecryptRequest = struct {
    ciphertext: []const u8,
};

/// JSON structure for AWS KMS Encrypt request
const AwsKmsEncryptRequest = struct {
    KeyId: []const u8,
    Plaintext: []const u8,
};

/// JSON structure for AWS KMS Decrypt request (KeyId pins the key)
const AwsKmsDecryptWithKeyRequest = struct {
    CiphertextBlob: []const u8,
    KeyId: []const u8,
};

/// JSON structure for AWS KMS GenerateDataKey request
const AwsKmsGenerateDataKeyRequest = struct {
    KeyId: []const u8,
    KeySpec: []const u8 = "AES_256",
};

// external_kms_client.zig
// External KMS client providing abstraction over multiple KMS backends:
// - LocalSimulated: AES-256-GCM wrapping for development/testing
// - VaultTransit: HashiCorp Vault Transit backend (enterprise)
// - AwsKms: AWS Key Management Service (enterprise)
//
// GAP-0086: External KMS Integration Implementation
// CANARY: REQ=REQ-GQL-TDE-EXT-KMS-001; FEATURE="ExternalKMSIntegration"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_EXT_KMS_001; OWNER=security; UPDATED=2026-01-15

/// KMS Backend Type
pub const KmsBackend = enum {
    LocalSimulated, // Development/testing only - NOT FOR PRODUCTION
    VaultTransit, // HashiCorp Vault Transit
    AwsKms, // AWS Key Management Service
    AzureKeyVault, // Azure Key Vault (future)
    GcpKms, // Google Cloud KMS (future)

    /// Check if this backend is safe for production use
    /// CANARY: REQ=REQ-GQL-KMS-BACKEND-001; FEATURE="KMS Backend Safety Check"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_sonny6386_key_rotation_truth.zig; OWNER=security; UPDATED=2026-11-12
    pub fn isProductionSafe(self: KmsBackend) bool {
        return switch (self) {
            .LocalSimulated => false, // Never safe for production
            .VaultTransit => true, // Enterprise-grade
            .AwsKms => true, // Enterprise-grade
            .AzureKeyVault => true, // Enterprise-grade
            .GcpKms => true, // Enterprise-grade
        };
    }
};

/// Detect production builds at compile time
pub const is_production_build = @import("builtin").mode == .ReleaseFast or
    @import("builtin").mode == .ReleaseSafe;

/// KMS Configuration for enterprise backends
/// CANARY: REQ=REQ-GQL-KMS-CONFIG-001; FEATURE="KMS Configuration"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_sonny6386_key_rotation_truth.zig; OWNER=security; UPDATED=2026-11-12
pub const KmsConfig = struct {
    backend: KmsBackend = .VaultTransit, // Default to Vault (requires configuration)
    // Vault Transit configuration
    vault_addr: ?[]const u8 = null, // e.g., "http://127.0.0.1:8200"
    vault_token: ?[]const u8 = null, // Vault authentication token
    vault_key_name: ?[]const u8 = null, // Transit key name
    vault_namespace: ?[]const u8 = null, // Vault enterprise namespace
    // AWS KMS configuration
    aws_region: ?[]const u8 = null, // e.g., "us-east-1"
    aws_key_id: ?[]const u8 = null, // KMS Key ID or ARN
    aws_access_key: ?[]const u8 = null, // Optional: use IAM role if null
    aws_secret_key: ?[]const u8 = null, // Optional: use IAM role if null
    aws_endpoint: ?[]const u8 = null, // Optional: custom endpoint for local testing
    // TLS configuration
    tls_ca_cert: ?[]const u8 = null, // CA certificate for TLS verification
    tls_skip_verify: bool = false, // Skip TLS verification (insecure, testing only)

    // GAP-0135: Production safety check for TLS configuration
    // CANARY: REQ=REQ-KMS-TLS-SAFETY-001; FEATURE="KMS TLS Production Guard"; ASPECT=Security; STATUS=TESTED; TEST=tests/test_sonny6386_key_rotation_truth.zig; OWNER=security; UPDATED=2026-11-12
    /// Check if this configuration is safe for production use
    pub fn isSecureForProduction(self: KmsConfig) bool {
        // tls_skip_verify should never be true in production
        if (self.tls_skip_verify) {
            return false;
        }
        // LocalSimulated backend is never production-safe
        if (self.backend == .LocalSimulated) {
            return false;
        }
        return true;
    }

    /// Validate configuration for production use - fails in release builds if insecure
    pub fn validateForProduction(self: KmsConfig) !void {
        if (self.tls_skip_verify) {
            // In release/production builds, block insecure TLS configuration
            if (builtin.mode == .ReleaseSafe or builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall) {
                log.err("tls_skip_verify=true is not allowed in production builds", &.{});
                return error.InsecureTlsConfigurationBlocked;
            } else {
                // In debug builds, emit a warning
                log.warn("tls_skip_verify=true is enabled - TLS MITM attacks are possible", &.{});
            }
        }

        if (self.backend == .LocalSimulated) {
            if (builtin.mode == .ReleaseSafe or builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall) {
                log.err("LocalSimulated KMS backend is not allowed in production builds", &.{});
                return error.InsecureKmsBackendBlocked;
            }
        }
    }
};

/// KMS Provider interface for pluggable backends
pub const KmsProvider = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        wrap: *const fn (ctx: *anyopaque, plaintext: [32]u8) anyerror!Envelope,
        unwrap: *const fn (ctx: *anyopaque, envelope: Envelope) anyerror![32]u8,
        generateKey: *const fn (ctx: *anyopaque) anyerror![32]u8,
        rotateKey: *const fn (ctx: *anyopaque) anyerror!void,
        getKeyVersion: *const fn (ctx: *anyopaque) anyerror!u32,
        /// SONNY-6465: frees what `createKmsProvider` allocated (it used to
        /// leak: nothing could free the client behind a provider).
        destroy: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
    };

    /// Free a provider made by `createKmsProvider` (with the same allocator).
    pub fn deinit(self: KmsProvider, allocator: std.mem.Allocator) void {
        self.vtable.destroy(self.ctx, allocator);
    }

    pub fn wrap(self: KmsProvider, plaintext: [32]u8) !Envelope {
        return self.vtable.wrap(self.ctx, plaintext);
    }
    pub fn unwrap(self: KmsProvider, envelope: Envelope) ![32]u8 {
        return self.vtable.unwrap(self.ctx, envelope);
    }
    pub fn generateKey(self: KmsProvider) ![32]u8 {
        return self.vtable.generateKey(self.ctx);
    }
    pub fn rotateKey(self: KmsProvider) !void {
        return self.vtable.rotateKey(self.ctx);
    }
    pub fn getKeyVersion(self: KmsProvider) !u32 {
        return self.vtable.getKeyVersion(self.ctx);
    }
};

/// Vault Transit client with actual HTTP implementation
/// GAP-0086: HashiCorp Vault Transit backend implementation
/// CANARY: REQ=REQ-GQL-TDE-VAULT-001; FEATURE="VaultTransitKMS"; ASPECT=SECURITY; STATUS=IMPL; OWNER=security; UPDATED=2026-11-12
pub const VaultTransitClient = struct {
    allocator: std.mem.Allocator,
    config: KmsConfig,
    /// The Transit key version of the most recent wrap (from Vault's
    /// "vault:v<N>:" ciphertext prefix); 1 before any wrap.
    key_version: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, config: KmsConfig) VaultTransitClient {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *VaultTransitClient) void {
        _ = self;
    }

    /// Wrap key using Vault Transit encrypt endpoint
    /// POST /v1/transit/encrypt/:key_name
    /// SONNY-6465: the envelope carries Vault's ciphertext
    /// (`kms_ciphertext`, owned by the caller: `Envelope.deinitKmsCiphertext`),
    /// so any client can unwrap it later, after a restart too.
    pub fn wrap(self: *VaultTransitClient, plaintext: [32]u8) !Envelope {
        if (self.config.vault_addr == null or self.config.vault_token == null or self.config.vault_key_name == null) {
            return error.InvalidConfiguration;
        }

        var body_buf: [128]u8 = undefined;
        const body = try vaultEncryptRequestBody(&body_buf, plaintext);
        defer std.crypto.secureZero(u8, &body_buf);

        var url_buf: [512]u8 = undefined;
        const url = try vaultTransitUrl(&url_buf, self.config.vault_addr.?, "encrypt", self.config.vault_key_name.?);

        const response = try self.httpPost(url, body);
        defer self.allocator.free(response);

        // Response: {"data": {"ciphertext": "vault:v1:...", "key_version": N}, ...}
        const ciphertext = try jsonStringField(self.allocator, response, "data", "ciphertext");
        defer self.allocator.free(ciphertext);

        const env = try vaultEnvelope(self.allocator, self.config.vault_key_name.?, ciphertext);
        self.key_version = env.version;
        return env;
    }

    /// Unwrap key using Vault Transit decrypt endpoint
    /// POST /v1/transit/decrypt/:key_name
    pub fn unwrap(self: *VaultTransitClient, env: Envelope) ![32]u8 {
        if (self.config.vault_addr == null or self.config.vault_token == null or self.config.vault_key_name == null) {
            return error.InvalidConfiguration;
        }

        // SONNY-6465: decrypt the ciphertext the envelope carries (it used to
        // be the last wrap's, held in memory), after checking it is the one
        // the envelope was made with.
        try verifyKmsCiphertext(env, "VAULT-TRANSIT");
        const body = try vaultDecryptRequestBody(self.allocator, env);
        defer self.allocator.free(body);

        var url_buf: [512]u8 = undefined;
        const url = try vaultTransitUrl(&url_buf, self.config.vault_addr.?, "decrypt", self.config.vault_key_name.?);

        const response = try self.httpPost(url, body);
        defer {
            std.crypto.secureZero(u8, response);
            self.allocator.free(response);
        }

        // Response: {"data": {"plaintext": "<base64>"}, ...}
        const b64_plaintext = try jsonStringField(self.allocator, response, "data", "plaintext");
        defer {
            std.crypto.secureZero(u8, b64_plaintext);
            self.allocator.free(b64_plaintext);
        }

        // Base64 decode (exactly one 32-byte data key)
        var out: [32]u8 = undefined;
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(b64_plaintext) catch return error.InvalidBase64;
        if (decoded_len != out.len) return error.InvalidBase64;
        _ = std.base64.standard.Decoder.decode(&out, b64_plaintext) catch |e| {
            log.err("Vault Transit base64 decode failed", &.{
                Attr.string("error", @errorName(e)),
            });
            return error.InvalidBase64;
        };

        return out;
    }

    pub fn generateKey(self: *VaultTransitClient) ![32]u8 {
        // Vault Transit generates keys internally; we generate locally and wrap
        var key: [32]u8 = undefined;
        try cb.Csprng.bytes(&key);
        _ = self;
        return key;
    }

    pub fn rotateKey(self: *VaultTransitClient) !void {
        if (self.config.vault_addr == null or self.config.vault_token == null or self.config.vault_key_name == null) {
            return error.InvalidConfiguration;
        }

        // POST /v1/transit/keys/:key_name/rotate
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/v1/transit/keys/{s}/rotate", .{
            self.config.vault_addr.?,
            self.config.vault_key_name.?,
        }) catch return error.BufferOverflow;

        const response = try self.httpPost(url, "{}");
        defer self.allocator.free(response);
        // SONNY-6465: no local counter is bumped. The new version shows in
        // the next wrap's "vault:v<N>:" ciphertext (`getKeyVersion`).
    }

    /// The Transit key version of the most recent wrap.
    pub fn getKeyVersion(self: *VaultTransitClient) !u32 {
        return self.key_version;
    }

    /// POST to Vault with X-Vault-Token (and X-Vault-Namespace when set) as
    /// privileged headers: they are dropped if a redirect leaves the host.
    fn httpPost(self: *VaultTransitClient, url: []const u8, body: []const u8) ![]u8 {
        var headers_buf: [2]std.http.Header = undefined;
        const headers = vaultHeaders(&headers_buf, self.config);
        return httpPostJson(self.allocator, self.config, url, "application/json", body, &.{}, headers, "Vault");
    }

    pub fn toProvider(self: *VaultTransitClient) KmsProvider {
        return .{
            .ctx = self,
            .vtable = &.{
                .wrap = vaultWrap,
                .unwrap = vaultUnwrap,
                .generateKey = vaultGenKey,
                .rotateKey = vaultRotate,
                .getKeyVersion = vaultGetVersion,
                .destroy = vaultDestroy,
            },
        };
    }

    fn vaultWrap(ctx: *anyopaque, plaintext: [32]u8) anyerror!Envelope {
        const self: *VaultTransitClient = @ptrCast(@alignCast(ctx));
        return self.wrap(plaintext);
    }

    fn vaultUnwrap(ctx: *anyopaque, envelope: Envelope) anyerror![32]u8 {
        const self: *VaultTransitClient = @ptrCast(@alignCast(ctx));
        return self.unwrap(envelope);
    }

    fn vaultGenKey(ctx: *anyopaque) anyerror![32]u8 {
        const self: *VaultTransitClient = @ptrCast(@alignCast(ctx));
        return self.generateKey();
    }

    fn vaultRotate(ctx: *anyopaque) anyerror!void {
        const self: *VaultTransitClient = @ptrCast(@alignCast(ctx));
        return self.rotateKey();
    }

    fn vaultGetVersion(ctx: *anyopaque) anyerror!u32 {
        const self: *VaultTransitClient = @ptrCast(@alignCast(ctx));
        return self.getKeyVersion();
    }

    fn vaultDestroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *VaultTransitClient = @ptrCast(@alignCast(ctx));
        self.deinit();
        allocator.destroy(self);
    }
};

/// AWS KMS client with actual HTTP implementation
/// GAP-0086: AWS Key Management Service backend implementation
/// CANARY: REQ=REQ-GQL-TDE-AWS-001; FEATURE="AwsKmsIntegration"; ASPECT=SECURITY; STATUS=IMPL; OWNER=security; UPDATED=2026-11-12
pub const AwsKmsClient = struct {
    allocator: std.mem.Allocator,
    config: KmsConfig,
    /// AWS KMS keeps key versions to itself (rotation is AWS-managed); this
    /// stays 1.
    key_version: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, config: KmsConfig) AwsKmsClient {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *AwsKmsClient) void {
        _ = self;
    }

    /// Wrap key using AWS KMS Encrypt API
    pub fn wrap(self: *AwsKmsClient, plaintext: [32]u8) !Envelope {
        if (self.config.aws_key_id == null) {
            return error.InvalidConfiguration;
        }
        if (self.config.aws_access_key == null or self.config.aws_secret_key == null) return error.AwsCredentialsRequired;

        // Base64 encode the plaintext
        var b64_buf: [64]u8 = undefined;
        const b64_plaintext = std.base64.standard.Encoder.encode(&b64_buf, &plaintext);

        // Build request body for Encrypt using type-safe JSON encoding
        const request = AwsKmsEncryptRequest{
            .KeyId = self.config.aws_key_id.?,
            .Plaintext = b64_plaintext,
        };
        const body = try json_lib.encode(self.allocator, request, .{});
        defer self.allocator.free(body);

        // Make HTTP request
        const response = try self.httpPost("TrentService.Encrypt", body);
        defer self.allocator.free(response);

        // Parse response: {"CiphertextBlob": "base64..."}. SONNY-6465: the
        // envelope carries it (base64, as Decrypt takes it), so any client can
        // unwrap it later; the caller owns it (`Envelope.deinitKmsCiphertext`).
        const ciphertext_blob = try jsonStringField(self.allocator, response, null, "CiphertextBlob");
        defer self.allocator.free(ciphertext_blob);
        return awsEnvelope(self.allocator, self.config.aws_key_id.?, ciphertext_blob);
    }

    /// Unwrap key using AWS KMS Decrypt API
    pub fn unwrap(self: *AwsKmsClient, env: Envelope) ![32]u8 {
        if (self.config.aws_key_id == null) {
            return error.InvalidConfiguration;
        }

        // SONNY-6465: decrypt the CiphertextBlob the envelope carries (it
        // used to be the last wrap's, held in memory).
        try verifyKmsCiphertext(env, "AWS-KMS");
        const body = try awsDecryptRequestBody(self.allocator, self.config.aws_key_id.?, env);
        defer self.allocator.free(body);

        // Make HTTP request
        const response = try self.httpPost("TrentService.Decrypt", body);
        defer self.allocator.free(response);

        // Parse response: {"Plaintext": "base64..."}
        const b64_plaintext = try jsonStringField(self.allocator, response, null, "Plaintext");
        defer self.allocator.free(b64_plaintext);

        // Base64 decode (exactly one 32-byte data key)
        var out: [32]u8 = undefined;
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(b64_plaintext) catch return error.InvalidBase64;
        if (decoded_len != out.len) return error.InvalidBase64;
        _ = std.base64.standard.Decoder.decode(&out, b64_plaintext) catch |e| {
            log.err("AWS KMS base64 decode failed", &.{
                Attr.string("error", @errorName(e)),
            });
            return error.InvalidBase64;
        };
        return out;
    }

    /// Generate a data key using AWS KMS GenerateDataKey API
    pub fn generateKey(self: *AwsKmsClient) ![32]u8 {
        if (self.config.aws_key_id == null) {
            return error.InvalidConfiguration;
        }
        if (self.config.aws_access_key == null or self.config.aws_secret_key == null) return error.AwsCredentialsRequired;

        // Build request body for GenerateDataKey using type-safe JSON encoding
        const request = AwsKmsGenerateDataKeyRequest{ .KeyId = self.config.aws_key_id.? };
        const body = try json_lib.encode(self.allocator, request, .{});
        defer self.allocator.free(body);

        // Make HTTP request
        const response = try self.httpPost("TrentService.GenerateDataKey", body);
        defer self.allocator.free(response);

        // Parse response: {"Plaintext": "base64...", "CiphertextBlob": "base64..."}
        const b64_plaintext = try jsonStringField(self.allocator, response, null, "Plaintext");
        defer self.allocator.free(b64_plaintext);

        // The response's CiphertextBlob is not kept: this returns the key
        // only (the vtable has no place for it); the caller wraps the key.

        // Base64 decode the plaintext (exactly one 32-byte data key)
        var out: [32]u8 = undefined;
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(b64_plaintext) catch return error.InvalidBase64;
        if (decoded_len != out.len) return error.InvalidBase64;
        _ = std.base64.standard.Decoder.decode(&out, b64_plaintext) catch |e| {
            log.err("AWS KMS GenerateDataKey base64 decode failed", &.{
                Attr.string("error", @errorName(e)),
            });
            return error.InvalidBase64;
        };

        return out;
    }

    /// SONNY-6465: refused. AWS KMS rotates a key's material itself (enable
    /// automatic rotation on the key, or RotateKeyOnDemand); envelopes keep
    /// decrypting across rotations. This used to bump a local counter and
    /// report success.
    pub fn rotateKey(self: *AwsKmsClient) !void {
        _ = self;
        return error.AwsKmsRotationIsManagedByAws;
    }

    pub fn getKeyVersion(self: *AwsKmsClient) !u32 {
        return self.key_version;
    }

    /// POST an AWS KMS JSON 1.1 request, SigV4-signed (SONNY-6465; it was
    /// unsigned, so real AWS KMS refused it). Static credentials
    /// (aws_access_key / aws_secret_key) are required: fetching instance-role
    /// or SSO credentials is not implemented, and is refused clearly.
    fn httpPost(self: *AwsKmsClient, target: []const u8, body: []const u8) ![]u8 {
        if (self.config.aws_access_key == null or self.config.aws_secret_key == null) return error.AwsCredentialsRequired;
        // Use custom endpoint or default AWS endpoint
        const endpoint = self.config.aws_endpoint orelse blk: {
            const region = self.config.aws_region orelse "us-east-1";
            break :blk std.fmt.allocPrint(self.allocator, "https://kms.{s}.amazonaws.com", .{region}) catch return error.OutOfMemory;
        };
        const endpoint_owned = self.config.aws_endpoint == null;
        defer if (endpoint_owned) self.allocator.free(endpoint);

        const uri = std.Uri.parse(endpoint) catch return error.InvalidUrl;
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host_name = uri.getHost(&host_buf) catch return error.InvalidUrl;
        const host = if (uri.port) |port|
            try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ host_name.bytes, port })
        else
            try self.allocator.dupe(u8, host_name.bytes);
        defer self.allocator.free(host);

        const now_s: u64 = @intCast(@max(0, std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).toSeconds()));
        const amz_date = sigv4.formatAmzDate(now_s);
        const authorization = try awsKmsAuthorization(self.allocator, self.config, host, target, body, &amz_date);
        defer self.allocator.free(authorization);

        const extra = [_]std.http.Header{
            .{ .name = "X-Amz-Target", .value = target },
            .{ .name = "X-Amz-Date", .value = &amz_date },
        };
        const privileged = [_]std.http.Header{.{ .name = "Authorization", .value = authorization }};
        return httpPostJson(self.allocator, self.config, endpoint, aws_json_content_type, body, &extra, &privileged, "AWS KMS");
    }

    pub fn toProvider(self: *AwsKmsClient) KmsProvider {
        return .{
            .ctx = self,
            .vtable = &.{
                .wrap = awsWrap,
                .unwrap = awsUnwrap,
                .generateKey = awsGenKey,
                .rotateKey = awsRotate,
                .getKeyVersion = awsGetVersion,
                .destroy = awsDestroy,
            },
        };
    }

    fn awsWrap(ctx: *anyopaque, plaintext: [32]u8) anyerror!Envelope {
        const self: *AwsKmsClient = @ptrCast(@alignCast(ctx));
        return self.wrap(plaintext);
    }

    fn awsUnwrap(ctx: *anyopaque, envelope: Envelope) anyerror![32]u8 {
        const self: *AwsKmsClient = @ptrCast(@alignCast(ctx));
        return self.unwrap(envelope);
    }

    fn awsGenKey(ctx: *anyopaque) anyerror![32]u8 {
        const self: *AwsKmsClient = @ptrCast(@alignCast(ctx));
        return self.generateKey();
    }

    fn awsRotate(ctx: *anyopaque) anyerror!void {
        const self: *AwsKmsClient = @ptrCast(@alignCast(ctx));
        return self.rotateKey();
    }

    fn awsGetVersion(ctx: *anyopaque) anyerror!u32 {
        const self: *AwsKmsClient = @ptrCast(@alignCast(ctx));
        return self.getKeyVersion();
    }

    fn awsDestroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *AwsKmsClient = @ptrCast(@alignCast(ctx));
        self.deinit();
        allocator.destroy(self);
    }
};

// CANARY: REQ=REQ-SONNY-6465-KMS-TLS; FEATURE="ExternalKmsClients"; ASPECT=TlsOptionsHonoured; STATUS=TESTED; TEST=tests/test_sonny6465_external_kms.zig; OWNER=security; UPDATED=2026-11-13
/// SONNY-6465: the HTTP client a KMS request uses. `tls_ca_cert` is the only
/// trust anchor when set (the system store is not scanned);
/// `tls_skip_verify` is refused (std.http.Client cannot skip verification,
/// and both options used to be ignored silently).
pub fn kmsHttpClient(allocator: std.mem.Allocator, config: KmsConfig) !std.http.Client {
    if (config.tls_skip_verify) {
        log.err("KMS tls_skip_verify is not supported; configure tls_ca_cert instead", &.{});
        return error.TlsSkipVerifyUnsupported;
    }
    const io = std.Io.Threaded.global_single_threaded.io();
    var client = std.http.Client{ .allocator = allocator, .io = io };
    errdefer client.deinit();
    if (config.tls_ca_cert) |ca_path| {
        const now = std.Io.Clock.real.now(io);
        client.ca_bundle.addCertsFromFilePath(allocator, io, now, std.Io.Dir.cwd(), ca_path) catch |err| {
            log.err("KMS tls_ca_cert cannot be read", &.{ Attr.string("path", ca_path), Attr.string("error", @errorName(err)) });
            return error.KmsCaCertUnreadable;
        };
        if (client.ca_bundle.map.count() == 0) return error.KmsCaCertUnreadable;
        // A set `now` stops the client rescanning the system CA store.
        client.now = now;
    }
    return client;
}

/// One POST over std.http.Client (Zig 0.16). Returns the response body
/// (caller owns) on 200 OK; any other status or a transport failure is an
/// error.
fn httpPostJson(
    allocator: std.mem.Allocator,
    config: KmsConfig,
    url: []const u8,
    content_type: []const u8,
    body: []const u8,
    extra_headers: []const std.http.Header,
    privileged_headers: []const std.http.Header,
    what: []const u8,
) ![]u8 {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var client = try kmsHttpClient(allocator, config);
    defer client.deinit();

    var response: std.Io.Writer.Allocating = .init(allocator);
    defer response.deinit();
    const result = client.fetch(.{
        .location = .{ .uri = uri },
        .method = .POST,
        .payload = body,
        .headers = .{ .content_type = .{ .override = content_type } },
        .extra_headers = extra_headers,
        .privileged_headers = privileged_headers,
        .response_writer = &response.writer,
        .keep_alive = false,
    }) catch |err| {
        log.err("KMS HTTP request failed", &.{
            Attr.string("service", what),
            Attr.string("error", @errorName(err)),
        });
        return error.ConnectionFailed;
    };
    if (result.status != .ok) {
        log.err("KMS HTTP status error", &.{
            Attr.string("service", what),
            Attr.int("status_code", @intCast(@intFromEnum(result.status))),
        });
        return error.HttpError;
    }
    return response.toOwnedSlice();
}

const aws_json_content_type = "application/x-amz-json-1.1";

// CANARY: REQ=REQ-SONNY-6465-AWS-SIGV4; FEATURE="ExternalKmsClients"; ASPECT=AwsKmsSigV4; STATUS=TESTED; TEST=tests/test_sonny6465_external_kms.zig; OWNER=security; UPDATED=2026-11-13
/// The SigV4 signing key (kSecret -> kDate -> kRegion -> kService ->
/// kSigning).
pub fn awsSigningKey(secret: []const u8, date: []const u8, region: []const u8, service: []const u8) ![32]u8 {
    return sigv4.signingKey(secret, date, region, service);
}

/// SONNY-6465: the `Authorization` header of an AWS KMS JSON 1.1 request
/// (POST / with Content-Type application/x-amz-json-1.1 and X-Amz-Target),
/// SigV4-signed for service "kms" over content-type, host, x-amz-date and
/// x-amz-target and the body. `amz_date` is "YYYYMMDDTHHMMSSZ"; `host` is
/// the Host header (with ":port" when the endpoint names one).
pub fn awsKmsAuthorization(
    allocator: std.mem.Allocator,
    config: KmsConfig,
    host: []const u8,
    target: []const u8,
    body: []const u8,
    amz_date: []const u8,
) ![]u8 {
    const access_key = config.aws_access_key orelse return error.AwsCredentialsRequired;
    const secret_key = config.aws_secret_key orelse return error.AwsCredentialsRequired;
    const payload_hash = try sigv4.hashPayloadHex(body);
    const headers = [_]sigv4.Header{
        .{ .name = "Content-Type", .value = aws_json_content_type },
        .{ .name = "Host", .value = host },
        .{ .name = "X-Amz-Date", .value = amz_date },
        .{ .name = "X-Amz-Target", .value = target },
    };
    return sigv4.authorizationHeader(allocator, .{
        .method = "POST",
        .canonical_uri = "/",
        .canonical_query = "",
        .headers = &headers,
        .payload_hash_hex = &payload_hash,
        .amz_date = amz_date,
        .region = config.aws_region orelse "us-east-1",
        .service = "kms",
        .access_key_id = access_key,
        .secret_access_key = secret_key,
    });
}

// CANARY: REQ=REQ-SONNY-6465-ENVELOPE-CIPHERTEXT; FEATURE="ExternalKmsClients"; ASPECT=UnwrapFromEnvelope; STATUS=TESTED; TEST=tests/test_sonny6465_external_kms.zig; OWNER=security; UPDATED=2026-11-13
/// True when `text` is safe to carry verbatim in the envelope's JSON (and in
/// a request body): base64 / Vault ciphertext characters only.
fn isPlainKmsCiphertext(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=' or c == ':' or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

/// An external-KMS envelope for `kms_ciphertext` (duplicated; the caller
/// frees it with `Envelope.deinitKmsCiphertext`). `ct` is its SHA-256 and
/// `tag` the first 16 bytes of it; `nonce` binds the key name.
fn externalEnvelope(allocator: std.mem.Allocator, alg: []const u8, version: u8, key_name: []const u8, kms_ciphertext: []const u8) !Envelope {
    var env = Envelope{ .version = version, .alg = alg, .nonce = undefined, .tag = undefined, .ct = undefined };
    var hash: [32]u8 = undefined;
    _ = try cb.Hash.digest(.sha256, kms_ciphertext, &hash);
    @memcpy(&env.ct, &hash);
    @memcpy(&env.tag, hash[0..16]);
    var key_hash: [32]u8 = undefined;
    _ = try cb.Hash.digest(.sha256, key_name, &key_hash);
    @memcpy(&env.nonce, key_hash[0..12]);
    env.kms_ciphertext = try allocator.dupe(u8, kms_ciphertext);
    return env;
}

/// SONNY-6465: the envelope for a Vault Transit ciphertext
/// ("vault:v<N>:<base64>"); its version is N.
pub fn vaultEnvelope(allocator: std.mem.Allocator, key_name: []const u8, ciphertext: []const u8) !Envelope {
    if (!std.mem.startsWith(u8, ciphertext, "vault:v") or !isPlainKmsCiphertext(ciphertext)) return error.InvalidVaultCiphertext;
    const rest = ciphertext["vault:v".len..];
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return error.InvalidVaultCiphertext;
    const version = std.fmt.parseInt(u8, rest[0..colon], 10) catch return error.InvalidVaultCiphertext;
    if (version == 0 or colon + 1 >= rest.len) return error.InvalidVaultCiphertext;
    return externalEnvelope(allocator, "VAULT-TRANSIT", version, key_name, ciphertext);
}

/// SONNY-6465: the envelope for an AWS KMS CiphertextBlob (base64, as the
/// Encrypt response gives it and Decrypt takes it).
pub fn awsEnvelope(allocator: std.mem.Allocator, key_id: []const u8, ciphertext_blob_b64: []const u8) !Envelope {
    if (!isPlainKmsCiphertext(ciphertext_blob_b64)) return error.InvalidBase64;
    return externalEnvelope(allocator, "AWS-KMS", 1, key_id, ciphertext_blob_b64);
}

/// The envelope must carry the KMS ciphertext it was made with.
fn verifyKmsCiphertext(env: Envelope, alg: []const u8) !void {
    if (!std.mem.eql(u8, env.alg, alg)) return error.UnsupportedAlgorithm;
    if (env.kms_ciphertext.len == 0) return error.MissingKmsCiphertext;
    if (!isPlainKmsCiphertext(env.kms_ciphertext)) return error.EnvelopeCiphertextMismatch;
    var hash: [32]u8 = undefined;
    _ = try cb.Hash.digest(.sha256, env.kms_ciphertext, &hash);
    if (!std.crypto.timing_safe.eql([32]u8, hash, env.ct)) return error.EnvelopeCiphertextMismatch;
}

/// `{"ciphertext":"vault:v<N>:..."}` for the envelope's ciphertext (Vault
/// Transit decrypt). Caller frees.
pub fn vaultDecryptRequestBody(allocator: std.mem.Allocator, env: Envelope) ![]u8 {
    return json_lib.encode(allocator, VaultDecryptRequest{ .ciphertext = env.kms_ciphertext }, .{});
}

/// `{"CiphertextBlob":"<base64>","KeyId":"<key>"}` for the envelope's
/// ciphertext (AWS KMS Decrypt). Caller frees.
pub fn awsDecryptRequestBody(allocator: std.mem.Allocator, key_id: []const u8, env: Envelope) ![]u8 {
    return json_lib.encode(allocator, AwsKmsDecryptWithKeyRequest{ .CiphertextBlob = env.kms_ciphertext, .KeyId = key_id }, .{});
}

/// `{vault_addr}/v1/transit/{op}/{key_name}` (Vault Transit HTTP API).
pub fn vaultTransitUrl(buf: []u8, vault_addr: []const u8, op: []const u8, key_name: []const u8) ![]const u8 {
    const addr = std.mem.trimEnd(u8, vault_addr, "/");
    return std.fmt.bufPrint(buf, "{s}/v1/transit/{s}/{s}", .{ addr, op, key_name }) catch error.BufferOverflow;
}

/// `{"plaintext":"<base64 of the 32-byte data key>"}` (Vault Transit encrypt).
pub fn vaultEncryptRequestBody(buf: []u8, plaintext: [32]u8) ![]const u8 {
    var b64_buf: [std.base64.standard.Encoder.calcSize(32)]u8 = undefined;
    defer std.crypto.secureZero(u8, &b64_buf);
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &plaintext);
    return std.fmt.bufPrint(buf, "{{\"plaintext\":\"{s}\"}}", .{b64}) catch error.BufferOverflow;
}

/// The Vault request headers: X-Vault-Token, plus X-Vault-Namespace when a
/// namespace is configured (Vault Enterprise). Both are privileged.
pub fn vaultHeaders(buf: *[2]std.http.Header, config: KmsConfig) []const std.http.Header {
    buf[0] = .{ .name = "X-Vault-Token", .value = config.vault_token orelse "" };
    if (config.vault_namespace) |ns| {
        buf[1] = .{ .name = "X-Vault-Namespace", .value = ns };
        return buf[0..2];
    }
    return buf[0..1];
}

/// The string at `response[outer][field]` (or `response[field]` when
/// `outer` is null), duplicated. error.InvalidResponse when the body is not
/// a JSON object or the value is missing or not a string.
pub fn jsonStringField(allocator: std.mem.Allocator, response: []const u8, outer: ?[]const u8, field: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return error.InvalidResponse;
    defer parsed.deinit();
    var obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };
    if (outer) |name| {
        obj = switch (obj.get(name) orelse return error.InvalidResponse) {
            .object => |o| o,
            else => return error.InvalidResponse,
        };
    }
    return switch (obj.get(field) orelse return error.InvalidResponse) {
        .string => |v| try allocator.dupe(u8, v),
        else => error.InvalidResponse,
    };
}

/// Factory function to create KMS provider based on configuration
pub fn createKmsProvider(allocator: std.mem.Allocator, config: KmsConfig) !KmsProvider {
    switch (config.backend) {
        .LocalSimulated => {
            // SONNY-6442: a simulated KMS exists in test builds only.
            if (comptime !builtin.is_test) return error.SimulatedKmsUnavailable;
            const seed = blk: {
                // Route through FIPS seam (cb.Hash.Stream) for incremental hash
                var h = try cb.Hash.Stream.init(.sha256);
                defer h.deinit();
                try h.update("local-kms-seed");
                var digest: [32]u8 = undefined;
                _ = try h.final(&digest);
                break :blk std.mem.readInt(u64, digest[0..8], .little);
            };
            const client_ptr = try allocator.create(Client);
            // GAP-0216: Handle potential error from LocalSimulated KMS init
            client_ptr.* = try Client.init(allocator, seed);
            return .{
                .ctx = client_ptr,
                .vtable = &local_vtable,
            };
        },
        .VaultTransit => {
            const vault_ptr = try allocator.create(VaultTransitClient);
            vault_ptr.* = VaultTransitClient.init(allocator, config);
            return vault_ptr.toProvider();
        },
        .AwsKms => {
            const aws_ptr = try allocator.create(AwsKmsClient);
            aws_ptr.* = AwsKmsClient.init(allocator, config);
            return aws_ptr.toProvider();
        },
        .AzureKeyVault, .GcpKms => {
            return error.UnsupportedBackend;
        },
    }
}

const local_vtable = KmsProvider.VTable{
    .wrap = localWrap,
    .unwrap = localUnwrap,
    .generateKey = localGenKey,
    .rotateKey = localRotate,
    .getKeyVersion = localGetVersion,
    .destroy = localDestroy,
};

fn localDestroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const client: *Client = @ptrCast(@alignCast(ctx));
    std.crypto.secureZero(u8, &client.kek);
    allocator.destroy(client);
}

fn localWrap(ctx: *anyopaque, plaintext: [32]u8) anyerror!Envelope {
    const client: *Client = @ptrCast(@alignCast(ctx));
    return client.wrap(plaintext);
}

fn localUnwrap(ctx: *anyopaque, envelope: Envelope) anyerror![32]u8 {
    const client: *Client = @ptrCast(@alignCast(ctx));
    return client.unwrap(envelope);
}

fn localGenKey(_: *anyopaque) anyerror![32]u8 {
    var key: [32]u8 = undefined;
    try cb.Csprng.bytes(&key);
    return key;
}

fn localRotate(_: *anyopaque) anyerror!void {
    // No-op for local simulation
}

fn localGetVersion(_: *anyopaque) anyerror!u32 {
    return 1;
}

pub const Envelope = struct {
    version: u8 = 1,
    alg: []const u8 = "AES-256-GCM",
    nonce: [12]u8,
    tag: [16]u8,
    ct: [32]u8, // wrapped 32-byte data key (or SHA-256 of kms_ciphertext for external KMS)
    /// SONNY-6465: the external KMS ciphertext (Vault "vault:v<N>:...", AWS
    /// base64 CiphertextBlob) unwrap decrypts; empty for the local AEAD
    /// envelope. Owned by whoever made the envelope (`wrap` allocates it with
    /// the client's allocator; free it with `deinitKmsCiphertext`);
    /// `envelopeFromJson` points it into the JSON text.
    kms_ciphertext: []const u8 = "",

    pub fn deinitKmsCiphertext(self: *Envelope, allocator: std.mem.Allocator) void {
        if (self.kms_ciphertext.len > 0) allocator.free(self.kms_ciphertext);
        self.kms_ciphertext = "";
    }
};

const simulated_kms_test_only = "the LocalSimulated KMS client exists in test builds only (SONNY-6442): use VaultTransit or AwsKms";

/// LocalSimulated KMS Client - TEST BUILDS ONLY
/// Uses local AES-256-GCM with deterministic key derived from seed
/// WARNING: This is NOT a real KMS integration. Production must use VaultTransit or AwsKms.
/// CANARY: REQ=REQ-GQL-KMS-LOCALSIM-001; FEATURE="LocalSimulated KMS Client"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_external_kms_provider.zig; OWNER=security; UPDATED=2026-11-12
/// CANARY: REQ=REQ-GQL-KMS-PRODSAFE-001; FEATURE="LocalSimulated KMS Production Block"; ASPECT=SECURITY; STATUS=TESTED; TEST=tests/test_sonny6442_kms_channel.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6442: its constructors do not compile outside a test build, so no
/// product binary -- release or debug -- can construct it. (GAP-0216 refused
/// it in release builds only, behind an environment-variable override.)
pub const Client = struct {
    allocator: std.mem.Allocator,
    kek: [32]u8, // simulated Key Encryption Key (would be remote / HSM-controlled)
    prng: std.Random.DefaultPrng,

    /// Initialize LocalSimulated client (test builds only).
    pub fn init(allocator: std.mem.Allocator, seed: u64) !Client {
        if (comptime !builtin.is_test) @compileError(simulated_kms_test_only);
        var prng = std.Random.DefaultPrng.init(seed);
        var kek: [32]u8 = undefined;
        prng.random().bytes(&kek);
        return .{ .allocator = allocator, .kek = kek, .prng = prng };
    }

    /// Create a client with cryptographically secure key (for testing without deterministic seed)
    /// GAP-0107 SECURITY FIX: Use cryptographic random for all operations
    /// Test builds only (SONNY-6442).
    pub fn initSecure(allocator: std.mem.Allocator) !Client {
        if (comptime !builtin.is_test) @compileError(simulated_kms_test_only);

        var kek: [32]u8 = undefined;
        try cb.Csprng.bytes(&kek);
        // GAP-0107 FIX: PRNG field retained for backward compatibility but NOT used for nonces
        return .{ .allocator = allocator, .kek = kek, .prng = std.Random.DefaultPrng.init(0) };
    }

    pub fn wrap(self: *Client, data_key: [32]u8) !Envelope {
        var nonce: [12]u8 = undefined;
        // GAP-0107 SECURITY FIX: Use cryptographic random for nonces, not deterministic PRNG
        try cb.Csprng.bytes(&nonce);
        var ct: [32]u8 = undefined;
        var tag: [16]u8 = undefined;
        // Route through FIPS seam
        try cb.Aead.seal(.aes_256_gcm, &self.kek, &nonce, &.{}, &data_key, &ct, &tag);
        return .{ .nonce = nonce, .tag = tag, .ct = ct };
    }

    pub fn unwrap(self: *Client, env: Envelope) ![32]u8 {
        if (env.version != 1) return error.UnsupportedEnvelopeVersion;
        if (!std.mem.eql(u8, env.alg, "AES-256-GCM")) return error.UnsupportedAlgorithm;
        var out: [32]u8 = undefined;
        var nonce = env.nonce;
        var tag = env.tag;
        // Route through FIPS seam
        cb.Aead.open(.aes_256_gcm, &self.kek, &nonce, &.{}, &env.ct, &tag, &out) catch |e| return e;
        return out;
    }
};

// Serialization helpers
pub fn envelopeToJson(env: Envelope, allocator: std.mem.Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 256) catch return error.OutOfMemory;
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\"version\":{d},\"alg\":\"{s}\",\"nonce\":\"", .{ env.version, env.alg });
    for (env.nonce) |b| try w.print("{x:0>2}", .{b});
    try w.print("\",\"tag\":\"", .{});
    for (env.tag) |b| try w.print("{x:0>2}", .{b});
    try w.print("\",\"ct\":\"", .{});
    for (env.ct) |b| try w.print("{x:0>2}", .{b});
    if (env.kms_ciphertext.len > 0) {
        if (!isPlainKmsCiphertext(env.kms_ciphertext)) return error.InvalidEnvelope;
        try w.print("\",\"kms_ct\":\"{s}", .{env.kms_ciphertext});
    }
    try w.print("\"}}", .{});
    var buf = aw.toArrayList();
    return try buf.toOwnedSlice(allocator);
}

pub fn envelopeFromJson(json: []const u8) !Envelope {
    var env: Envelope = undefined;
    env.version = 0;
    const nonce_key = std.mem.indexOf(u8, json, "\"nonce\":\"") orelse return error.InvalidEnvelope;
    const tag_key = std.mem.indexOf(u8, json, "\"tag\":\"") orelse return error.InvalidEnvelope;
    const ct_key = std.mem.indexOf(u8, json, "\"ct\":\"") orelse return error.InvalidEnvelope;
    const ver_key = std.mem.indexOf(u8, json, "\"version\":") orelse return error.InvalidEnvelope;
    var i = ver_key + 10;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}
    if (i >= json.len) return error.InvalidEnvelope;
    env.version = std.fmt.parseInt(u8, json[i .. i + 1], 10) catch return error.InvalidEnvelope;
    const alg_key = std.mem.indexOf(u8, json, "\"alg\":\"") orelse return error.InvalidEnvelope;
    const j = alg_key + 7;
    const alg_end = std.mem.indexOfScalarPos(u8, json, j, '"') orelse return error.InvalidEnvelope;
    const alg_slice = json[j..alg_end];
    if (!std.mem.eql(u8, alg_slice, "AES-256-GCM") and !std.mem.eql(u8, alg_slice, "VAULT-TRANSIT") and !std.mem.eql(u8, alg_slice, "AWS-KMS")) {
        return error.UnsupportedAlgorithm;
    }
    // GAP-0141: Safe hex parsing with proper error handling
    // CANARY: REQ=REQ-HEX-PARSE-001; FEATURE="Safe Hex Parsing"; ASPECT=Security; STATUS=TESTED; TEST=tests/test_sonny6386_key_rotation_truth.zig; OWNER=security; UPDATED=2026-11-12
    const nonce_start = nonce_key + 9;
    const nonce_end = nonce_start + 24;
    if (nonce_end > json.len) return error.InvalidEnvelope;
    var k: usize = 0;
    while (k < 12) : (k += 1) env.nonce[k] = std.fmt.parseInt(u8, json[nonce_start + k * 2 .. nonce_start + k * 2 + 2], 16) catch return error.InvalidHexInNonce;
    const tag_start = tag_key + 7;
    const tag_end = tag_start + 32;
    if (tag_end > json.len) return error.InvalidEnvelope;
    k = 0;
    while (k < 16) : (k += 1) env.tag[k] = std.fmt.parseInt(u8, json[tag_start + k * 2 .. tag_start + k * 2 + 2], 16) catch return error.InvalidHexInTag;
    const ct_start = ct_key + 6;
    const ct_end = ct_start + 64;
    if (ct_end > json.len) return error.InvalidEnvelope;
    k = 0;
    while (k < 32) : (k += 1) env.ct[k] = std.fmt.parseInt(u8, json[ct_start + k * 2 .. ct_start + k * 2 + 2], 16) catch return error.InvalidHexInCiphertext;
    env.alg = alg_slice;
    // SONNY-6465: the external KMS ciphertext, when present.
    env.kms_ciphertext = "";
    if (std.mem.indexOf(u8, json, "\"kms_ct\":\"")) |kk| {
        const start = kk + 10;
        const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse return error.InvalidEnvelope;
        if (!isPlainKmsCiphertext(json[start..end])) return error.InvalidEnvelope;
        env.kms_ciphertext = json[start..end];
    }
    return env;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "external kms client wrap/unwrap round trip" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    // GAP-0216: Handle error union from init (succeeds in test mode)
    var client = try Client.init(gpa.allocator(), 0xDEEFA55E);
    var key: [32]u8 = undefined;
    @memset(&key, 0x11);
    const env1 = try client.wrap(key);
    const env2 = try client.wrap(key);
    try std.testing.expect(!std.mem.eql(u8, &env1.nonce, &env2.nonce));
    const k_out = try client.unwrap(env1);
    try std.testing.expect(std.mem.eql(u8, &key, &k_out));
    var tampered = env1;
    tampered.tag[0] ^= 0xFF;
    const res = client.unwrap(tampered);
    // The crypto_backend AEAD reports a failed tag as AuthFailed (as
    // tests/test_external_kms_provider.zig expects; SONNY-6465).
    try std.testing.expectError(error.AuthFailed, res);
}

test "kms provider factory local simulation" {
    const allocator = std.testing.allocator;
    const config = KmsConfig{ .backend = .LocalSimulated };
    const provider = try createKmsProvider(allocator, config);
    defer provider.deinit(allocator);
    const key = try provider.generateKey();
    const env = try provider.wrap(key);
    const recovered = try provider.unwrap(env);
    try std.testing.expect(std.mem.eql(u8, &key, &recovered));
}

test "kms provider unsupported backend returns error" {
    const allocator = std.testing.allocator;
    const config = KmsConfig{ .backend = .AzureKeyVault };
    const result = createKmsProvider(allocator, config);
    try std.testing.expectError(error.UnsupportedBackend, result);
}

test "vault transit client configuration validation" {
    const allocator = std.testing.allocator;
    // Missing required config should fail
    var vault = VaultTransitClient.init(allocator, KmsConfig{ .backend = .VaultTransit });
    var key: [32]u8 = undefined;
    @memset(&key, 0x42);
    const result = vault.wrap(key);
    try std.testing.expectError(error.InvalidConfiguration, result);
}

test "aws kms client configuration validation" {
    const allocator = std.testing.allocator;
    // Missing required config should fail
    var aws = AwsKmsClient.init(allocator, KmsConfig{ .backend = .AwsKms });
    var key: [32]u8 = undefined;
    @memset(&key, 0x55);
    const result = aws.wrap(key);
    try std.testing.expectError(error.InvalidConfiguration, result);
}

// Integration tests against a live service (SONNY-6465: they used to pass
// when the service was missing OR when a call failed). Skipped unless the
// environment names a service; once it does, any failure fails the test.
//   VAULT_ADDR, VAULT_TOKEN (Transit engine with key geode-test-key)
//   AWS_KMS_ENDPOINT, AWS_KMS_KEY_ID (default alias/testing),
//   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION (default us-east-1)
test "vault transit integration test" {
    const a = std.testing.allocator;
    const vault_addr = getEnvVarOwned(a, "VAULT_ADDR") catch return error.SkipZigTest;
    defer a.free(vault_addr);
    const vault_token = getEnvVarOwned(a, "VAULT_TOKEN") catch return error.SkipZigTest;
    defer a.free(vault_token);

    const config = KmsConfig{
        .backend = .VaultTransit,
        .vault_addr = vault_addr,
        .vault_token = vault_token,
        .vault_key_name = "geode-test-key",
    };
    var vault = VaultTransitClient.init(a, config);
    defer vault.deinit();
    var key: [32]u8 = undefined;
    @memset(&key, 0x42);
    var env = try vault.wrap(key);
    defer env.deinitKmsCiphertext(a);
    // A second client (a restarted process) unwraps the envelope.
    var fresh = VaultTransitClient.init(a, config);
    defer fresh.deinit();
    const recovered = try fresh.unwrap(env);
    try std.testing.expect(std.mem.eql(u8, &key, &recovered));
}

test "aws kms integration test" {
    const a = std.testing.allocator;
    const endpoint = getEnvVarOwned(a, "AWS_KMS_ENDPOINT") catch return error.SkipZigTest;
    defer a.free(endpoint);
    const access = getEnvVarOwned(a, "AWS_ACCESS_KEY_ID") catch return error.SkipZigTest;
    defer a.free(access);
    const secret = getEnvVarOwned(a, "AWS_SECRET_ACCESS_KEY") catch return error.SkipZigTest;
    defer a.free(secret);
    const key_id = getEnvVarOwned(a, "AWS_KMS_KEY_ID") catch try a.dupe(u8, "alias/testing");
    defer a.free(key_id);
    const region = getEnvVarOwned(a, "AWS_REGION") catch try a.dupe(u8, "us-east-1");
    defer a.free(region);

    const config = KmsConfig{
        .backend = .AwsKms,
        .aws_endpoint = endpoint,
        .aws_key_id = key_id,
        .aws_region = region,
        .aws_access_key = access,
        .aws_secret_key = secret,
    };
    var aws = AwsKmsClient.init(a, config);
    defer aws.deinit();
    var key: [32]u8 = undefined;
    @memset(&key, 0x55);
    var env = try aws.wrap(key);
    defer env.deinitKmsCiphertext(a);
    var fresh = AwsKmsClient.init(a, config);
    defer fresh.deinit();
    const recovered = try fresh.unwrap(env);
    try std.testing.expect(std.mem.eql(u8, &key, &recovered));

    const generated = try aws.generateKey();
    try std.testing.expect(!std.mem.allEqual(u8, &generated, 0));
}
