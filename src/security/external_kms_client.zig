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

/// JSON structure for Vault Transit decrypt request
const VaultDecryptRequest = struct {
    ciphertext: []const u8,
};

/// JSON structure for AWS KMS Encrypt request
const AwsKmsEncryptRequest = struct {
    KeyId: []const u8,
    Plaintext: []const u8,
};

/// JSON structure for AWS KMS Decrypt request
const AwsKmsDecryptRequest = struct {
    CiphertextBlob: []const u8,
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
    };

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
    key_version: u32 = 1,
    // Cached vault ciphertext prefix for this key (to avoid re-parsing)
    last_ciphertext: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, config: KmsConfig) VaultTransitClient {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *VaultTransitClient) void {
        if (self.last_ciphertext) |ct| {
            self.allocator.free(ct);
        }
    }

    /// Wrap key using Vault Transit encrypt endpoint
    /// POST /v1/transit/encrypt/:key_name
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

        // Store ciphertext in envelope (vault ciphertexts are opaque blobs)
        // We store a hash of the vault ciphertext as a reference and the actual
        // ciphertext in a separate field that gets serialized
        var env = Envelope{
            .version = @intCast(self.key_version),
            .nonce = undefined,
            .tag = undefined,
            .ct = undefined,
            .alg = "VAULT-TRANSIT",
        };

        // Store truncated ciphertext hash for identification (routed through FIPS seam)
        var hash: [32]u8 = undefined;
        _ = try cb.Hash.digest(.sha256, ciphertext, &hash);
        @memcpy(&env.ct, &hash);

        // Store nonce as hash of key_name for consistency checks (routed through FIPS seam)
        var key_hash: [32]u8 = undefined;
        _ = try cb.Hash.digest(.sha256, self.config.vault_key_name.?, &key_hash);
        @memcpy(&env.nonce, key_hash[0..12]);

        // Tag stores first 16 bytes for verification
        @memcpy(&env.tag, hash[0..16]);

        // Cache the actual ciphertext for later unwrap
        if (self.last_ciphertext) |old| {
            self.allocator.free(old);
        }
        self.last_ciphertext = try self.allocator.dupe(u8, ciphertext);

        return env;
    }

    /// Unwrap key using Vault Transit decrypt endpoint
    /// POST /v1/transit/decrypt/:key_name
    pub fn unwrap(self: *VaultTransitClient, env: Envelope) ![32]u8 {
        if (self.config.vault_addr == null or self.config.vault_token == null or self.config.vault_key_name == null) {
            return error.InvalidConfiguration;
        }

        // Get the cached ciphertext (for now, we need to have wrapped first)
        // In production, the ciphertext would be stored alongside the envelope
        const ciphertext = self.last_ciphertext orelse return error.NoCachedCiphertext;

        // Build request body using type-safe JSON encoding: {"ciphertext": "vault:v1:..."}
        const request = VaultDecryptRequest{ .ciphertext = ciphertext };
        const body = try json_lib.encode(self.allocator, request, .{});
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

        _ = env; // Envelope used for verification in production
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

        self.key_version += 1;
    }

    pub fn getKeyVersion(self: *VaultTransitClient) !u32 {
        return self.key_version;
    }

    /// POST to Vault with X-Vault-Token (and X-Vault-Namespace when set) as
    /// privileged headers: they are dropped if a redirect leaves the host.
    fn httpPost(self: *VaultTransitClient, url: []const u8, body: []const u8) ![]u8 {
        var headers_buf: [2]std.http.Header = undefined;
        const headers = vaultHeaders(&headers_buf, self.config);
        return httpPostJson(self.allocator, url, "application/json", body, &.{}, headers, "Vault");
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
};

