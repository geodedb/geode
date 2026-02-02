const std = @import("std");
const schema = @import("../proto/schema.zig");
const protobuf = @import("protobuf"); // Added protobuf import
// Import the gRPC server library exposed in build.zig
const GrpcServer = @import("grpc_server").GrpcServer;

const log = std.log.scoped(.grpc_server);

pub const GeodeGrpcServer = struct {
    allocator: std.mem.Allocator,
    server: GrpcServer,

    pub fn init(allocator: std.mem.Allocator, port: u16, cert_path: ?[]const u8, key_path: ?[]const u8) !GeodeGrpcServer {
        // TODO: TLS configuration is passed to GrpcServer?
        // vendor/grpc-zig example uses "secret-key" as 3rd arg?
        // Need to check GrpcServer.init signature again.
        // Assuming (allocator, port, ?something)
        _ = cert_path;
        _ = key_path;

        // For now using placeholder string for key if required
        const server = try GrpcServer.init(allocator, port, "secret-key");

        var self = GeodeGrpcServer{
            .allocator = allocator,
            .server = server,
        };

        try self.registerHandlers();
        return self;
    }

    pub fn deinit(self: *GeodeGrpcServer) void {
        self.server.deinit();
    }

    pub fn start(self: *GeodeGrpcServer) !void {
        log.info("Starting gRPC server on port {}", .{self.server.port});
        try self.server.start();
    }

    fn registerHandlers(self: *GeodeGrpcServer) !void {
        try self.server.handlers.append(self.allocator, .{
            .name = "Handshake",
            .handler_fn = handleHandshake,
        });
        try self.server.handlers.append(self.allocator, .{
            .name = "Execute",
            .handler_fn = handleExecute,
        });
        try self.server.handlers.append(self.allocator, .{
            .name = "Ping",
            .handler_fn = handlePing,
        });
        try self.server.handlers.append(self.allocator, .{
            .name = "Begin",
            .handler_fn = handleBegin,
        });
        try self.server.handlers.append(self.allocator, .{
            .name = "Commit",
            .handler_fn = handleCommit,
        });
        try self.server.handlers.append(self.allocator, .{
            .name = "Rollback",
            .handler_fn = handleRollback,
        });
    }

    // ------------------------------------------------------------------------
    // Handlers
    // ------------------------------------------------------------------------

    fn handlePing(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
        // Decode Request (Empty)
        // For PingRequest (empty struct), we don't strictly need to decode if we trust the handler mapping.
        _ = request_bytes;

        // Encode Response
        const response = schema.PingResponse{ .ok = true };

        var response_buffer = std.ArrayList(u8).init(allocator);
        // Using scope to ensure flush/release if needed, though ArrayList writer is simple.

        // Assume Arwalk/zig-protobuf:
        // var writer = protobuf.initWriter(response_buffer.writer());
        // OR
        // var pb = protobuf.PbEncoder.init(response_buffer.writer());
        // Let's guess initWriter.
        const pb_writer = protobuf.initWriter(response_buffer.writer());
        try response.encode(pb_writer);

        return response_buffer.toOwnedSlice();
    }

    fn handleHandshake(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
        _ = request_bytes;
        // Decode logic
        // var fbs = std.io.fixedBufferStream(request_bytes);
        // var reader = protobuf.initReader(fbs.reader(), allocator);
        // const req = try schema.HelloRequest.decode(allocator, reader); // Need allocator for strings
        // defer req.deinit(allocator); // Assuming manual cleanup if needed or arena?

        // Mock Auth Success
        var caps = std.ArrayList([]const u8).init(allocator);
        try caps.append("QUIC");
        try caps.append("TLS1.3");
        try caps.append("PROTOBUF");

        const resp = schema.HelloResponse{
            .success = true,
            .session_id = "test-session-123",
            .capabilities = caps,
        };

        var response_buffer = std.ArrayList(u8).init(allocator);
        const pb_writer = protobuf.initWriter(response_buffer.writer());
        try resp.encode(pb_writer);

        return response_buffer.toOwnedSlice();
    }

    fn handleExecute(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
        _ = request_bytes;
        // Decode
        // var fbs = std.io.fixedBufferStream(request_bytes);
        // var reader = protobuf.initReader(fbs.reader(), allocator);
        // const req = try schema.ExecuteRequest.decode(allocator, reader);

        // Return "Not Implemented" Error for now
        const err = schema.Error{
            .code = "501",
            .message = "Streaming execution not yet supported by gRPC-zig adapter",
            .type = "ERROR",
        };
        const resp = schema.ExecutionResponse{ .@"error" = err };

        var response_buffer = std.ArrayList(u8).init(allocator);
        const pb_writer = protobuf.initWriter(response_buffer.writer());
        try resp.encode(pb_writer);

        return response_buffer.toOwnedSlice();
    }

    fn handleBegin(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
        _ = request_bytes;
        // Mock Transaction Begin
        const resp = schema.BeginResponse{
            .session_id = "test-session-123",
            .tx_id = "9999", // Mock TX ID
        };
        var response_buffer = std.ArrayList(u8).init(allocator);
        const pb_writer = protobuf.initWriter(response_buffer.writer());
        try resp.encode(pb_writer);
        return response_buffer.toOwnedSlice();
    }

    fn handleCommit(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
        _ = request_bytes;
        // Mock Commit
        const resp = schema.CommitResponse{ .success = true };
        var response_buffer = std.ArrayList(u8).init(allocator);
        const pb_writer = protobuf.initWriter(response_buffer.writer());
        try resp.encode(pb_writer);
        return response_buffer.toOwnedSlice();
    }

    fn handleRollback(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
        _ = request_bytes;
        // Mock Rollback
        const resp = schema.RollbackResponse{ .success = true };
        var response_buffer = std.ArrayList(u8).init(allocator);
        const pb_writer = protobuf.initWriter(response_buffer.writer());
        try resp.encode(pb_writer);
        return response_buffer.toOwnedSlice();
    }
};
