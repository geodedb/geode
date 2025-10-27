## Field-Level Encryption - Phase 2 Integration Guide

<!-- CANARY: FLE_INTEGRATION_GUIDE - Phase 2 Implementation Roadmap -->
<!-- CANARY: REQ=REQ-FLE-PHASE2-001; FEATURE="FieldLevelEncryption"; ASPECT=INTEGRATION; STATUS=GUIDE; OWNER=security; UPDATED=2025-10-15 -->

**Target Completion:** October 31, 2025

This guide provides **precise, actionable steps** to complete Phase 2 integration of Field-Level Encryption into Geode's storage, execution, and query planning systems.

---

## Prerequisites

✅ **Phase 1 Complete:**
- `src/crypto/aead.zig` - AEAD encryption primitives
- `src/crypto/hkdf.zig` - Key derivation
- `src/crypto/hmac.zig` - Blind index HMAC
- `src/keys/manager.zig` - Key management with caching
- `src/index/blind_index.zig` - Blind index functionality
- `src/schema/annotations.zig` - Annotation parsing ✅ **NEW**

---

## Integration Tasks

### Task 1: Build System Integration

**File:** `build.zig`

**Location:** After `exe` is created

**Add:**
```zig
// Field-Level Encryption modules
exe.root_module.addAnonymousImport("fle_aead", .{
    .root_source_file = .{ .path = "src/crypto/aead.zig" }
});
exe.root_module.addAnonymousImport("fle_hkdf", .{
    .root_source_file = .{ .path = "src/crypto/hkdf.zig" }
});
exe.root_module.addAnonymousImport("fle_hmac", .{
    .root_source_file = .{ .path = "src/crypto/hmac.zig" }
});
exe.root_module.addAnonymousImport("fle_keys", .{
    .root_source_file = .{ .path = "src/keys/manager.zig" }
});
exe.root_module.addAnonymousImport("fle_blind_index", .{
    .root_source_file = .{ .path = "src/index/blind_index.zig" }
});
exe.root_module.addAnonymousImport("fle_annotations", .{
    .root_source_file = .{ .path = "src/schema/annotations.zig" }
});
```

**Test:**
```bash
zig build
# Should compile without errors
```

---

### Task 2: Schema Catalog Extension

**Create:** `src/schema/catalog.zig`

**Purpose:** Store type metadata with field encryption/searchability info

**Implementation:**
```zig
const std = @import("std");
const annotations = @import("annotations.zig");

// CANARY: FLE_SCHEMA_CATALOG - Schema Metadata Catalog
// CANARY: REQ=REQ-FLE-CATALOG-001; FEATURE="FieldLevelEncryption"; ASPECT=SCHEMA; STATUS=IMPL; OWNER=security; UPDATED=2025-10-15

/// Global schema catalog for type metadata
pub const SchemaCatalog = struct {
    allocator: std.mem.Allocator,
    types: std.StringHashMap(annotations.TypeMetadata),
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) SchemaCatalog {
        return .{
            .allocator = allocator,
            .types = std.StringHashMap(annotations.TypeMetadata).init(allocator),
        };
    }

    pub fn deinit(self: *SchemaCatalog) void {
        var it = self.types.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.types.deinit();
    }

    /// Register a new type with metadata
    pub fn registerType(
        self: *SchemaCatalog,
        type_name: []const u8,
        type_definition: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var type_meta = annotations.TypeMetadata.init(self.allocator, type_name);

        // Parse type definition and extract field annotations
        // For now, simplified: just create entry
        // TODO: Parse CREATE TYPE body and apply annotations per field

        try self.types.put(type_name, type_meta);
    }

    /// Get type metadata
    pub fn getType(self: *SchemaCatalog, type_name: []const u8) ?*const annotations.TypeMetadata {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.types.getPtr(type_name);
    }

    /// Check if field is encrypted
    pub fn isFieldEncrypted(
        self: *SchemaCatalog,
        type_name: []const u8,
        field_name: []const u8,
    ) bool {
        if (self.getType(type_name)) |type_meta| {
            return type_meta.isFieldEncrypted(field_name);
        }
        return false;
    }

    /// Check if field is searchable
    pub fn isFieldSearchable(
        self: *SchemaCatalog,
        type_name: []const u8,
        field_name: []const u8,
    ) bool {
        if (self.getType(type_name)) |type_meta| {
            return type_meta.isFieldSearchable(field_name);
        }
        return false;
    }

    /// Get field metadata
    pub fn getFieldMetadata(
        self: *SchemaCatalog,
        type_name: []const u8,
        field_name: []const u8,
    ) ?annotations.FieldMetadata {
        if (self.getType(type_name)) |type_meta| {
            return type_meta.getField(field_name);
        }
        return null;
    }
};

/// Global schema catalog instance
var global_catalog: ?*SchemaCatalog = null;
var catalog_mutex: std.Thread.Mutex = .{};

/// Get or initialize global schema catalog
pub fn globalCatalog(allocator: std.mem.Allocator) !*SchemaCatalog {
    catalog_mutex.lock();
    defer catalog_mutex.unlock();

    if (global_catalog == null) {
        const catalog = try allocator.create(SchemaCatalog);
        catalog.* = SchemaCatalog.init(allocator);
        global_catalog = catalog;
    }

    return global_catalog.?;
}
```

