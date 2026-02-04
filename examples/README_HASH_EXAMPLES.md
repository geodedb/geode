# Hash Function Examples for Geode

This directory contains comprehensive examples demonstrating the new cryptographic hash functions added to Geode's type system.

## Hash Algorithms Supported

### General Purpose Hashing

- **SHA3-256**: NIST standard, 256-bit output
- **SHA3-512**: NIST standard, 512-bit output  
- **BLAKE3**: Modern, fast, parallelizable
- **BLAKE2b-256**: Fast, 256-bit output
- **BLAKE2b-512**: Fast, 512-bit output
- **BLAKE2s-256**: Optimized for 32-bit platforms

### Password Hashing

- **Argon2id**: Memory-hard, resistant to GPU/ASIC attacks
  - Configurable iterations (time cost)
  - Configurable memory usage
  - Configurable parallelism
  - Built-in salt handling

## Example Files

### 1. `gql_hash_examples.gql`

Comprehensive examples covering:

- Basic hash creation and comparison
- Password hashing with Argon2id
- Key derivation functions (KDF)
- Document integrity and signatures
- Blockchain/Merkle tree structures
- Data deduplication
- Migration strategies
- Security audit trails
- Multi-factor authentication
- Data privacy and anonymization

### 2. `hash_user_auth_example.gql`

Complete user authentication system including:

- User registration with secure password storage
- Login with brute-force protection
- Password reset flow
- Password upgrade strategies
- Session management
- API key generation
- Two-factor authentication
- Audit logging
- Privacy-preserving analytics
- Security monitoring

### 3. `hash_data_integrity_example.gql`

Data integrity and verification patterns:

- Content-addressable storage
- Deduplication systems
- Merkle trees for verification
- Change detection
- Distributed consensus
- Cache validation (ETags)
- Data pipeline integrity
- Commit-reveal schemes
- Proof of work
- Compliance and audit trails

## Constructor Functions

### Basic Hash Creation

```gql
-- Create hash from hex string
Hash("BLAKE2b-256", "4B7F8E...")

-- Hash data directly
HashData("BLAKE2b-256", "my data")
```

### Password Hashing

```gql
-- With explicit parameters
Argon2idHash(password, salt, iterations, memory_kb, parallelism)

-- Example with interactive preset
Argon2idHash("SecurePass123", "random_salt_16b", 4, 65536, 1)
```

### Key Derivation

```gql
-- Blake2b KDF (variable output length)
Blake2bKdf(32, "context-string", "master-key")

-- Blake2s KDF (max 32 bytes output)
Blake2sKdf(16, "auth-context", "secret-key")
```

## Built-in Functions

### Hash Operations

- `hash_equals(a, b)` - Constant-time comparison (prevents timing attacks)
- `hash_alg(hash)` - Get algorithm name as string

## Security Presets for Argon2id

### Interactive (Fast)

- Iterations: 4
- Memory: 64 MB
- Parallelism: 1
- Use case: User-facing web applications

### Moderate (Balanced)

- Iterations: 6
- Memory: 256 MB
- Parallelism: 1
- Use case: Standard security requirements

### Sensitive (High Security)

- Iterations: 8
- Memory: 1 GB
- Parallelism: 1
- Use case: High-value targets

### OWASP Recommended

- Iterations: 2
- Memory: 19 MB
- Parallelism: 1
- Use case: Following OWASP guidelines

## Best Practices

### Password Storage

1. Always use Argon2id for passwords
2. Generate random salts (16+ bytes)
3. Store salt with the hash
4. Use appropriate security presets
5. Plan for parameter upgrades

### Data Integrity

1. Use BLAKE3 or BLAKE2b for speed
2. Use BLAKE2b-512 for maximum security
3. Implement hash chains for audit logs
4. Use constant-time comparison

### Key Derivation

1. Use unique contexts for each purpose
2. Never reuse contexts across applications
3. Derive keys from a master secret
4. Use appropriate output lengths

## Performance Characteristics

| Algorithm | Speed | Security | Use Case |
|-----------|-------|----------|----------|
| BLAKE3 | Fastest | High | General hashing, large data |
| BLAKE2b | Very Fast | High | General purpose |
| BLAKE2s | Fast | High | 32-bit systems |
| SHA3-256 | Moderate | High | Standards compliance |
| SHA3-512 | Moderate | Very High | Maximum security |
| Argon2id | Slow* | Very High | Passwords only |

*Intentionally slow to resist brute-force attacks

## Migration Guide

### From SHA3 to BLAKE2

```gql
-- Add new hash while keeping old
MATCH (doc:Document)
WHERE exists(doc.sha3_hash)
SET doc.blake2b_hash = HashData("BLAKE2b-256", doc.content)
```

### Password Hash Upgrade

```gql
-- Upgrade on next login
MATCH (user:User {username: $username})
WHERE hash_equals(user.old_hash, $old_hash_function($password))
SET user.new_hash = Argon2idHash($password, $new_salt, 4, 65536, 1)
```

## Testing

Run these examples against a Geode instance to verify functionality:

```bash
# Basic hash operations
geode query < gql_hash_examples.gql

# Authentication system
geode query < hash_user_auth_example.gql

# Data integrity patterns
geode query < hash_data_integrity_example.gql
```

## Security Considerations

1. **Never log passwords or password hashes**
2. **Use constant-time comparison for sensitive data**
3. **Generate cryptographically secure random salts**
4. **Store salts separately from hashes when possible**
5. **Plan for algorithm migration**
6. **Monitor for unusual hash computation patterns (mining)**
7. **Implement rate limiting for password operations**
8. **Use appropriate Argon2 parameters for your threat model**

## References

- [BLAKE2 Specification](https://blake2.net/)
- [BLAKE3 Specification](https://github.com/BLAKE3-team/BLAKE3)
- [Argon2 RFC 9106](https://datatracker.ietf.org/doc/html/rfc9106)
- [OWASP Password Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html)
- [SHA-3 Standard (FIPS 202)](https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.202.pdf)
