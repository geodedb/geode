//! The gRPC methods geode serves (SONNY-6593).
//!
//! Exactly the RPCs `service GeodeService` in src/proto/geode.proto
//! declares, in its order: the clients ship that file and generate their
//! stubs from it, so a method served under any other name cannot be
//! called by a generated client, and a declared method that is not served
//! answers UNIMPLEMENTED. `GeodeGrpcServer` registers `paths` and nothing
//! else (grpc-zig answers any other `:path` with grpc-status 12).
//! tests/test_sonny6593_grpc_service_contract.zig compares this list with
//! the .proto and probes a running server.
//!
//! The server served Savepoint, RollbackTo, Backup, Restore and
//! UploadBackup without the .proto declaring them; they are declared now.
//! It also served CdcDiag and CdcCtrl, undeclared aliases of
//! GetCdcDiagnostics and ControlCdc that no client used; they are gone.

// CANARY: REQ=REQ-SONNY-6593-GRPC-SERVICE-CONTRACT; FEATURE="GrpcTransport"; ASPECT=ServedEqualsDeclared; STATUS=TESTED; TEST=tests/test_sonny6593_grpc_service_contract.zig; OWNER=transport; UPDATED=2026-11-15

/// The fully qualified service name (`package geode;` + the service).
pub const service = "geode.GeodeService";

/// The RPC names, as geode.proto declares them.
pub const names = [_][]const u8{
    "Handshake",
    "Execute",
    "Ping",
    "Begin",
    "Commit",
    "Rollback",
    "GetCdcDiagnostics",
    "ControlCdc",
    "Savepoint",
    "RollbackTo",
    "Backup",
    "Restore",
    "UploadBackup",
};

/// The `:path` of each RPC: `/geode.GeodeService/<name>`.
pub const paths = blk: {
    var out: [names.len][]const u8 = undefined;
    for (names, 0..) |name, i| out[i] = "/" ++ service ++ "/" ++ name;
    const final = out;
    break :blk final;
};
