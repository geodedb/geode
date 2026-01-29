# Geode User Authentication System

🔐 **Complete Configurable Authentication & Security Framework**

## Overview

Geode implements a comprehensive authentication system with post-quantum ready security features, configurable policies, and enterprise-grade password requirements. All users follow the same high security standards with extensive environment-based customization.

## 1. Default User Configuration

### Basic Setup

- **Default Username**: `geode` (configurable)
- **Default Password**: `geodesic` (configurable)  
- **Privileges**: Full superuser access
- **Auto-Creation**: Created automatically on first system initialization

### Environment Configuration

```bash
# Configure default admin username
export GEODE_ADMIN_USERNAME="database_admin"        # Default: "geode"

# Configure default admin password  
export GEODE_DEFAULT_PASSWORD="My Super Secure Admin Passphrase 2024"
```

### Supported Admin Username Examples

```bash
# Production environments
export GEODE_ADMIN_USERNAME="prod_admin"
export GEODE_ADMIN_USERNAME="sysadmin"
export GEODE_ADMIN_USERNAME="database_operator"

# Development environments
export GEODE_ADMIN_USERNAME="dev_admin"
export GEODE_ADMIN_USERNAME="test_user"
```

## 2. Unified Password Policy (All Users)

### Security Requirements

**Every user in the system must meet these standards:**

- ✅ **Minimum Length**: 20+ characters (configurable, absolute minimum: 20)
- ✅ **Passphrase Format**: 3+ words required (configurable, absolute minimum: 2)
- ✅ **Case Requirements**: Must contain both uppercase and lowercase letters
- ✅ **Character Support**: Spaces, numbers, and symbols allowed
- ✅ **No Exceptions**: Admin and regular users follow identical standards

### Policy Configuration

```bash
# Password length (minimum 20 enforced)
export GEODE_PASSWORD_MIN_LENGTH=25        # Default: 20

# Word count (minimum 2 enforced)  
export GEODE_PASSWORD_MIN_WORDS=4          # Default: 3
```

### Configuration Examples

```bash
# High security environment
export GEODE_PASSWORD_MIN_LENGTH=35
export GEODE_PASSWORD_MIN_WORDS=6

# Moderate security (cannot go below minimums)
export GEODE_PASSWORD_MIN_LENGTH=22
export GEODE_PASSWORD_MIN_WORDS=3

# Invalid (will use minimums instead)
export GEODE_PASSWORD_MIN_LENGTH=15        # Becomes 20
export GEODE_PASSWORD_MIN_WORDS=1          # Becomes 2
```

## 3. Forced Password Reset System

### Reset Triggers

Password reset is **automatically required** when:

- ✅ Using default password `"geodesic"`
- ✅ Environment password < configured minimum length
- ✅ Environment password lacks uppercase AND lowercase letters  
- ✅ Environment password doesn't meet passphrase word requirements
- ✅ Administrator manually forces reset via API

### Reset Flow Process

1. **Authentication Succeeds**: User identity verified
2. **Policy Check**: Password evaluated against current policy
3. **Reset Prompt**: Clear explanation of requirements shown
4. **New Password Entry**: Secure input with confirmation
5. **Real-time Validation**: Immediate feedback on policy compliance
6. **Session Termination**: Forced logout requiring re-authentication

### Reset Experience

```
Authentication successful, but a password reset is required.
Your current password does not meet the security policy:
  - Minimum 25 characters
  - Must be a passphrase (4 or more words)
  - Must contain uppercase and lowercase letters
  - Spaces, numbers, and symbols are allowed

You must set a new password before accessing the database.

New password: [Type secure passphrase here]
Confirm password: [Retype to confirm]
```

## 4. CLI Authentication Commands

### Login Command

```bash
# Basic login (uses default server)
geode auth login --user <username>

# Specify custom server
geode auth login --user <username> --server <host:port>

# With password file
geode auth login --user <username> --password-file /path/to/password

# With environment-configured admin
geode auth login --user $GEODE_ADMIN_USERNAME
```

### Login Options

| Option | Description | Example |
|--------|-------------|---------|
| `--user`, `-U` | Username to authenticate | `--user admin` |
| `--server` | Server address | `--server prod.geode.com:3141` |
| `--password` | Password (not recommended) | `--password "secret"` |
| `--password-file` | Read password from file | `--password-file /dev/stdin` |

### Logout Command

```bash
# Clear stored credentials
geode auth logout
```

### Authentication Flow Examples

**Standard Login:**

```bash
$ geode auth login --user geode
Username: geode
Password: [hidden input]
Successfully authenticated as 'geode' on server '127.0.0.1:3141'
Session token saved to ~/.geode/credentials.json
```

**Password Reset Required:**

```bash
$ geode auth login --user prod_admin  
Username: prod_admin
Password: [weak_password]
Authentication successful, but a password reset is required.
[Policy explanation and reset flow]
```

