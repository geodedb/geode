# Authentication System Implementation Guide

**Status**: NOT IMPLEMENTED - Documentation for Future Development
**Date**: October 14, 2025
**Complexity**: Estimated 2-3 weeks of development effort

## Overview

The authentication system needs to be implemented to support the following test scenarios from `geode_auth_security.yml`:

1. `unauthenticated-query-failure` - Queries without credentials should fail
2. `wrong-password-failure` - Queries with incorrect passwords should fail
3. `test-read-only-access` - Read-only users should be able to query but not mutate

## Current State

### What Exists
- `--user` and `--password` CLI flags are parsed in `src/cli/main.zig` (lines 1904-1917)
- Basic authentication context structure in `src/test_harness.zig` (QueryOptions struct)
- Special handling for "unauthorized" user that exits with code 3 (lines 2009-2013)

### What's Missing
- **User credential storage and validation**
- **Role-based access control (RBAC) system**
- **Password hashing and verification**
- **Session management**
- **Permission checking in query execution**

## Implementation Requirements

### 1. User Management System

**Location**: Create `src/security/user_management.zig`

```zig
pub const User = struct {
    username: []const u8,
    password_hash: []const u8,  // bcrypt or argon2
    roles: []Role,
    created_at: i64,
    last_login: ?i64,
};

pub const Role = enum {
    Admin,
    ReadOnly,
    ReadWrite,
};

pub const UserStore = struct {
    users: std.StringHashMap(User),

    pub fn authenticate(self: *UserStore, username: []const u8, password: []const u8) !bool;
    pub fn hasPermission(self: *UserStore, username: []const u8, operation: Operation) bool;
};
```

### 2. Password Hashing

**Dependencies**: Add bcrypt or argon2 library to `build.zig`

**Implementation**:
- Use bcrypt with cost factor 12 for password hashing
- Store hashed passwords in user database
- Verify passwords on authentication

### 3. Permission Checking

**Location**: Modify `src/execution.zig`

Add permission checks before executing:
- CREATE, DELETE, MERGE operations (require ReadWrite or Admin)
- MATCH, CALL operations (require ReadOnly, ReadWrite, or Admin)
- Schema operations (require Admin)

```zig
pub const Operation = enum {
    Read,
    Write,
    Admin,
};

fn checkPermission(context: ExecutionContext, operation: Operation) !void {
    if (context.user == null) return error.Unauthenticated;

    const user_roles = getUserRoles(context.user.?);
    if (!hasPermissionForOperation(user_roles, operation)) {
        return error.Unauthorized;
    }
}
```

### 4. CLI Integration

**Location**: `src/cli/main.zig`

Modify `cmdQuery` and `cmdServe` to:
1. Parse `--enable-auth` flag
2. Read credentials from:
   - Command-line flags (`--user`, `--password`)
   - Environment variables (`GEODE_USER`, `GEODE_PASSWORD`)
   - Config file (`~/.geode/credentials`)
3. Pass authentication context to query execution

### 5. Test Updates

**Location**: `src/test_harness.zig`

Add authentication handling:
```zig
pub const QueryOptions = struct {
    token: ?[]const u8 = null,
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,  // Add this
    strict_offset_validation: bool = false,
    require_auth: bool = false,    // Add this
};
```

## Test Specifications

### Test 1: unauthenticated-query-failure

**Query**: `RETURN 1`
**Expected**: exit_code 3, stderr contains "authentication required"

**Implementation**:
- Check if `--enable-auth` is set on server
- If auth is enabled and no credentials provided, return error
- Exit with code 3 for authentication failures

### Test 2: wrong-password-failure

**Query**: `RETURN 1` with `--user testuser --password wrongpass`
**Expected**: exit_code 3, stderr contains "authentication failed"

**Implementation**:
- Validate provided credentials against user store
- If password doesn't match, return authentication error
- Exit with code 3

### Test 3: test-read-only-access

**Setup**: Create testuser with ReadOnly role
**Query**: `CREATE (n) RETURN n` with valid readonly credentials
**Expected**: exit_code 1, stderr contains "permission denied"

**Implementation**:
- Check user role before executing write operations
- If user has ReadOnly role, reject CREATE/DELETE/MERGE
- Return permission error with helpful message

## Error Codes

| Exit Code | Meaning | When Used |
|-----------|---------|-----------|
| 0 | Success | Query executed successfully |
| 1 | Query Error | Syntax error, permission denied, constraint violation |
| 3 | Authentication Error | No credentials, wrong password, invalid token |

## Database Schema

For persistent user storage, create table:

```sql
CREATE TABLE users (
    username VARCHAR(255) PRIMARY KEY,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(50) NOT NULL,
    created_at BIGINT NOT NULL,
    last_login BIGINT,
    active BOOLEAN DEFAULT true
);
```

## Security Considerations

1. **Never log passwords** - Only log usernames and authentication status
2. **Use constant-time comparison** for password verification to prevent timing attacks
3. **Rate limiting** - Implement exponential backoff for failed login attempts
4. **Audit logging** - Log all authentication attempts (success and failure)
5. **Session timeout** - Implement configurable session timeout for long-running connections

## Configuration File Format

`~/.geode/config.toml`:
```toml
[auth]
enabled = true
require_auth = true
session_timeout_seconds = 3600

[users]
# Users can be defined here for development
# In production, use database-backed user store
```

## Migration Path

1. **Phase 1** (Week 1): Implement user management and password hashing
2. **Phase 2** (Week 1-2): Add permission checking to execution engine
3. **Phase 3** (Week 2): Integrate with CLI and add `--enable-auth` flag
4. **Phase 4** (Week 2-3): Add persistent storage and session management
5. **Phase 5** (Week 3): Testing and documentation

## Testing Strategy

1. Unit tests for password hashing and verification
2. Integration tests for authentication flow
3. Permission tests for each operation type
4. Load tests for authentication performance
5. Security audit for vulnerability assessment

## Performance Considerations

- Cache authenticated sessions to avoid repeated hash verification
- Use connection pooling with authentication context
- Consider JWT tokens for stateless authentication
- Benchmark authentication overhead (<1ms per query)

## Future Enhancements

- Multi-factor authentication (MFA)
- LDAP/Active Directory integration
- OAuth2 support for enterprise SSO
- Fine-grained column-level permissions
- Attribute-based access control (ABAC)

---

**Note**: This system is not currently implemented. The above specifications are based on the failing test requirements and industry best practices for database authentication systems.
