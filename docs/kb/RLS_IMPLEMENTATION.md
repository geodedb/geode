# Row-Level Security (RLS) Implementation for Geode

## Overview

This document describes the comprehensive Row-Level Security (RLS) implementation for the Geode graph database, including Users, RBAC (Role-Based Access Control), ABAC (Attribute-Based Access Control), and extensive management capabilities.

## Components Implemented

### 1. User Management (`src/security/auth.zig`)

- **User Creation & Authentication**
  - Secure password hashing (configurable for Argon2id)
  - Email validation
  - Account activation/deactivation
  - Multi-factor authentication (MFA) support
  - Session management with token-based authentication

- **Password Policies**
  - Minimum/maximum length requirements
  - Character complexity requirements (uppercase, lowercase, digits, special)
  - Password history tracking
  - Password age policies

### 2. Role-Based Access Control (RBAC)

- **Roles**
  - System roles (cannot be deleted)
  - Custom roles with descriptions
  - Role hierarchy with inheritance
  - Priority-based role resolution

- **Permissions**
  - Resource-based permissions
  - Action types: create, read, update, delete, execute, grant, revoke, all
  - Conditional permissions with JSON-based conditions
  - Fine-grained resource targeting

- **Authorization**
  - User-role assignments
  - Role-permission grants
  - Hierarchical permission inheritance
  - Superuser bypass

### 3. Attribute-Based Access Control (ABAC)

- **Policy Components**
  - Subject attributes (user properties)
  - Resource attributes
  - Environment conditions (time, IP, location)
  - Effect (allow/deny) with deny precedence

- **Attribute Conditions**
  - Comparison operators: equals, not_equals, contains, greater_than, less_than, in, matches (regex)
  - Dynamic attribute evaluation
  - Context-aware decisions

- **Environment Conditions**
  - Time-based access (business hours, time ranges)
  - IP range restrictions
  - Location-based access
  - Device type restrictions
  - Request rate limiting

### 4. Row-Level Security Engine (`src/security/rls.zig`)

- **Policy Management**
  - Per-table/graph policies
  - Operation-specific policies (SELECT, INSERT, UPDATE, DELETE)
  - Permissive vs Restrictive policies
  - Using clauses for row filtering
  - Check clauses for data validation

- **Advanced Features**
  - Temporal constraints with recurrence rules
  - Data classification levels (public, internal, confidential, restricted, top_secret)
  - Audit levels (none, errors_only, denials, all_access, detailed)
  - Policy caching for performance

- **Query Rewriting**
  - Automatic security predicate injection
  - Context-aware query modification
  - Performance-optimized predicate evaluation

- **Comparisons in policy expressions (SONNY-2709)**

  An expression policy (`row.<field>`, `principal.attribute.<key>`,
  `current_user`, literals, `=`, `<>`, `<`, `<=`, `>`, `>=`, `AND`, `OR`,
  `NOT`) is compiled to bytecode and evaluated per row. Its comparisons
  follow these rules:

  | Comparison | Result |
  |---|---|
  | `<`, `<=`, `>`, `>=` on two numbers (integer or float, mixed) | ordered as numbers |
  | the same on two strings | ordered by bytes |
  | the same on two timestamps | ordered |
  | the same on anything else: a missing field or `NULL`, NaN, a boolean, a string against a number | UNKNOWN |
  | `principal.attribute.<key>` against a number | the attribute is parsed strictly as that number's type, then compared; if it does not parse, UNKNOWN |
  | `=`, `<>` | true or false; a missing field equals only `NULL` |

  UNKNOWN never admits a row. `NOT`, `AND` and `OR` follow SQL's
  three-valued logic: `NOT` UNKNOWN is UNKNOWN, `false AND` UNKNOWN is
  false, `true OR` UNKNOWN is true, and every other combination with
  UNKNOWN is UNKNOWN. A policy whose result is UNKNOWN denies the row. So
  `row.level <= 3` and `NOT (row.level > 3)` both deny a row with no
  `level`, or with a `level` that is not a number.

  A principal attribute is stored as a string. Compared with an integer
  field it must be an optional `-` followed by ASCII digits, within the
  64-bit range (`"3"`, `"-1"`). Compared with a float field it may also have
  a `.` and at least one fraction digit (`"2.5"`). Anything else, such as
  `" 3"`, `"+3"`, `"3.0"` (against an integer), `"1e3"`, `"0x3"` or `"inf"`,
  is not a number, and the comparison is UNKNOWN. A user without the
  attribute gets UNKNOWN too. Compared with a string field, the attribute is
  compared as a string. Only a principal attribute is converted: a row's
  string field is never read as a number.

### 5. User Management CLI (`src/tools/user_auth.zig`)