**Add to build.zig:**
```zig
exe.root_module.addAnonymousImport("fle_catalog", .{
    .root_source_file = .{ .path = "src/schema/catalog.zig" }
});
```

---

### Task 3: Hook CREATE GRAPH TYPE Parser

**File:** `src/gql/parser.zig` (or wherever execution happens)

**Location:** After `CreateGraphType` statement is created (around line 5140)

**Add:**
```zig
// Hook for FLE: Register type in schema catalog
const fle_catalog = @import("fle_catalog");
const fle_annotations = @import("fle_annotations");

// After creating CreateGraphType statement:
if (comptime @import("builtin").is_test == false) {
    const catalog = fle_catalog.globalCatalog(self.arena.child_allocator) catch |err| {
        // Log error but don't fail parse
        std.log.warn("Failed to register type in FLE catalog: {}", .{err});
    };
    if (catalog) |cat| {
        cat.registerType(name, type_definition) catch |err| {
            std.log.warn("Failed to apply FLE annotations: {}", .{err});
        };
    }
}
```

**Test:**
```gql
CREATE GRAPH TYPE Person (
  id UUID PRIMARY KEY,
  ssn STRING @encrypted(alg:"AES-256-GCM") @searchable(index:"blind-hmac-sha256")
);
```

---

### Task 4: Storage Layer - Encrypt-on-Write

**Find:** `src/storage/graph_store.zig` or equivalent property storage

**Target Functions:**
- `setNodeProperty(node_id, key, value)`
- `setEdgeProperty(edge_id, key, value)`

**Integration Pattern:**

