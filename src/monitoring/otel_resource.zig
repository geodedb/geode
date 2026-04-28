const std = @import("std");
const otel = @import("otel");

pub const NodeRole = enum {
    standalone,
    leader,
    follower,
    coordinator,

    pub fn name(self: NodeRole) []const u8 {
        return switch (self) {
            .standalone => "standalone",
            .leader => "leader",
            .follower => "follower",
            .coordinator => "coordinator",
        };
    }
};

pub const Options = struct {
    service_version: []const u8,
    instance_id: []const u8,
    node_role: NodeRole,
    cluster_name: ?[]const u8 = null,
    node_id: ?[]const u8 = null,
    deployment_environment: ?[]const u8 = null,
};

/// Attribute keys used by `buildResource` that are not present in
/// `otel.semconv`. Centralised so call sites that read these attributes
/// (tests, exporters, dashboards generated from this list) reference one
/// canonical spelling rather than re-typing the dotted string. Geode-
/// specific keys are namespaced under `geode.*`; the `db.system.name` key
/// is a standard OTel DB semconv key whose constant the upstream OTel
/// package does not yet expose.
pub const keys = struct {
    pub const db_system_name = "db.system.name";
    pub const node_role = "geode.node.role";
    pub const cluster_name = "geode.cluster.name";
    pub const node_id = "geode.node.id";
    pub const deployment_env = "deployment.environment.name";
};

/// Build the OTel `Resource` populated with Geode's required + recommended
/// attributes per docs/otel-updates.md §1.
///
/// Required: service.name, service.instance.id, db.system.name.
/// Recommended: service.namespace, service.version, geode.node.role.
/// Cluster-only: geode.cluster.name, geode.node.id.
///
/// Caller owns the returned `Resource` and MUST call `.deinit()`.
pub fn buildResource(allocator: std.mem.Allocator, opts: Options) !otel.sdk.resource.Resource {
    var resource = try otel.sdk.resource.defaultResource(allocator);
    errdefer resource.deinit();

    try resource.attributes.putString(otel.semconv.service_name, "geode");
    try resource.attributes.putString(otel.semconv.service_namespace, "codepros");
    try resource.attributes.putString(otel.semconv.service_version, opts.service_version);
    try resource.attributes.putString(otel.semconv.service_instance_id, opts.instance_id);
    // db.system.name MUST be "codepros.geode" — the well-known value
    // "geode" is reserved for Apache Geode in OTel's DB semconv.
    try resource.attributes.putString(keys.db_system_name, "codepros.geode");
    try resource.attributes.putString(keys.node_role, opts.node_role.name());

    if (opts.cluster_name) |c| try resource.attributes.putString(keys.cluster_name, c);
    if (opts.node_id) |n| try resource.attributes.putString(keys.node_id, n);
    if (opts.deployment_environment) |env| {
        try resource.attributes.putString(keys.deployment_env, env);
    }
    return resource;
}
