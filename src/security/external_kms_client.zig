const std = @import("std");
const crypto = std.crypto;

// external_kms_client.zig
// External KMS client providing abstraction over multiple KMS backends:
// - LocalSimulated: AES-256-GCM wrapping for development/testing
// - VaultTransit: HashiCorp Vault Transit backend (enterprise)
// - AwsKms: AWS Key Management Service (enterprise)
//
// GAP-0066: External KMS Integration Framework
// CANARY: REQ=REQ-GQL-TDE-EXT-KMS-001; FEATURE="ExternalKMSWrapUnwrap"; ASPECT=SECURITY; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_TDE_EXT_KMS_001_WrapUnwrap; OWNER=security; UPDATED=2026-01-10

/// KMS Backend Type
/// GAP-0066: Support for multiple KMS backends
pub const KmsBackend = enum {
    LocalSimulated, // Development/testing only
    VaultTransit, // HashiCorp Vault Transit
    AwsKms, // AWS Key Management Service
    AzureKeyVault, // Azure Key Vault (future)
    GcpKms, // Google Cloud KMS (future)
};

/// KMS Configuration for enterprise backends
/// GAP-0066: Configuration structure for external KMS integration
pub const KmsConfig = struct {
    backend: KmsBackend = .LocalSimulated,
    // Vault Transit configuration
    vault_addr: ?[]const u8 = null, // e.g., "https://vault.example.com:8200"
    vault_token: ?[]const u8 = null, // Vault authentication token
    vault_key_name: ?[]const u8 = null, // Transit key name
    vault_namespace: ?[]const u8 = null, // Vault enterprise namespace
    // AWS KMS configuration
    aws_region: ?[]const u8 = null, // e.g., "us-east-1"
    aws_key_id: ?[]const u8 = null, // KMS Key ID or ARN
    aws_access_key: ?[]const u8 = null, // Optional: use IAM role if null
    aws_secret_key: ?[]const u8 = null, // Optional: use IAM role if null
    // TLS configuration
    tls_ca_cert: ?[]const u8 = null, // CA certificate for TLS verification
    tls_skip_verify: bool = false, // Skip TLS verification (insecure, testing only)
};

/// KMS Provider interface for pluggable backends
/// GAP-0066: Unified interface for all KMS backends
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