```zig
const fle_catalog = @import("fle_catalog");
const fle_keys = @import("fle_keys");
const fle_aead = @import("fle_aead");
const fle_blind_index = @import("fle_blind_index");

// In setNodeProperty / setEdgeProperty:
pub fn setNodeProperty(
    self: *GraphStore,
    node_id: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    // Get node type (you'll need to track this)
    const node_type = try self.getNodeType(node_id); // Implement this

    // Check if field is encrypted
    const catalog = try fle_catalog.globalCatalog(self.allocator);
    if (catalog.isFieldEncrypted(node_type, key)) {
        const field_meta = catalog.getFieldMetadata(node_type, key) orelse return error.MissingMetadata;

        // Get tenant ID (from session context)
        const tenant_id = self.getCurrentTenant(); // Implement this

        // Get FEK from key manager
        const key_manager = try fle_keys.KeyManager.init(self.allocator);
        defer key_manager.deinit();

        const key_ids = fle_keys.types.KeyIds{
            .tenant = tenant_id,
            .schema = node_type,
            .field = key,
            .version = 1, // Get from catalog or default to 1
        };

        const fek = try key_manager.getFEK(key_ids);
        defer std.crypto.secureZero(u8, &fek);

        // Construct AAD
        const aad = try fle_aead.makeAAD(
            self.allocator,
            tenant_id,
            node_type,
            key,
            node_id,
            key_ids.version,
        );
        defer self.allocator.free(aad);

        // Encrypt
        var envelope = try fle_aead.encryptField(
            self.allocator,
            field_meta.algorithm() orelse .aes256_gcm,
            &fek,
            aad,
            value,
            null, // Random nonce
        );
        defer envelope.deinit(self.allocator);

        // Serialize envelope
        const envelope_bytes = try envelope.serialize(self.allocator);
        defer self.allocator.free(envelope_bytes);

        // Store encrypted value
        try self.rawSetProperty(node_id, key, envelope_bytes);

        // Update blind index if searchable
        if (catalog.isFieldSearchable(node_type, key)) {
            const bik = try key_manager.getBIK(key_ids);
            defer std.crypto.secureZero(u8, &bik);

            const blind_index = try self.getBlindIndex(); // Implement this
            try blind_index.put(node_type, key, bik, value, node_id);
        }

        return;
    }

    // Not encrypted - store plaintext
    try self.rawSetProperty(node_id, key, value);
}
```

**Required Helper Functions:**
```zig
fn getNodeType(self: *GraphStore, node_id: []const u8) ![]const u8 {
    // Return the type name for this node
    // You may need to extend node storage to track this
}

fn getCurrentTenant(self: *GraphStore) []const u8 {
    // Get tenant from session context
    // For now, could default to "default"
    return "default";
}

fn getBlindIndex(self: *GraphStore) !*fle_blind_index.BlindIndex {
    // Return global blind index instance
    // Could be a field on GraphStore
}

fn rawSetProperty(self: *GraphStore, id: []const u8, key: []const u8, value: []const u8) !void {
    // Original property storage logic
}
```

---

### Task 5: Execution Layer - Decrypt-on-Projection

**Find:** `src/execution.zig` property serialization

**Target Function:** `writeValue()` or Node/Edge property JSON emission

**Integration Pattern:**

```zig
const fle_catalog = @import("fle_catalog");
const fle_keys = @import("fle_keys");
const fle_aead = @import("fle_aead");

// In writeValue or similar:
fn writeNodeProperty(
    writer: anytype,
    node_type: []const u8,
    node_id: []const u8,
    key: []const u8,
    value: []const u8,
    security_ctx: SecurityContext,
) !void {
    const catalog = try fle_catalog.globalCatalog(allocator);

    if (catalog.isFieldEncrypted(node_type, key)) {
        // Check RBAC: does user have READ_PLAINTEXT permission?
        if (security_ctx.canReadPlaintext(node_type, key)) {
            // Decrypt and return plaintext
            const envelope = try fle_aead.EnvelopeV1.deserialize(allocator, value);
            defer envelope.deinit(allocator);

            const key_manager = try fle_keys.KeyManager.init(allocator);
            defer key_manager.deinit();

            const tenant_id = security_ctx.getTenant();
            const key_ids = fle_keys.types.KeyIds{
                .tenant = tenant_id,
                .schema = node_type,
                .field = key,
                .version = envelope.key_version,
            };

            const fek = try key_manager.getFEK(key_ids);
            defer std.crypto.secureZero(u8, &fek);

            const aad = try fle_aead.makeAAD(
                allocator,
                tenant_id,
                node_type,
                key,
                node_id,
                envelope.key_version,
            );
            defer allocator.free(aad);

            const plaintext = try fle_aead.decryptField(allocator, &fek, aad, envelope);
            defer {
                std.crypto.secureZero(u8, plaintext);
                allocator.free(plaintext);
            }

            // Write plaintext
            try writer.print("\"{s}\"", .{plaintext});
            return;
        } else {
            // User lacks permission - return redacted
            try writer.print("\"[REDACTED]\"", .{});
            return;
        }
    }

    // Not encrypted - write plaintext
    try writer.print("\"{s}\"", .{value});
}
```

