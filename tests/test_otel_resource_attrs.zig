const std = @import("std");
const otel = @import("otel");
const otel_resource = @import("otel_resource");

test "resource carries service + db semconv attributes" {
    const gpa = std.testing.allocator;
    var resource = try otel_resource.buildResource(gpa, .{
        .service_version = "0.1.4",
        .instance_id = "test-instance-uuid",
        .node_role = .standalone,
    });
    defer resource.deinit();

    try std.testing.expectEqualStrings("geode", resource.attributes.getString(otel.semconv.service_name).?);
    try std.testing.expectEqualStrings("0.1.4", resource.attributes.getString(otel.semconv.service_version).?);
    try std.testing.expectEqualStrings("test-instance-uuid", resource.attributes.getString(otel.semconv.service_instance_id).?);
    try std.testing.expectEqualStrings("codepros", resource.attributes.getString(otel.semconv.service_namespace).?);
    try std.testing.expectEqualStrings("codepros.geode", resource.attributes.getString("db.system.name").?);
    try std.testing.expectEqualStrings("standalone", resource.attributes.getString("geode.node.role").?);
}

test "cluster mode adds geode.cluster.name + geode.node.id" {
    const gpa = std.testing.allocator;
    var resource = try otel_resource.buildResource(gpa, .{
        .service_version = "0.1.4",
        .instance_id = "test-instance",
        .cluster_name = "production-cluster",
        .node_id = "node-1",
        .node_role = .leader,
    });
    defer resource.deinit();

    try std.testing.expectEqualStrings("production-cluster", resource.attributes.getString("geode.cluster.name").?);
    try std.testing.expectEqualStrings("node-1", resource.attributes.getString("geode.node.id").?);
    try std.testing.expectEqualStrings("leader", resource.attributes.getString("geode.node.role").?);
    try std.testing.expectEqualStrings("geode", resource.attributes.getString(otel.semconv.service_name).?);
}
