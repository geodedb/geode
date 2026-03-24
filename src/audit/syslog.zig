// Thin compatibility wrapper — delegates to external audit library.
// CANARY: REQ=REQ-AUDIT-TLS-POOL-001; FEATURE="SyslogTLSConnectionPool"; ASPECT=PERFORMANCE; STATUS=TESTED; TEST=geodetestlab/specs/geode_audit_logging_enterprise.yml; OWNER=audit; UPDATED=2026-01-12
// CANARY: REQ=REQ-AUDIT-TLS-001; FEATURE="SyslogTLSTransport"; ASPECT=SECURITY; STATUS=TESTED; TEST=geodetestlab/specs/geode_audit_logging_enterprise.yml; OWNER=audit; UPDATED=2026-01-12
// CANARY: REQ=REQ-AUDIT-TLS-POOL-002; FEATURE="SyslogTLSConnectionPooling"; ASPECT=PERFORMANCE; STATUS=TESTED; TEST=geodetestlab/specs/geode_audit_logging_enterprise.yml; OWNER=audit; UPDATED=2026-01-12
// CANARY: REQ=REQ-AUDIT-TLS-PIN-002; FEATURE="SyslogTLSCertPinning"; ASPECT=SECURITY; STATUS=TESTED; TEST=geodetestlab/specs/geode_audit_logging_enterprise.yml; OWNER=audit; UPDATED=2026-01-12
// CANARY: REQ=REQ-AUDIT-TLS-PIN-003; FEATURE="SyslogTLSCertPinVerify"; ASPECT=SECURITY; STATUS=TESTED; TEST=geodetestlab/specs/geode_audit_logging_enterprise.yml; OWNER=audit; UPDATED=2026-01-12
// CANARY: REQ=REQ-AUDIT-TLS-TEST-001; FEATURE="SyslogTLSTests"; ASPECT=TESTING; STATUS=TESTED; TEST=geodetestlab/specs/geode_audit_logging_enterprise.yml; OWNER=audit; UPDATED=2026-01-12
// CANARY: REQ=REQ-QUALITY-GAP-413-009; FEATURE="OrphanedTestRemediation"; ASPECT=Zig015API; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Audit; STATUS=EXEMPT; OWNER=audit; UPDATED=2026-01-24
// CANARY: REQ=REQ-LIB-MIGRATION-DNS-001; FEATURE="External Library Migration"; ASPECT=DNSResolution; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-24

const audit_lib = @import("audit_lib");
const lib_syslog = audit_lib.syslog;

// Re-export all public types from the external library
pub const SyslogSender = lib_syslog.SyslogSender;
pub const MockSyslogSender = lib_syslog.MockSyslogSender;

// Re-export public functions
pub const formatRfc5424 = lib_syslog.formatRfc5424;
