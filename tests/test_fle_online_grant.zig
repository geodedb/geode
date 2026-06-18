// FLE online grant-plaintext — `CALL geode.fle.grantPlaintext('<Label>','<field>','<role>')`
//
// This drives the REAL production dispatch (geode.storage_dispatch.executeFle)
// for the new online procedure `geode.fle.grantplaintext` and asserts that it
// grants a role READ_PLAINTEXT on an encrypted field IN-PROCESS — i.e. while the
// server is running — with the EXACT same effect as the offline
// `geode fle grant-plaintext` CLI.
//
// The online handler (handleGeodeFleGrantplaintext) and the offline CLI
// (src/admin/fle_commands.zig grantPlaintext) both resolve the same process-wide
// FLE catalog (fle_catalog.globalCatalog) and call the same
// SchemaCatalog.grantPlaintextAccess(...). The FLE decryption read path
// (fle_integration.canReadPlaintext) consults that same global catalog's
// field `visibility.to_roles`. So asserting the role lands in `to_roles` proves
// the online procedure is equivalent to the offline grant.
//
// CANARY: REQ=REQ-FLE-ONLINE-GRANT-001; FEATURE="FLEOnlineGrant"; ASPECT=GrantPlaintextDispatch; STATUS=TESTED; OWNER=security; UPDATED=2026-06-18

const std = @import("std");
const geode = @import("geode");

const fle_integration = geode.fle_integration;
const storage_dispatch = geode.storage_dispatch;
const ast = geode.gql.ast;

const testing = std.testing;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const TEST_MASTER_KEY_HEX = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// Drive `CALL geode.fle.configureField(type,field,{algorithm:'AES-256-GCM'})`
// through the real dispatch so the global FLE catalog has the encrypted field.
fn configureFleField(arena: std.mem.Allocator, type_name: []const u8, field_name: []const u8) !void {
    var type_expr = ast.Expr{ .String = type_name };
    var field_expr = ast.Expr{ .String = field_name };
    var alg_val = ast.Expr{ .String = "AES-256-GCM" };
    var map_props = [_]ast.Property{.{ .key = "algorithm", .value = &alg_val }};
    var config_expr = ast.Expr{ .Map = &map_props };
    var args = [_]*ast.Expr{ &type_expr, &field_expr, &config_expr };

    var callee = ast.Expr{ .String = "geode.fle.configureField" };
    const proc_expr = ast.Expr{ .Call = .{ .callee = &callee, .args = &args } };
    const call_stmt = ast.CallProcedure{ .procedure = proc_expr };

    const result = try storage_dispatch.executeFle(arena, "geode.fle.configurefield", call_stmt);
    try testing.expect(result != null);
}

// Drive `CALL geode.fle.grantPlaintext(type,field,role)` through the real
// dispatch — the same code path the running server executes for the online grant.
fn grantPlaintext(arena: std.mem.Allocator, type_name: []const u8, field_name: []const u8, role: []const u8) !void {
    var type_expr = ast.Expr{ .String = type_name };
    var field_expr = ast.Expr{ .String = field_name };
    var role_expr = ast.Expr{ .String = role };
    var args = [_]*ast.Expr{ &type_expr, &field_expr, &role_expr };

    var callee = ast.Expr{ .String = "geode.fle.grantPlaintext" };
    const proc_expr = ast.Expr{ .Call = .{ .callee = &callee, .args = &args } };
    const call_stmt = ast.CallProcedure{ .procedure = proc_expr };

    const result = try storage_dispatch.executeFle(arena, "geode.fle.grantplaintext", call_stmt);
    try testing.expect(result != null);
}

fn roleHasPlaintext(allocator: std.mem.Allocator, type_name: []const u8, field_name: []const u8, role: []const u8) !bool {
    const catalog = try fle_integration.catalog_mod.globalCatalog(allocator);
    const field_meta = catalog.getFieldMetadata(type_name, field_name) orelse return false;
    for (field_meta.visibility.to_roles) |r| {
        if (std.mem.eql(u8, r, role)) return true;
    }
    return false;
}

test "FLE online grant: geode.fle.grantPlaintext adds role to field visibility (== offline grant effect)" {
    const allocator = testing.allocator;

    _ = setenv("GEODE_MASTER_KEY", TEST_MASTER_KEY_HEX, 1);

    // Isolate the PERSISTED FLE catalog to a per-test temp dir so we never touch
    // /tmp and never leak config into a sibling test in the same binary.
    var catalog_tmp = std.testing.tmpDir(.{});
    defer catalog_tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &catalog_tmp.sub_path);
    defer allocator.free(data_dir);
    const data_dir_z = try allocator.dupeZ(u8, data_dir);
    defer allocator.free(data_dir_z);
    _ = setenv("GEODE_DATA_DIR", data_dir_z.ptr, 1);
    fle_integration.catalog_mod.resetGlobalCatalog(allocator);
    fle_integration.setHasEncryptedFields(false);
    defer {
        fle_integration.catalog_mod.resetGlobalCatalog(allocator);
        fle_integration.setHasEncryptedFields(false);
        _ = unsetenv("GEODE_DATA_DIR");
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 1. Configure an encrypted (locked) field via the real dispatch.
    try configureFleField(arena, "Secret", "ssn");
    try testing.expect(fle_integration.fieldRequiresEncryption("Secret", "ssn"));

    // 2. Before the grant, role 'analyst' has NO plaintext access (locked field).
    try testing.expect(!try roleHasPlaintext(allocator, "Secret", "ssn", "analyst"));

    // 3. ONLINE grant via the new procedure dispatch.
    try grantPlaintext(arena, "Secret", "ssn", "analyst");

    // 4. After the grant, role 'analyst' IS in the field visibility list — the
    //    exact same mutation the offline CLI's grantPlaintextAccess performs.
    try testing.expect(try roleHasPlaintext(allocator, "Secret", "ssn", "analyst"));

    // 5. An ungranted role is still denied.
    try testing.expect(!try roleHasPlaintext(allocator, "Secret", "ssn", "auditor"));

    // 6. Granting the same role again is idempotent (mirrors grantPlaintextAccess
    //    early-return when the role already has access) — still exactly one entry.
    try grantPlaintext(arena, "Secret", "ssn", "analyst");
    {
        const catalog = try fle_integration.catalog_mod.globalCatalog(allocator);
        const field_meta = catalog.getFieldMetadata("Secret", "ssn").?;
        var count: usize = 0;
        for (field_meta.visibility.to_roles) |r| {
            if (std.mem.eql(u8, r, "analyst")) count += 1;
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}
