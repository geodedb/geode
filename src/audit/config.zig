// Thin compatibility wrapper — delegates to external audit library.
// CANARY: REQ=REQ-AUDIT-TLS-PIN-001; FEATURE="SyslogTLSCertPinning"; ASPECT=SECURITY; STATUS=TESTED; TEST=geodetestlab/specs/geode_audit_logging_enterprise.yml; OWNER=audit; UPDATED=2026-01-12

const audit_lib = @import("audit_lib");
const lib_config = audit_lib.config;

// Re-export all public types from the external library
pub const SyslogProtocol = lib_config.SyslogProtocol;
pub const SyslogFacility = lib_config.SyslogFacility;
pub const PiiMode = lib_config.PiiMode;
pub const ServiceConfig = lib_config.ServiceConfig;
pub const CefIdentityConfig = lib_config.CefIdentityConfig;
pub const IdentityConfig = lib_config.IdentityConfig;
pub const SyncMode = lib_config.SyncMode;
pub const FileSinkConfig = lib_config.FileSinkConfig;
pub const SyslogRfc5424Config = lib_config.SyslogRfc5424Config;
pub const SyslogTlsConfig = lib_config.SyslogTlsConfig;
pub const SyslogSinkConfig = lib_config.SyslogSinkConfig;
pub const SinksConfig = lib_config.SinksConfig;
pub const FiltersConfig = lib_config.FiltersConfig;
pub const Config = lib_config.Config;

// Re-export functions
pub const loadConfig = lib_config.loadConfig;

/// Geode-specific test config that uses build_options.version for the CEF product version
/// and sets product name to "GEODE" instead of the library default "AUDIT".
pub fn loadTestConfig(allocator: @import("std").mem.Allocator) !Config {
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