## 5. Complete Environment Configuration

### All Available Variables

```bash
# === User Configuration ===
export GEODE_ADMIN_USERNAME="database_admin"        # Default: "geode"
export GEODE_DEFAULT_PASSWORD="Secure Admin Passphrase Goes Here 2024"

# === Password Policy ===
export GEODE_PASSWORD_MIN_LENGTH=25                 # Default: 20, Min: 20
export GEODE_PASSWORD_MIN_WORDS=4                   # Default: 3, Min: 2

# === Server Configuration ===
export GEODE_SERVER_HOST="prod.geode.com"          # Default: "127.0.0.1"
export GEODE_SERVER_PORT="3141"                    # Default: "3141"
```

## 6. Security Implementation

### Enhanced Password Validation

- **Pre-Hash Validation**: Passwords checked against policy before hashing
- **Post-Auth Validation**: Authenticated passwords re-checked against current policy
- **Policy Enforcement**: Non-bypassable requirement for policy compliance
- **Dynamic Updates**: Policy changes immediately affect all users

### Password Hashing

- **Current**: BLAKE2b-256 with salt (secure placeholder)
- **Future**: Argon2id with OWASP parameters (when Zig API stabilizes)
- **Security Level**: Post-quantum computational resistance
- **Validation**: All passwords validated before hashing

### Session Management

- **Duration**: 24-hour expiration
- **Storage**: `~/.geode/credentials.json` (user home directory)
- **Format**: Cryptographically secure random tokens
- **Cross-platform**: Windows and Unix support
- **Policy Enforcement**: Sessions invalidated for policy violations

### Audit Trail (CANARY Tracking)

- `REQ-AUTH-POLICY-001`: Password Reset Tracking
- `REQ-AUTH-POLICY-002`: Enhanced Password Policy  
- `REQ-AUTH-POLICY-003`: Passphrase Validation
- `REQ-AUTH-POLICY-004`: Unified Password Policy
- `REQ-AUTH-POLICY-005`: Password Policy Validation Before Hashing
- `REQ-AUTH-POLICY-006`: Post-Authentication Policy Check
- `REQ-AUTH-POLICY-007`: Mandatory Password Policy Enforcement
- `REQ-AUTH-POLICY-008`: Pre-Hash Password Validation
- `REQ-AUTH-POLICY-009`: Password Update Policy Validation
- `REQ-AUTH-POLICY-010`: CLI Password Policy Validation
- `REQ-AUTH-POLICY-011`: Pre-Authentication Policy Check
- `REQ-AUTH-DEFAULT-001`: Default User Creation
- `REQ-AUTH-CONFIG-001`: Configurable Password Policy

## 7. Complete Usage Examples

### Example 1: Production Environment Setup

```bash
# Configure production admin
export GEODE_ADMIN_USERNAME="prod_db_admin"
export GEODE_DEFAULT_PASSWORD="Production Database Administrative Access Phrase 2024"
export GEODE_PASSWORD_MIN_LENGTH=30
export GEODE_PASSWORD_MIN_WORDS=5

# First login (secure password meets policy)
$ geode auth login --user prod_db_admin
Password: [Production Database Administrative Access Phrase 2024]
Successfully authenticated as 'prod_db_admin' on server '127.0.0.1:3141'
Session token saved to ~/.geode/credentials.json
```

### Example 2: Development Environment (Requires Reset)

```bash
# Configure dev admin with weak password
export GEODE_ADMIN_USERNAME="dev_admin"
export GEODE_DEFAULT_PASSWORD="dev123"

# Login triggers reset
$ geode auth login --user dev_admin
Password: [dev123]
Authentication successful, but a password reset is required.
Your current password does not meet the security policy:
  - Minimum 20 characters
  - Must be a passphrase (3 or more words)
  - Must contain uppercase and lowercase letters
  - Spaces, numbers, and symbols are allowed

You must set a new password before accessing the database.

New password: [Development Environment Secure Access Phrase 2024]
Confirm password: [Development Environment Secure Access Phrase 2024]
Password updated successfully.
You can now log in with your new password.
```

### Example 3: High Security Environment

```bash
# Maximum security configuration
export GEODE_ADMIN_USERNAME="security_officer"
export GEODE_PASSWORD_MIN_LENGTH=40
export GEODE_PASSWORD_MIN_WORDS=6

# All users now require 40+ character passphrases with 6+ words
$ geode auth login --user security_officer
Username: security_officer
Password: [Ultra Secure Database Administrative Access Control Passphrase With Extended Length Requirements 2024]
Successfully authenticated as 'security_officer' on server '127.0.0.1:3141'
```

### Example 4: Custom Server Configuration

