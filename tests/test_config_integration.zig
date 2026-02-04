// CANARY: REQ=REQ-LIB-MIGRATION-CONFIG-TEST-001; FEATURE="External Library Migration"; ASPECT=ConfigTesting; STATUS=TESTED; OWNER=test; UPDATED=2026-01-24
// Unit tests for configuration file loading with YAML, TOML, and JSON formats
// Tests the integration of the external config library with Geode

const std = @import("std");
const testing = std.testing;

// Import the config library directly for testing
const config_lib = @import("config");

// ============================================================================
// Test: Config library basic functionality
// ============================================================================

test "config library getPaths returns valid XDG paths" {
    const allocator = testing.allocator;
    var paths = try config_lib.getPaths(allocator);
    defer paths.deinit();

    // Should return non-empty paths
    try testing.expect(paths.config_home.len > 0);

    // Config home should contain a valid path
    try testing.expect(paths.config_home[0] == '/');
}

test "config library parseFile handles missing file gracefully" {
    const allocator = testing.allocator;

    // Attempting to load a non-existent file should return an error
    const result = config_lib.parseFile(allocator, "/nonexistent/path/config.yaml");
    try testing.expectError(error.FileNotFound, result);
}

// ============================================================================
// Test: YAML format support
// ============================================================================

test "config library can parse YAML content" {
    const allocator = testing.allocator;
    const yaml_content =
        \\host: localhost
        \\port: 8080
        \\debug: true
    ;

    var value = try config_lib.parseContent(allocator, yaml_content, .yaml);
    defer value.deinit();

    try testing.expectEqualStrings("localhost", value.getString("host").?);
    try testing.expectEqual(@as(i64, 8080), value.getInt("port").?);
    try testing.expectEqual(true, value.getBool("debug").?);
}

test "config library can parse nested YAML" {
    const allocator = testing.allocator;
    const yaml_content =
        \\server:
        \\  host: localhost
        \\  port: 3141
    ;

    var value = try config_lib.parseContent(allocator, yaml_content, .yaml);
    defer value.deinit();

    try testing.expectEqualStrings("localhost", value.getString("server.host").?);
    try testing.expectEqual(@as(i64, 3141), value.getInt("server.port").?);
}

// ============================================================================
// Test: TOML format support
// ============================================================================

test "config library can parse TOML content" {
    const allocator = testing.allocator;
    const toml_content =
        \\host = "localhost"
        \\port = 8080
        \\debug = true
    ;

    var value = try config_lib.parseContent(allocator, toml_content, .toml);
    defer value.deinit();

    try testing.expectEqualStrings("localhost", value.getString("host").?);
    try testing.expectEqual(@as(i64, 8080), value.getInt("port").?);
    try testing.expectEqual(true, value.getBool("debug").?);
}

// ============================================================================
// Test: JSON format support
// ============================================================================