- **User Commands**
  - `user create <username> <email> <password>` - Create new user
  - `user delete <username>` - Delete user
  - `user list` - List all users
  - `user show <username>` - Show user details
  - `user enable/disable <username>` - Enable/disable user
  - `user password <username> <new_password>` - Change password

- **Role Commands**
  - `role create <name> <description>` - Create role
  - `role delete <name>` - Delete role
  - `role list` - List all roles
  - `role show <name>` - Show role details

- **Policy Commands**
  - `policy create <name> <table> <operation>` - Create RLS policy
  - `policy delete <name>` - Delete policy
  - `policy list [table]` - List policies
  - `policy enable/disable <name>` - Enable/disable policy

- **Grant/Revoke Commands**
  - `grant role <role> to <user>` - Grant role to user
  - `grant permission <permission> to <role>` - Grant permission to role
  - `revoke role <role> from <user>` - Revoke role from user
  - `revoke permission <permission> from <role>` - Revoke permission from role

### 6. Audit Logging

- **Event Types**
  - User lifecycle events (created, updated, deleted)
  - Authentication events (login success/failure, logout)
  - Authorization events (role/permission changes)
  - Policy events (creation, modification, deletion)
  - Access events (granted, denied)

- **Audit Entry Structure**
  - Timestamp
  - Event type
  - User ID
  - Detailed description
  - Context information

## Security Features

### Multi-Tenant Isolation

- Tenant-specific policies
- Complete data isolation between tenants
- Shared-nothing architecture support
- Per-tenant role hierarchies

### Performance Optimizations

- **Policy Caching**
  - LRU cache with configurable size
  - TTL-based expiration
  - Automatic invalidation on policy changes

- **Expression Compilation**
  - Bytecode compilation for frequently used expressions
  - JIT-style optimization for hot paths
  - Constant folding and dead code elimination

### Integration Points

- **Storage Backend**
  - Persistent user/role/permission storage
  - Policy persistence
  - Audit log storage

- **Query Engine**
  - Transparent query rewriting
  - Security predicate pushdown
  - Index-aware filtering

- **Transaction Manager**
  - Row-level locking integration
  - MVCC visibility checks
  - Conflict detection with security context

## Usage Examples

### Creating a User with Roles

```bash
# Create a user
geode-auth user create alice alice@example.com SecurePass123!

# Create a role
geode-auth role create analyst "Data analyst with read access"

# Grant role to user
geode-auth grant role analyst to alice
```

### Setting Up RLS Policies

```zig
// Create a policy for user data isolation
const policy = RLSEngine.Policy{
    .name = "user_own_data",
    .description = "Users can only see their own data",
    .table = "user_profiles",
    .operation = .select,
    .using_expr = Expression{
        .raw = "owner_id = current_user()",
    },
    .roles = &[_]RoleId{user_role_id},
    .enabled = true,
};

try rls_engine.createPolicy(policy);
```

### ABAC Policy Example

```zig
const policy = ABACPolicy{
    .name = "time_restricted_access",
    .effect = .allow,
    .subjects = &[_]AttributeCondition{
        .{ .attribute = "department", .operator = .equals, .value = .{ .string = "finance" } },
    },
    .resources = &[_]AttributeCondition{
        .{ .attribute = "classification", .operator = .equals, .value = .{ .string = "financial" } },
    },
    .conditions = &[_]EnvironmentCondition{
        .{ .type = .time_range, .parameters = .{ .object = ... } },
    },
};
```

## Testing

Comprehensive test coverage is provided in `tests/e2e_rls_security.zig`:

- User creation and authentication
- RBAC role and permission management
- ABAC policy evaluation
- RLS policy application
- Temporal constraints
- Password policy enforcement
- Session management
- Audit logging
- Multi-tenant isolation
- Performance testing with policy cache

## Build and Run

```bash
# Build the project
zig build

# Run tests
zig build test

# Run the user management CLI
./zig-out/bin/geode-auth --help

# Test RLS implementation
zig build-exe src/test_rls.zig && ./test_rls
```

## Future Enhancements

1. **OAuth2/OIDC Integration**
   - External identity provider support
   - JWT token validation
   - SAML support

2. **Advanced RLS Features**
   - Row-level encryption
   - Dynamic data masking
   - Column-level security

3. **Performance Improvements**
   - Parallel policy evaluation
   - Distributed policy cache
   - Query plan caching with security context

4. **Compliance Features**
   - GDPR compliance tools
   - Data retention policies
   - Right to be forgotten implementation

## Conclusion

The Row-Level Security implementation for Geode provides a comprehensive, performant, and flexible security framework that supports:

- Fine-grained access control at the row level
- Multiple authorization models (RBAC and ABAC)
- Multi-tenant data isolation
- Comprehensive audit logging
- Performance optimization through caching
- Easy management through CLI tools

This implementation ensures that users only see data they are authorized to access, maintaining data privacy and security in multi-user and multi-tenant environments.