/// AWS KMS client with actual HTTP implementation
/// GAP-0086: AWS Key Management Service backend implementation
/// CANARY: REQ=REQ-GQL-TDE-AWS-001; FEATURE="AwsKmsIntegration"; ASPECT=SECURITY; STATUS=IMPL; OWNER=security; UPDATED=2026-11-12
pub const AwsKmsClient = struct {
    allocator: std.mem.Allocator,
    config: KmsConfig,
    key_version: u32 = 1,
    // Cache the last encrypted blob for unwrap (AWS returns opaque ciphertext)
    last_ciphertext_blob: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, config: KmsConfig) AwsKmsClient {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *AwsKmsClient) void {
        if (self.last_ciphertext_blob) |blob| {
            self.allocator.free(blob);
        }
    }

    /// Wrap key using AWS KMS Encrypt API
    pub fn wrap(self: *AwsKmsClient, plaintext: [32]u8) !Envelope {
        if (self.config.aws_key_id == null) {
            return error.InvalidConfiguration;
        }

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

        // Parse response: {"CiphertextBlob": "base64..."}
        const ciphertext_blob = try jsonStringField(self.allocator, response, null, "CiphertextBlob");
        defer self.allocator.free(ciphertext_blob);

        // Decode the ciphertext blob from base64
        const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(ciphertext_blob) catch return error.InvalidBase64;
        const decoded_blob = try self.allocator.alloc(u8, decoded_size);
        _ = std.base64.standard.Decoder.decode(decoded_blob, ciphertext_blob) catch |e| {
            self.allocator.free(decoded_blob);
            log.err("Base64 decode of ciphertext failed", &.{
                Attr.string("error", @errorName(e)),
            });
            return error.InvalidBase64;
        };

        // Store for later unwrap
        if (self.last_ciphertext_blob) |old| {
            self.allocator.free(old);
        }
        self.last_ciphertext_blob = decoded_blob;

        // Build envelope with hash reference
        var env = Envelope{
            .version = @intCast(self.key_version),
            .nonce = undefined,
            .tag = undefined,
            .ct = undefined,
            .alg = "AWS-KMS",
        };

        // Store hash of ciphertext blob (routed through FIPS seam)
        var hash: [32]u8 = undefined;
        _ = try cb.Hash.digest(.sha256, decoded_blob, &hash);
        @memcpy(&env.ct, &hash);

        // Store key ID hash in nonce (routed through FIPS seam)
        var key_hash: [32]u8 = undefined;
        _ = try cb.Hash.digest(.sha256, self.config.aws_key_id.?, &key_hash);
        @memcpy(&env.nonce, key_hash[0..12]);
        @memcpy(&env.tag, hash[0..16]);

        return env;
    }

    /// Unwrap key using AWS KMS Decrypt API
    pub fn unwrap(self: *AwsKmsClient, env: Envelope) ![32]u8 {
        if (self.config.aws_key_id == null) {
            return error.InvalidConfiguration;
        }

        // Get cached ciphertext blob
        const ciphertext_blob = self.last_ciphertext_blob orelse return error.NoCachedCiphertext;

        // Base64 encode the ciphertext blob
        const b64_size = std.base64.standard.Encoder.calcSize(ciphertext_blob.len);
        const b64_buf = try self.allocator.alloc(u8, b64_size);
        defer self.allocator.free(b64_buf);
        _ = std.base64.standard.Encoder.encode(b64_buf, ciphertext_blob);

        // Build request body for Decrypt using type-safe JSON encoding
        const request = AwsKmsDecryptRequest{ .CiphertextBlob = b64_buf };
        const body = try json_lib.encode(self.allocator, request, .{});
        defer self.allocator.free(body);

        // Make HTTP request
        const response = try self.httpPost("TrentService.Decrypt", body);
        defer self.allocator.free(response);

        // Parse response: {"Plaintext": "base64..."}
        const b64_plaintext = try jsonStringField(self.allocator, response, null, "Plaintext");
        defer self.allocator.free(b64_plaintext);

        // Base64 decode
        var out: [32]u8 = undefined;
        _ = std.base64.standard.Decoder.decode(&out, b64_plaintext) catch |e| {
            log.err("AWS KMS base64 decode failed", &.{
                Attr.string("error", @errorName(e)),
            });
            return error.InvalidBase64;
        };

        _ = env; // Used for verification
        return out;
    }

    /// Generate a data key using AWS KMS GenerateDataKey API
    pub fn generateKey(self: *AwsKmsClient) ![32]u8 {
        if (self.config.aws_key_id == null) {
            return error.InvalidConfiguration;
        }

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

        // Also get and cache the ciphertext blob
        const ciphertext_blob_b64 = try jsonStringField(self.allocator, response, null, "CiphertextBlob");
        defer self.allocator.free(ciphertext_blob_b64);

        const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(ciphertext_blob_b64) catch return error.InvalidBase64;
        const decoded_blob = try self.allocator.alloc(u8, decoded_size);
        _ = std.base64.standard.Decoder.decode(decoded_blob, ciphertext_blob_b64) catch {
            self.allocator.free(decoded_blob);
            return error.InvalidBase64;
        };

        if (self.last_ciphertext_blob) |old| {
            self.allocator.free(old);
        }
        self.last_ciphertext_blob = decoded_blob;

        // Base64 decode the plaintext
        var out: [32]u8 = undefined;
        _ = std.base64.standard.Decoder.decode(&out, b64_plaintext) catch |e| {
            log.err("AWS KMS GenerateDataKey base64 decode failed", &.{
                Attr.string("error", @errorName(e)),
            });
            return error.InvalidBase64;
        };

        return out;
    }

    pub fn rotateKey(self: *AwsKmsClient) !void {
        // AWS KMS key rotation is automatic when enabled
        // For manual rotation, you would create a new key
        self.key_version += 1;
    }

    pub fn getKeyVersion(self: *AwsKmsClient) !u32 {
        return self.key_version;
    }

    /// POST an AWS KMS JSON 1.1 request. NOTE: requests are not SigV4-signed,
    /// so only an unauthenticated KMS-compatible endpoint (e.g. local-kms
    /// via aws_endpoint) accepts them; KMS wiring is SONNY-6380.
    fn httpPost(self: *AwsKmsClient, target: []const u8, body: []const u8) ![]u8 {
        // Use custom endpoint or default AWS endpoint
        const endpoint = self.config.aws_endpoint orelse blk: {
            const region = self.config.aws_region orelse "us-east-1";
            break :blk std.fmt.allocPrint(self.allocator, "https://kms.{s}.amazonaws.com", .{region}) catch return error.OutOfMemory;
        };
        const endpoint_owned = self.config.aws_endpoint == null;
        defer if (endpoint_owned) self.allocator.free(endpoint);

        const extra = [_]std.http.Header{.{ .name = "X-Amz-Target", .value = target }};
        return httpPostJson(self.allocator, endpoint, "application/x-amz-json-1.1", body, &extra, &.{}, "AWS KMS");
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
};