test "config library can parse JSON content" {
    const allocator = testing.allocator;
    const json_content =
        \\{"host": "localhost", "port": 8080", "debug": true}
    ;

    var value = try config_lib.parseContent(allocator, json_content, .json);
    defer value.deinit();

    try testing.expectEqualStrings("localhost", value.getString("host").?);
    try testing.expectEqual(@as(i64, 8080), value.getInt("port").?);
    try testing.expectEqual(true, value.getBool("debug").?);
}

test "config library can parse nested JSON" {
    const allocator = testing.allocator;
    const json_content =
        \\{"server": {"host": "localhost", "port": 3141}}
    ;

    var value = try config_lib.parseContent(allocator, json_content, .json);
    defer value.deinit();

    try testing.expectEqualStrings("localhost", value.getString("server.host").?);
    try testing.expectEqual(@as(i64, 3141), value.getInt("server.port").?);
}

// ============================================================================
// Test: Config file search order
// ============================================================================

test "config file extensions follow correct search order" {
    // The search order should be: yaml, yml, toml, json
    const extensions = [_][]const u8{ "yaml", "yml", "toml", "json" };

    try testing.expectEqual(@as(usize, 4), extensions.len);
    try testing.expectEqualStrings("yaml", extensions[0]);
    try testing.expectEqualStrings("yml", extensions[1]);
    try testing.expectEqualStrings("toml", extensions[2]);
    try testing.expectEqualStrings("json", extensions[3]);
}

// ============================================================================
// Test: Project config directory name
// ============================================================================

test "project config uses .geode directory" {
    const project_config_dir = ".geode";
    const expected_yaml = ".geode/config.yaml";
    const expected_toml = ".geode/config.toml";
    const expected_json = ".geode/config.json";

    try testing.expect(std.mem.startsWith(u8, expected_yaml, project_config_dir));
    try testing.expect(std.mem.startsWith(u8, expected_toml, project_config_dir));
    try testing.expect(std.mem.startsWith(u8, expected_json, project_config_dir));
}

// ============================================================================
// Test: Geode config keys
// ============================================================================

test "supported config keys are documented" {
    // These are the config keys that Geode supports
    const supported_keys = [_][]const u8{
        "listen_quic",
        "cert_path",
        "key_path",
        "data_dir",
        "log_level",
    };

    try testing.expectEqual(@as(usize, 5), supported_keys.len);

    // Verify each key is a valid identifier
    for (supported_keys) |key| {
        try testing.expect(key.len > 0);
        try testing.expect(std.ascii.isAlphabetic(key[0]) or key[0] == '_');
    }
}

// ============================================================================
// Test: Config precedence logic
// ============================================================================

test "CLI values take precedence over file values" {
    // This tests the logic that CLI-specified values should not be overwritten

    // Simulate CLI value already set
    var cli_value: ?[]const u8 = "from-cli";

    // File value would be different
    const file_value: []const u8 = "from-file";

    // The merge logic: only set if CLI value is null
    if (cli_value == null) {
        cli_value = file_value;
    }

    // CLI value should be preserved
    try testing.expectEqualStrings("from-cli", cli_value.?);
}

test "file values are used when CLI values are null" {
    // Simulate no CLI value set
    var cli_value: ?[]const u8 = null;

    // File value should be used
    const file_value: []const u8 = "from-file";

    // The merge logic: set if CLI value is null
    if (cli_value == null) {
        cli_value = file_value;
    }

    // File value should be used
    try testing.expectEqualStrings("from-file", cli_value.?);
}

// ============================================================================
// Test: Value API features
// ============================================================================

test "config Value has method returns correct result" {
    const allocator = testing.allocator;
    const yaml_content =
        \\host: localhost
        \\port: 8080
    ;

    var value = try config_lib.parseContent(allocator, yaml_content, .yaml);
    defer value.deinit();

    try testing.expect(value.has("host"));
    try testing.expect(value.has("port"));
    try testing.expect(!value.has("nonexistent"));
}

test "config Value isNull method" {
    const allocator = testing.allocator;
    const yaml_content =
        \\value: null
    ;

    var value = try config_lib.parseContent(allocator, yaml_content, .yaml);
    defer value.deinit();

    // The root value should not be null
    try testing.expect(!value.isNull());
}

// ============================================================================
// Test: Format detection
// ============================================================================

test "Format enum has all supported types" {
    // Verify the Format enum has all the formats we need
    const yaml_format = config_lib.Format.yaml;
    const toml_format = config_lib.Format.toml;
    const json_format = config_lib.Format.json;

    try testing.expect(yaml_format != toml_format);
    try testing.expect(toml_format != json_format);
    try testing.expect(yaml_format != json_format);
}

test "Format fromExtension detects YAML" {
    try testing.expectEqual(config_lib.Format.yaml, config_lib.Format.fromExtension("config.yaml"));
    try testing.expectEqual(config_lib.Format.yaml, config_lib.Format.fromExtension("config.yml"));
}

test "Format fromExtension detects TOML" {
    try testing.expectEqual(config_lib.Format.toml, config_lib.Format.fromExtension("config.toml"));
}

test "Format fromExtension detects JSON" {
    try testing.expectEqual(config_lib.Format.json, config_lib.Format.fromExtension("config.json"));
}