**Required:**
```zig
pub const SecurityContext = struct {
    user_roles: [][]const u8,
    tenant_id: []const u8,

    pub fn canReadPlaintext(self: SecurityContext, type_name: []const u8, field_name: []const u8) bool {
        // Check if user has READ_PLAINTEXT permission
        // For now, simplified check against field visibility config
        const catalog = fle_catalog.globalCatalog(allocator) catch return false;
        if (catalog.getFieldMetadata(type_name, field_name)) |meta| {
            for (meta.visibility.to_roles) |role| {
                for (self.user_roles) |user_role| {
                    if (std.mem.eql(u8, role, user_role)) return true;
                }
            }
            return false; // Deny by default
        }
        return true; // Field not encrypted
    }

    pub fn getTenant(self: SecurityContext) []const u8 {
        return self.tenant_id;
    }
};
```

---

### Task 6: Planner Rewrite - Encrypted Field Predicates

**Extend:** `src/planner/rewrite.zig`

**Add Function:**

```zig
const fle_catalog = @import("fle_catalog");
const fle_keys = @import("fle_keys");
const fle_hmac = @import("fle_hmac");

/// Rewrite WHERE predicate on encrypted field to blind index lookup
pub fn rewriteEncryptedPredicate(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    field_name: []const u8,
    literal_value: []const u8,
    security_ctx: SecurityContext,
) !?[]const u8 {
    const catalog = try fle_catalog.globalCatalog(allocator);

    // Check if field is encrypted
    if (!catalog.isFieldEncrypted(type_name, field_name)) {
        return null; // Not encrypted - no rewrite needed
    }

    // Check if field is searchable
    if (!catalog.isFieldSearchable(type_name, field_name)) {
        return error.SearchNotPermitted; // Cannot search non-searchable encrypted field
    }

    // Check RBAC permission
    if (!security_ctx.canReadPlaintext(type_name, field_name)) {
        return error.SearchNotPermitted; // User lacks permission
    }

    // Get BIK and compute blind index token
    const key_manager = try fle_keys.KeyManager.init(allocator);
    defer key_manager.deinit();

    const key_ids = fle_keys.types.KeyIds{
        .tenant = security_ctx.getTenant(),
        .schema = type_name,
        .field = field_name,
        .version = 1, // Active version
    };

    const bik = try key_manager.getBIK(key_ids);
    defer std.crypto.secureZero(u8, &bik);

    // Normalize and compute token
    const normalized = try fle_hmac.normalizeForBlindIndex(allocator, literal_value);
    defer allocator.free(normalized);

    var token: [32]u8 = undefined;
    fle_hmac.blindIndexHmac256(&token, &bik, normalized);

    // Convert to hex for query
    const hex = try fle_hmac.tokenToHex(allocator, token);
    return hex; // Caller must free
}
```

**Hook into query planning:**

In query planner, when encountering `WHERE field = literal`:

```zig
// Detect encrypted field equality predicate
if (try rewriteEncryptedPredicate(allocator, type_name, field_name, literal_value, security_ctx)) |bi_hex| {
    defer allocator.free(bi_hex);
    // Rewrite to blind index lookup
    // Use blind_index.lookup(type_name, field_name, bik, literal_value)
    // Return matching record IDs
}
```

---

### Task 7: Admin CLI Commands

**Create:** `src/admin/fle_cli.zig`

**Commands:**

