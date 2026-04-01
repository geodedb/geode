const std = @import("std");
const config = @import("audit_lib").config;

pub const Config = config.Config;
pub const ServiceConfig = config.ServiceConfig;
pub const CefIdentityConfig = config.CefIdentityConfig;
pub const IdentityConfig = config.IdentityConfig;
pub const FileSinkConfig = config.FileSinkConfig;
pub const SyslogRfc5424Config = config.SyslogRfc5424Config;
pub const SyslogSinkConfig = config.SyslogSinkConfig;
pub const SinksConfig = config.SinksConfig;
pub const FiltersConfig = config.FiltersConfig;

pub fn loadTestConfig(allocator: std.mem.Allocator) !Config {
    const allow_fields = try allocator.alloc([]const u8, 10);
    allow_fields[0] = try allocator.dupe(u8, "actor_id");
    allow_fields[1] = try allocator.dupe(u8, "subject_id");
    allow_fields[2] = try allocator.dupe(u8, "request_id");
    allow_fields[3] = try allocator.dupe(u8, "session_id");
    allow_fields[4] = try allocator.dupe(u8, "source_ip");
    allow_fields[5] = try allocator.dupe(u8, "trace_id");
    allow_fields[6] = try allocator.dupe(u8, "span_id");
    allow_fields[7] = try allocator.dupe(u8, "category");
    allow_fields[8] = try allocator.dupe(u8, "action");
    allow_fields[9] = try allocator.dupe(u8, "outcome");

    const deny_patterns = try allocator.alloc([]const u8, 2);
    deny_patterns[0] = try allocator.dupe(u8, "password");
    deny_patterns[1] = try allocator.dupe(u8, "secret");

    return Config{
        .version = 1,
        .service = ServiceConfig{
            .name = try allocator.dupe(u8, "authsvc"),
            .host = try allocator.dupe(u8, "app-host"),
            .pid = 1234,
        },
        .identity = IdentityConfig{
            .cef = CefIdentityConfig{
                .vendor = try allocator.dupe(u8, "DEVNW"),
                .product = try allocator.dupe(u8, "GEODE"),
                .version = try allocator.dupe(u8, @import("build_options").version),
            },
        },
        .sinks = SinksConfig{
            .file = FileSinkConfig{
                .enabled = true,
                .path = try allocator.dupe(u8, "zig-out/tmp/audit.log"),
                .max_bytes = 1048576,
                .backup_count = 5,
            },
            .syslog = SyslogSinkConfig{
                .enabled = true,
                .protocol = .udp,
                .host = try allocator.dupe(u8, "{{SYSLOG_HOST}}"),
                .port = 514,
                .rfc5424 = SyslogRfc5424Config{
                    .facility = .local4,
                },
            },
        },
        .filters = FiltersConfig{
            .default_deny = true,
            .allow_fields = allow_fields,
            .deny_key_patterns = deny_patterns,
            .pii_mode = .mask,
            .pci_mode = true,
        },
        .allocator = allocator,
    };
}