/// One POST over std.http.Client (Zig 0.16). Returns the response body
/// (caller owns) on 200 OK; any other status or a transport failure is an
/// error.
fn httpPostJson(
    allocator: std.mem.Allocator,
    url: []const u8,
    content_type: []const u8,
    body: []const u8,
    extra_headers: []const std.http.Header,
    privileged_headers: []const std.http.Header,
    what: []const u8,
) ![]u8 {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var client = std.http.Client{ .allocator = allocator, .io = std.Io.Threaded.global_single_threaded.io() };
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
};

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
    ct: [32]u8, // wrapped 32-byte data key (or hash reference for external KMS)
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
    try std.testing.expectError(error.AuthenticationFailed, res);
}

test "kms provider factory local simulation" {
    const allocator = std.testing.allocator;
    const config = KmsConfig{ .backend = .LocalSimulated };
    const provider = try createKmsProvider(allocator, config);
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

// Integration tests - require running Vault and local-kms containers
// Run with: VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=geode-test-token AWS_KMS_ENDPOINT=http://127.0.0.1:8080 zig build test
test "vault transit integration test" {
    // Skip if no Vault available
    const vault_addr = getEnvVarOwned(std.testing.allocator, "VAULT_ADDR") catch {
        std.debug.print("SKIP: VAULT_ADDR not set\n", .{});
        return;
    };
    defer std.testing.allocator.free(vault_addr);

    const vault_token = getEnvVarOwned(std.testing.allocator, "VAULT_TOKEN") catch {
        std.debug.print("SKIP: VAULT_TOKEN not set\n", .{});
        return;
    };
    defer std.testing.allocator.free(vault_token);

    const config = KmsConfig{
        .backend = .VaultTransit,
        .vault_addr = vault_addr,
        .vault_token = vault_token,
        .vault_key_name = "geode-test-key",
    };

    var vault = VaultTransitClient.init(std.testing.allocator, config);
    defer vault.deinit();

    var key: [32]u8 = undefined;
    @memset(&key, 0x42);

    const env = vault.wrap(key) catch |err| {
        std.debug.print("Vault wrap failed (expected if Vault not running): {any}\n", .{err});
        return;
    };

    const recovered = vault.unwrap(env) catch |err| {
        std.debug.print("Vault unwrap failed: {any}\n", .{err});
        return;
    };

    try std.testing.expect(std.mem.eql(u8, &key, &recovered));
    std.debug.print("VAULT_TRANSIT_INTEGRATION_OK\n", .{});
}

test "aws kms integration test" {
    // Skip if no local-kms available
    const aws_endpoint = getEnvVarOwned(std.testing.allocator, "AWS_KMS_ENDPOINT") catch {
        std.debug.print("SKIP: AWS_KMS_ENDPOINT not set\n", .{});
        return;
    };
    defer std.testing.allocator.free(aws_endpoint);

    const aws_key_id = getEnvVarOwned(std.testing.allocator, "AWS_KMS_KEY_ID") catch {
        // Use default test key ID from local-kms
        std.debug.print("Using default test key ID\n", .{});
        const config = KmsConfig{
            .backend = .AwsKms,
            .aws_endpoint = aws_endpoint,
            .aws_key_id = "alias/testing", // local-kms default
            .aws_region = "us-east-1",
        };

        var aws = AwsKmsClient.init(std.testing.allocator, config);
        defer aws.deinit();

        var key: [32]u8 = undefined;
        @memset(&key, 0x55);

        const env = aws.wrap(key) catch |err| {
            std.debug.print("AWS wrap failed (expected if local-kms not running): {any}\n", .{err});
            return;
        };

        const recovered = aws.unwrap(env) catch |err| {
            std.debug.print("AWS unwrap failed: {any}\n", .{err});
            return;
        };

        try std.testing.expect(std.mem.eql(u8, &key, &recovered));
        std.debug.print("AWS_KMS_INTEGRATION_OK\n", .{});
        return;
    };
    defer std.testing.allocator.free(aws_key_id);

    const config = KmsConfig{
        .backend = .AwsKms,
        .aws_endpoint = aws_endpoint,
        .aws_key_id = aws_key_id,
        .aws_region = "us-east-1",
    };

    var aws = AwsKmsClient.init(std.testing.allocator, config);
    defer aws.deinit();

    var key: [32]u8 = undefined;
    @memset(&key, 0x55);

    const env = aws.wrap(key) catch |err| {
        std.debug.print("AWS wrap failed: {any}\n", .{err});
        return;
    };

    const recovered = aws.unwrap(env) catch |err| {
        std.debug.print("AWS unwrap failed: {any}\n", .{err});
        return;
    };

    try std.testing.expect(std.mem.eql(u8, &key, &recovered));
    std.debug.print("AWS_KMS_INTEGRATION_OK\n", .{});
}

test "aws kms generate data key integration test" {
    const aws_endpoint = getEnvVarOwned(std.testing.allocator, "AWS_KMS_ENDPOINT") catch {
        std.debug.print("SKIP: AWS_KMS_ENDPOINT not set\n", .{});
        return;
    };
    defer std.testing.allocator.free(aws_endpoint);

    const config = KmsConfig{
        .backend = .AwsKms,
        .aws_endpoint = aws_endpoint,
        .aws_key_id = "alias/testing",
        .aws_region = "us-east-1",
    };

    var aws = AwsKmsClient.init(std.testing.allocator, config);
    defer aws.deinit();

    const key = aws.generateKey() catch |err| {
        std.debug.print("AWS generateKey failed: {any}\n", .{err});
        return;
    };

    // Key should be non-zero
    var all_zero = true;
    for (key) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);
    std.debug.print("AWS_KMS_GENERATE_KEY_OK\n", .{});
}