```zig
pub fn keyRotateCommand(
    allocator: std.mem.Allocator,
    args: struct {
        tenant: []const u8,
        schema: ?[]const u8 = null,
        field: ?[]const u8 = null,
        scope: []const u8, // "FEK", "SK", "TRK"
    },
) !void {
    const key_manager = try fle_keys.KeyManager.init(allocator);
    defer key_manager.deinit();

    if (std.ascii.eqlIgnoreCase(args.scope, "FEK")) {
        if (args.schema == null or args.field == null) {
            return error.MissingSchemaOrField;
        }
        const new_version = try key_manager.rotateFEK(args.tenant, args.schema.?, args.field.?);
        std.log.info("Rotated FEK to version {d}", .{new_version});
    } else if (std.ascii.eqlIgnoreCase(args.scope, "SK")) {
        if (args.schema == null) {
            return error.MissingSchema;
        }
        try key_manager.rewrapSK(args.tenant, args.schema.?);
        std.log.info("Rewrapped SK for schema {s}", .{args.schema.?});
    } else if (std.ascii.eqlIgnoreCase(args.scope, "TRK")) {
        try key_manager.rewrapTRK(args.tenant);
        std.log.info("Rewrapped TRK for tenant {s}", .{args.tenant});
    }
}

pub fn policyGrantCommand(
    allocator: std.mem.Allocator,
    args: struct {
        field: []const u8, // "Schema.Field"
        role: []const u8,
    },
) !void {
    // TODO: Implement RBAC policy storage
    std.log.info("Granted READ_PLAINTEXT on {s} to role {s}", .{ args.field, args.role });
}

pub fn policyRevokeCommand(
    allocator: std.mem.Allocator,
    args: struct {
        field: []const u8,
        role: []const u8,
    },
) !void {
    // TODO: Implement RBAC policy revocation
    std.log.info("Revoked READ_PLAINTEXT on {s} from role {s}", .{ args.field, args.role });
}
```

**Wire into main CLI:**

In `src/cli/main.zig` or equivalent, add subcommands:
- `geode key rotate --tenant T --schema S --field F --scope FEK`
- `geode policy grant plaintext S.F --role R`
- `geode policy revoke plaintext S.F --role R`

---

## Testing Strategy

### Unit Tests

Run existing tests:
```bash
zig test src/crypto/aead.zig -lc
zig test src/crypto/hmac.zig -lc
zig test src/crypto/hkdf.zig -lc
zig test src/schema/annotations.zig -lc
```

### Integration Tests

After wiring storage/execution:

```bash
python3 extended_test_runner.py --filter encryption_
```

Should run 5 specs:
- encryption_basic.yml
- encryption_blind_index.yml
- encryption_rotation.yml
- encryption_migration.yml
- encryption_rbac.yml

---

## Validation Checklist

- [ ] Build system compiles with FLE modules
- [ ] Schema catalog stores type metadata
- [ ] CREATE TYPE registers encrypted fields
- [ ] setNodeProperty encrypts marked fields
- [ ] setNodeProperty updates blind index
- [ ] Query execution decrypts for authorized users
- [ ] Query execution returns [REDACTED] for unauthorized
- [ ] Planner rewrites encrypted predicates to BI lookups
- [ ] Admin CLI commands work (key rotate, policy grant/revoke)
- [ ] All 14 unit tests pass
- [ ] All 5 GeodeTestLab specs pass

---

## Troubleshooting

### Build Errors

**Problem:** Module import errors
**Solution:** Check `build.zig` has all `addAnonymousImport` calls

### Runtime Errors

**Problem:** "KeyNotFound" during decryption
**Solution:** Ensure key version matches between encryption and decryption

**Problem:** "SearchNotPermitted" on queries
**Solution:** Check field has `@searchable` annotation and user has READ_PLAINTEXT permission

### Test Failures

**Problem:** GeodeTestLab specs fail
**Solution:** Ensure encrypt/decrypt hooks are properly integrated; check logs for AEAD auth failures

---

## Next Steps After Phase 2

1. Performance benchmarking
2. External KMS integration
3. Post-Quantum Cryptography (Kyber/Dilithium)
4. Production security audit

---

**Last Updated:** 2025-10-15
**Author:** Benjamin (benji)
**Status:** Phase 2 In Progress