/// Vault Transit client stub
/// GAP-0066: HashiCorp Vault Transit backend implementation
/// CANARY: REQ=REQ-GQL-TDE-VAULT-001; FEATURE="VaultTransitKMS"; ASPECT=SECURITY; STATUS=STUB; UPDATED=2026-01-10
pub const VaultTransitClient = struct {
    allocator: std.mem.Allocator,
    config: KmsConfig,
    key_version: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, config: KmsConfig) VaultTransitClient {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Wrap key using Vault Transit encrypt endpoint
    /// In production: POST /v1/transit/encrypt/:key_name
    pub fn wrap(self: *VaultTransitClient, plaintext: [32]u8) !Envelope {
        // Validate configuration
        if (self.config.vault_addr == null or self.config.vault_token == null or self.config.vault_key_name == null) {
            return error.InvalidConfiguration;
        }

        // TODO: Implement HTTP POST to Vault Transit API
        // POST {vault_addr}/v1/transit/encrypt/{key_name}
        // Headers: X-Vault-Token: {vault_token}
        // Body: {"plaintext": base64(plaintext)}
        // Response: {"data": {"ciphertext": "vault:v1:...", "key_version": 1}}

        // For now, fall back to local simulation with random nonce
        var nonce: [12]u8 = undefined;
        crypto.random.bytes(&nonce);

        // Derive KEK from vault_token for stub (insecure, dev only)
        var kek: [32]u8 = undefined;
        var h = crypto.hash.sha2.Sha256.init(.{});
        h.update(self.config.vault_token.?);
        h.update(self.config.vault_key_name.?);
        h.final(&kek);

        var ct: [32]u8 = undefined;
        var tag: [16]u8 = undefined;
        crypto.aead.aes_gcm.Aes256Gcm.encrypt(&ct, &tag, &plaintext, &.{}, nonce, kek);
        return .{ .version = @intCast(self.key_version), .nonce = nonce, .tag = tag, .ct = ct };
    }

    /// Unwrap key using Vault Transit decrypt endpoint
    /// In production: POST /v1/transit/decrypt/:key_name
    pub fn unwrap(self: *VaultTransitClient, env: Envelope) ![32]u8 {
        if (self.config.vault_addr == null or self.config.vault_token == null or self.config.vault_key_name == null) {
            return error.InvalidConfiguration;
        }

        // Derive KEK from vault_token for stub
        var kek: [32]u8 = undefined;
        var h = crypto.hash.sha2.Sha256.init(.{});
        h.update(self.config.vault_token.?);
        h.update(self.config.vault_key_name.?);
        h.final(&kek);

        var out: [32]u8 = undefined;
        crypto.aead.aes_gcm.Aes256Gcm.decrypt(&out, &env.ct, env.tag, &.{}, env.nonce, kek) catch |e| return e;
        return out;
    }

    pub fn generateKey(self: *VaultTransitClient) ![32]u8 {
        _ = self;
        var key: [32]u8 = undefined;
        crypto.random.bytes(&key);
        return key;
    }

    pub fn rotateKey(self: *VaultTransitClient) !void {
        // TODO: POST /v1/transit/keys/:key_name/rotate
        self.key_version += 1;
    }

    pub fn getKeyVersion(self: *VaultTransitClient) !u32 {
        return self.key_version;
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

/// AWS KMS client stub
/// GAP-0066: AWS Key Management Service backend implementation
/// CANARY: REQ=REQ-GQL-TDE-AWS-001; FEATURE="AwsKmsIntegration"; ASPECT=SECURITY; STATUS=STUB; UPDATED=2026-01-10
pub const AwsKmsClient = struct {
    allocator: std.mem.Allocator,
    config: KmsConfig,
    key_version: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, config: KmsConfig) AwsKmsClient {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Wrap key using AWS KMS Encrypt API
    /// In production: AWS SDK kms:Encrypt with KeyId
    pub fn wrap(self: *AwsKmsClient, plaintext: [32]u8) !Envelope {
        if (self.config.aws_region == null or self.config.aws_key_id == null) {
            return error.InvalidConfiguration;
        }

        // TODO: Implement AWS SDK call to kms:Encrypt
        // POST https://kms.{region}.amazonaws.com
        // Action: Encrypt
        // Body: {"KeyId": "{key_id}", "Plaintext": base64(plaintext)}

        // For now, fall back to local simulation
        var nonce: [12]u8 = undefined;
        crypto.random.bytes(&nonce);

        // Derive KEK from aws_key_id for stub
        var kek: [32]u8 = undefined;
        var h = crypto.hash.sha2.Sha256.init(.{});
        h.update(self.config.aws_key_id.?);
        h.update(self.config.aws_region.?);
        h.final(&kek);

        var ct: [32]u8 = undefined;
        var tag: [16]u8 = undefined;
        crypto.aead.aes_gcm.Aes256Gcm.encrypt(&ct, &tag, &plaintext, &.{}, nonce, kek);
        return .{ .version = @intCast(self.key_version), .nonce = nonce, .tag = tag, .ct = ct };
    }

    /// Unwrap key using AWS KMS Decrypt API
    /// In production: AWS SDK kms:Decrypt
    pub fn unwrap(self: *AwsKmsClient, env: Envelope) ![32]u8 {
        if (self.config.aws_region == null or self.config.aws_key_id == null) {
            return error.InvalidConfiguration;
        }

        // Derive KEK from aws_key_id for stub
        var kek: [32]u8 = undefined;
        var h = crypto.hash.sha2.Sha256.init(.{});
        h.update(self.config.aws_key_id.?);
        h.update(self.config.aws_region.?);
        h.final(&kek);

        var out: [32]u8 = undefined;
        crypto.aead.aes_gcm.Aes256Gcm.decrypt(&out, &env.ct, env.tag, &.{}, env.nonce, kek) catch |e| return e;
        return out;
    }

    pub fn generateKey(self: *AwsKmsClient) ![32]u8 {
        _ = self;
        // TODO: AWS kms:GenerateDataKey
        var key: [32]u8 = undefined;
        crypto.random.bytes(&key);
        return key;
    }

    pub fn rotateKey(self: *AwsKmsClient) !void {
        // TODO: AWS kms:EnableKeyRotation (automatic rotation) or manual key creation
        self.key_version += 1;
    }

    pub fn getKeyVersion(self: *AwsKmsClient) !u32 {
        return self.key_version;
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

/// Factory function to create KMS provider based on configuration
/// GAP-0066: Provider factory for backend selection
pub fn createKmsProvider(allocator: std.mem.Allocator, config: KmsConfig) !KmsProvider {
    switch (config.backend) {
        .LocalSimulated => {
            // Use existing Client for local simulation
            const seed = blk: {
                var h = crypto.hash.sha2.Sha256.init(.{});
                h.update("local-kms-seed");
                var digest: [32]u8 = undefined;
                h.final(&digest);
                break :blk std.mem.readInt(u64, digest[0..8], .little);
            };
            const client_ptr = try allocator.create(Client);
            client_ptr.* = Client.init(allocator, seed);
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
    crypto.random.bytes(&key);
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
    ct: [32]u8, // wrapped 32-byte data key
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    kek: [32]u8, // simulated Key Encryption Key (would be remote / HSM-controlled)
    prng: std.Random.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, seed: u64) Client {
        // Derive KEK deterministically from seed for test reproducibility; real impl would fetch
        var prng = std.Random.DefaultPrng.init(seed);
        var kek: [32]u8 = undefined;
        prng.random().bytes(&kek);
        return .{ .allocator = allocator, .kek = kek, .prng = prng };
    }

    pub fn wrap(self: *Client, data_key: [32]u8) !Envelope {
        var nonce: [12]u8 = undefined;
        self.prng.random().bytes(&nonce);
        var ct: [32]u8 = undefined;
        var tag: [16]u8 = undefined;
        crypto.aead.aes_gcm.Aes256Gcm.encrypt(&ct, &tag, &data_key, &.{}, nonce, self.kek);
        return .{ .nonce = nonce, .tag = tag, .ct = ct };
    }

    pub fn unwrap(self: *Client, env: Envelope) ![32]u8 {
        if (env.version != 1) return error.UnsupportedEnvelopeVersion;
        if (!std.mem.eql(u8, env.alg, "AES-256-GCM")) return error.UnsupportedAlgorithm;
        var out: [32]u8 = undefined;
        crypto.aead.aes_gcm.Aes256Gcm.decrypt(&out, &env.ct, env.tag, &.{}, env.nonce, self.kek) catch |e| return e;
        return out;
    }
};

// Serialization helpers (minimal JSON subset for diagnostics & persistence if needed)
pub fn envelopeToJson(env: Envelope, allocator: std.mem.Allocator) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 256);
    const w = buf.writer(allocator);
    try w.print("{{\"version\":{d},\"alg\":\"{s}\",\"nonce\":\"", .{ env.version, env.alg });
    for (env.nonce) |b| try w.print("{x:0>2}", .{b});
    try w.print("\",\"tag\":\"", .{});
    for (env.tag) |b| try w.print("{x:0>2}", .{b});
    try w.print("\",\"ct\":\"", .{});
    for (env.ct) |b| try w.print("{x:0>2}", .{b});
    try w.print("\"}}", .{});
    return try buf.toOwnedSlice(allocator);
}

pub fn envelopeFromJson(json: []const u8) !Envelope {
    // Extremely small parser assuming format produced above. Not robust; internal use only.
    var env: Envelope = undefined;
    env.version = 0; // will set below
    // find fields
    const nonce_key = std.mem.indexOf(u8, json, "\"nonce\":\"") orelse return error.InvalidEnvelope;
    const tag_key = std.mem.indexOf(u8, json, "\"tag\":\"") orelse return error.InvalidEnvelope;
    const ct_key = std.mem.indexOf(u8, json, "\"ct\":\"") orelse return error.InvalidEnvelope;
    // version
    const ver_key = std.mem.indexOf(u8, json, "\"version\":") orelse return error.InvalidEnvelope;
    var i = ver_key + 10; // skip "version": (10 chars, not 11)
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}
    if (i >= json.len) return error.InvalidEnvelope;
    env.version = std.fmt.parseInt(u8, json[i .. i + 1], 10) catch return error.InvalidEnvelope; // single digit expected
    // alg
    const alg_key = std.mem.indexOf(u8, json, "\"alg\":\"") orelse return error.InvalidEnvelope;
    const j = alg_key + 7;
    const alg_end = std.mem.indexOfScalarPos(u8, json, j, '"') orelse return error.InvalidEnvelope;
    const alg_slice = json[j..alg_end];
    if (!std.mem.eql(u8, alg_slice, "AES-256-GCM")) return error.UnsupportedAlgorithm;
    // nonce hex (24 chars)
    const nonce_start = nonce_key + 9;
    const nonce_end = nonce_start + 24;
    if (nonce_end > json.len) return error.InvalidEnvelope;
    var k: usize = 0;
    while (k < 12) : (k += 1) env.nonce[k] = std.fmt.parseInt(u8, json[nonce_start + k * 2 .. nonce_start + k * 2 + 2], 16) catch 0;
    // tag hex (32 chars)
    const tag_start = tag_key + 7;
    const tag_end = tag_start + 32;
    if (tag_end > json.len) return error.InvalidEnvelope;
    k = 0;
    while (k < 16) : (k += 1) env.tag[k] = std.fmt.parseInt(u8, json[tag_start + k * 2 .. tag_start + k * 2 + 2], 16) catch 0;
    // ct hex (64 chars)
    const ct_start = ct_key + 6;
    const ct_end = ct_start + 64;
    if (ct_end > json.len) return error.InvalidEnvelope;
    k = 0;
    while (k < 32) : (k += 1) env.ct[k] = std.fmt.parseInt(u8, json[ct_start + k * 2 .. ct_start + k * 2 + 2], 16) catch 0;
    env.alg = "AES-256-GCM";
    return env;
}

// Basic tests
test "external kms client wrap/unwrap round trip & non-deterministic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var client = Client.init(gpa.allocator(), 0xDEEFA55E);
    var key: [32]u8 = undefined;
    @memset(&key, 0x11);
    const env1 = try client.wrap(key);
    const env2 = try client.wrap(key);
    try std.testing.expect(!std.mem.eql(u8, &env1.nonce, &env2.nonce));
    const k_out = try client.unwrap(env1);
    try std.testing.expect(std.mem.eql(u8, &key, &k_out));
    // Tamper tag
    var tampered = env1;
    tampered.tag[0] ^= 0xFF;
    const res = client.unwrap(tampered);
    try std.testing.expectError(error.AuthenticationFailed, res);
}

// GAP-0066: KMS Provider framework tests
test "vault transit client wrap/unwrap round trip" {
    const allocator = std.testing.allocator;
    const config = KmsConfig{
        .backend = .VaultTransit,
        .vault_addr = "https://vault.example.com:8200",
        .vault_token = "test-token-12345",
        .vault_key_name = "geode-transit-key",
    };
    var vault = VaultTransitClient.init(allocator, config);
    var key: [32]u8 = undefined;
    @memset(&key, 0x42);
    const env = try vault.wrap(key);
    const recovered = try vault.unwrap(env);
    try std.testing.expect(std.mem.eql(u8, &key, &recovered));
    std.debug.print("VAULT_TRANSIT_WRAP_UNWRAP_OK\n", .{});
}

test "aws kms client wrap/unwrap round trip" {
    const allocator = std.testing.allocator;
    const config = KmsConfig{
        .backend = .AwsKms,
        .aws_region = "us-east-1",
        .aws_key_id = "arn:aws:kms:us-east-1:123456789012:key/test-key",
    };
    var aws = AwsKmsClient.init(allocator, config);
    var key: [32]u8 = undefined;
    @memset(&key, 0x55);
    const env = try aws.wrap(key);
    const recovered = try aws.unwrap(env);
    try std.testing.expect(std.mem.eql(u8, &key, &recovered));
    std.debug.print("AWS_KMS_WRAP_UNWRAP_OK\n", .{});
}

test "kms provider factory local simulation" {
    const allocator = std.testing.allocator;
    const config = KmsConfig{ .backend = .LocalSimulated };
    const provider = try createKmsProvider(allocator, config);
    const key = try provider.generateKey();
    const env = try provider.wrap(key);
    const recovered = try provider.unwrap(env);
    try std.testing.expect(std.mem.eql(u8, &key, &recovered));
    std.debug.print("KMS_PROVIDER_FACTORY_OK\n", .{});
}

test "kms provider unsupported backend returns error" {
    const allocator = std.testing.allocator;
    const config = KmsConfig{ .backend = .AzureKeyVault };
    const result = createKmsProvider(allocator, config);
    try std.testing.expectError(error.UnsupportedBackend, result);
    std.debug.print("KMS_UNSUPPORTED_BACKEND_OK\n", .{});
}
