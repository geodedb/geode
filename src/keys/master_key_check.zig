//! SONNY-6435 / SONNY-6442: the one check that GEODE_MASTER_KEY is the key a
//! data directory's encrypted fields were written with. `geode serve`
//! (server_init.refuseMismatchedMasterKey), `geode fle migrate-encrypt`
//! (admin/fle_commands.migrateEncrypt) and the in-process FLE key manager
//! (fle_integration.getGlobalKeyManager) all call `verifyOrRecord` before
//! they use the key.
//!
//! The directory keeps the key's check value (`fle_key_manager.
//! masterKeyCheckValue`, never the key) in `fle_master_key.kcv` beside the
//! FLE catalog, written like the catalog (private, never through a link,
//! under GEODE_TDE_KEY when set). Without a key nothing is read or written:
//! a deployment without FLE is never blocked. With a key and no recorded
//! value (a new directory, or one from before the check) the value is
//! recorded. A recorded value that does not match, or a check file that
//! cannot be read, is an error. Nothing names the key.

const std = @import("std");
const km = @import("fle_key_manager");
const tde = @import("../storage/tde_file_encryption.zig");
const fle_catalog = @import("../schema/fle_catalog.zig");
const logging = @import("logging");
const log = logging.scoped("security");
const Attr = logging.Attr;

pub const Error = error{ MasterKeyMismatch, MasterKeyCheckUnavailable };

const docs = "docs/FIELD_LEVEL_ENCRYPTION.md, \"Master key check value\"";

/// Who checks: names the caller and its refusal in messages.
pub const Caller = enum {
    /// `geode serve` at startup.
    serve,
    /// `geode fle` (admin FLE commands).
    fle_cli,
    /// The in-process FLE key manager, on first use.
    in_process,

    fn tag(self: Caller) []const u8 {
        return switch (self) {
            .serve => "startup",
            .fle_cli => "geode fle",
            .in_process => "fle",
        };
    }

    fn refusal(self: Caller) []const u8 {
        return switch (self) {
            .serve => "refusing to start",
            .fle_cli => "refusing to run",
            .in_process => "refusing to use it",
        };
    }
};

// CANARY: REQ=REQ-SONNY-6442-MASTER-KEY-CHECK-PATHS; FEATURE="Key configuration"; ASPECT=SharedVerifyOrRecord; STATUS=TESTED; TEST=tests/test_sonny6442_master_key_check_paths.zig; OWNER=security; UPDATED=2026-11-12
/// Check GEODE_MASTER_KEY against `data_dir`'s recorded check value, or
/// record it when there is none.
pub fn verifyOrRecord(allocator: std.mem.Allocator, data_dir: []const u8, caller: Caller) !void {
    const value: []const u8 = if (std.c.getenv("GEODE_MASTER_KEY")) |raw| std.mem.span(raw) else "";
    if (value.len == 0) return;
    var key = try km.parseMasterKey(value, try km.masterKeyFormatFromEnv());
    defer std.crypto.secureZero(u8, &key);

    const path = try std.fs.path.join(allocator, &.{ data_dir, km.master_key_check_file_name });
    defer allocator.free(path);

    const recorded = tde.readDecryptedFileNoFollow(allocator, path) catch |err| switch (err) {
        error.FileNotFound => {
            const line = try km.encodeMasterKeyCheck(key);
            tde.writeEncryptedFilePrivate(allocator, path, &line) catch |werr| {
                std.debug.print("[{s}] cannot record the GEODE_MASTER_KEY check value in {s} ({s}); {s}: a later use of another key could not be detected ({s}).\n", .{ caller.tag(), path, @errorName(werr), caller.refusal(), docs });
                log.err("cannot record the master key check value; refusing", &.{ Attr.string("path", path), Attr.string("error", @errorName(werr)) });
                return error.MasterKeyCheckUnavailable;
            };
            log.info("recorded the GEODE_MASTER_KEY check value", &.{Attr.string("path", path)});
            return;
        },
        else => {
            std.debug.print("[{s}] the GEODE_MASTER_KEY check file {s} cannot be read ({s}); {s}: the key cannot be checked against the one the encrypted fields were written with. " ++
                "Restore the file (or the GEODE_TDE_KEY it was written with) ({s}).\n", .{ caller.tag(), path, @errorName(err), caller.refusal(), docs });
            log.err("master key check file unreadable; refusing", &.{ Attr.string("path", path), Attr.string("error", @errorName(err)) });
            return error.MasterKeyCheckUnavailable;
        },
    };
    defer allocator.free(recorded);

    const matches = km.masterKeyCheckMatches(recorded, key) catch |err| {
        std.debug.print("[{s}] the GEODE_MASTER_KEY check file {s} is not a key check file ({s}); {s}. Restore it from a backup ({s}).\n", .{ caller.tag(), path, @errorName(err), caller.refusal(), docs });
        log.err("master key check file corrupt; refusing", &.{Attr.string("path", path)});
        return error.MasterKeyCheckUnavailable;
    };
    if (!matches) {
        std.debug.print(
            "[{s}] GEODE_MASTER_KEY is not the key this data directory's encrypted fields were written with: its check value does not match {s}; " ++
                "{s}: fields encrypted under the recorded key would be unreadable and new ones written under another key. Nothing was written. " ++
                "Set the original GEODE_MASTER_KEY, with the GEODE_MASTER_KEY_FORMAT it was read in. If no field was ever encrypted, remove {s} to record the new key ({s}).\n",
            .{ caller.tag(), path, caller.refusal(), km.master_key_check_file_name, docs },
        );
        log.err("GEODE_MASTER_KEY does not match the recorded key check value: refusing", &.{Attr.string("path", path)});
        return error.MasterKeyMismatch;
    }
}

/// The data directory the FLE catalog (and so the check file) lives in: the
/// store's override, else GEODE_DATA_DIR. Null when there is neither: the
/// catalog is in memory, no encrypted field outlives the process, and there
/// is nothing to check. The caller frees it.
pub fn fleDataDir(allocator: std.mem.Allocator) !?[]u8 {
    const catalog_path = (try fle_catalog.catalogFilePath(allocator)) orelse return null;
    defer allocator.free(catalog_path);
    return try allocator.dupe(u8, std.fs.path.dirname(catalog_path) orelse ".");
}