```bash
export GEODE_ADMIN_USERNAME="cluster_admin"
export GEODE_DEFAULT_PASSWORD="Distributed Database Cluster Administrative Passphrase 2024"

$ geode auth login --user cluster_admin --server cluster-01.geode.internal:3141
Password: [Distributed Database Cluster Administrative Passphrase 2024]
Successfully authenticated as 'cluster_admin' on server 'cluster-01.geode.internal:3141'
```

## 8. Security Features & Benefits

### Mandatory Policy Enforcement

- **Non-Bypassable Validation**: Password policy violations cannot be circumvented
- **Real-Time Enforcement**: Policy changes immediately affect all existing users
- **Pre and Post Validation**: Passwords validated before hashing AND after authentication
- **Dynamic Compliance**: Users with policy-violating passwords must reset immediately
- **Zero Exceptions**: No user can maintain a password that violates current policy

### Post-Quantum Readiness

- **High Computational Cost**: 20+ character passphrases with multiple words
- **Resistance**: GPU-based attacks, side-channel attacks, time-memory trade-offs
- **Future-Proof**: Computational requirements scale against quantum threats
- **Policy-Enforced**: Quantum resistance enforced through mandatory policy compliance

### Enterprise Security

- **Unified Standards**: No weak password exceptions for any user
- **Environment Flexibility**: Different security levels per deployment
- **Audit Compliance**: Comprehensive logging and policy enforcement
- **Zero Trust**: Every authentication attempt validated against current policy
- **Immediate Compliance**: Policy updates require immediate user compliance

### Operational Benefits  

- **Easy Deployment**: Environment variable configuration
- **Flexible Identity**: Customizable admin usernames for different environments
- **User Friendly**: Clear error messages and guided password reset
- **Cross-Platform**: Consistent behavior across Windows and Unix systems

## 9. Troubleshooting

### Common Issues

**Issue**: Login fails with "Invalid username or password"

```bash
# Check configured admin username
echo $GEODE_ADMIN_USERNAME  # Should match login username

# Verify password matches environment
echo $GEODE_DEFAULT_PASSWORD  # Should match login password
```

**Issue**: Password reset required unexpectedly  

```bash
# Check current policy requirements
echo "Min Length: $GEODE_PASSWORD_MIN_LENGTH (default: 20)"
echo "Min Words: $GEODE_PASSWORD_MIN_WORDS (default: 3)"

# Verify password meets all requirements:
# - Length >= configured minimum
# - Word count >= configured minimum  
# - Contains uppercase and lowercase
```

**Issue**: Password reset required after policy update

```bash
# This is normal behavior - policy enforcement is mandatory
# Check what changed in the policy:
echo "Current Min Length: $GEODE_PASSWORD_MIN_LENGTH"
echo "Current Min Words: $GEODE_PASSWORD_MIN_WORDS"

# Policy violations are non-bypassable
# Users must update passwords to meet current requirements
```

**Issue**: "Password does not meet security requirements" during login

```bash
# This indicates pre-authentication policy validation failed
# Check your password against current policy:
# - Minimum length requirement
# - Uppercase and lowercase requirement
# - Passphrase word count requirement

# Update password to meet current policy standards
```

**Issue**: Cannot save credentials

```bash
# Ensure home directory is writable
ls -la ~/.geode/

# Check permissions
chmod 700 ~/.geode/
chmod 600 ~/.geode/credentials.json
```

### Password Policy Validation

Test your password against the policy:

```bash
# Example password check (manual verification)
PASSWORD="My Test Database Passphrase 2024"
echo "Length: ${#PASSWORD} (need: $GEODE_PASSWORD_MIN_LENGTH)"
echo "Words: $(echo $PASSWORD | wc -w) (need: $GEODE_PASSWORD_MIN_WORDS)"
echo "Has uppercase: $(echo $PASSWORD | grep -q '[A-Z]' && echo 'Yes' || echo 'No')"
echo "Has lowercase: $(echo $PASSWORD | grep -q '[a-z]' && echo 'Yes' || echo 'No')"
```

## 10. Migration & Compatibility

### Upgrading from Previous Versions

- **Backward Compatibility**: Existing `geode` username continues to work
- **Automatic Migration**: Default user created on first startup
- **Policy Enforcement**: All existing users subject to new password requirements
- **Session Preservation**: Existing sessions remain valid until expiration

### Environment Migration

```bash
# Old configuration (still works)
export GEODE_DEFAULT_PASSWORD="secure_password"

# New enhanced configuration
export GEODE_ADMIN_USERNAME="production_admin"
export GEODE_DEFAULT_PASSWORD="Production Database Administrative Access Phrase 2024"
export GEODE_PASSWORD_MIN_LENGTH=25
export GEODE_PASSWORD_MIN_WORDS=4
```

This authentication system provides **enterprise-grade security** with **complete configurability** while maintaining **user-friendly operation** and **comprehensive documentation** for all deployment scenarios.
