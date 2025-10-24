# Hash Types Implementation

## Overview
Successfully added advanced cryptographic hash types to the Geode type system, including Blake2b, Blake2s, and Argon2id algorithms.

## Implemented Hash Algorithms

### 1. Blake2b-256
- **Algorithm ID**: `BLAKE2B_256 = 3`
- **Output Size**: 32 bytes (256 bits)
- **Use Case**: General-purpose hashing with good performance
- **Function**: `std.crypto.hash.blake2.Blake2b256`

### 2. Blake2b-512
- **Algorithm ID**: `BLAKE2B_512 = 4`
- **Output Size**: 64 bytes (512 bits)
- **Use Case**: When larger hash output is needed
- **Function**: `std.crypto.hash.blake2.Blake2b512`

### 3. Blake2s-256
- **Algorithm ID**: `BLAKE2S_256 = 5`
- **Output Size**: 32 bytes (256 bits)
- **Use Case**: Optimized for 32-bit platforms
- **Function**: `std.crypto.hash.blake2.Blake2s256`

### 4. Argon2id
- **Algorithm ID**: `ARGON2ID = 6`
- **Output Size**: 32 bytes (configurable)
- **Use Case**: Password hashing with salt
- **Function**: `std.crypto.pwhash.argon2`
- **Features**:
  - Configurable iterations (time cost)
  - Configurable memory usage
  - Configurable parallelism
  - Salt storage
  - Multiple security presets (Interactive, Moderate, Sensitive, OWASP)

## Key Features

### Password Hashing Support
The Argon2id implementation includes:
- Salt storage in the Hash struct
- Configurable parameters (iterations, memory, parallelism)
- Predefined security presets
- PHC string format support for storage

### Key Derivation Functions (KDF)
- Blake2b KDF for key derivation
- Blake2s KDF for smaller key sizes
- Context and key-based derivation

### Security Features
- Constant-time hash comparison
- Secure password hashing with Argon2id
- Proper salt handling
- Memory-hard password hashing

## Files Modified

1. **`src/storage/heap.zig`**
   - Extended `HashAlg` enum with new algorithms
   - Added `Argon2Params` struct
   - Modified `Hash` struct to support salt and params

2. **`src/types/hash.zig`** (Created)
   - Comprehensive hash module implementation
   - Hash creation functions
   - KDF implementations
   - Argon2 presets
   - Helper functions

3. **`src/types/evaluator_functions.zig`**
   - Added constructor functions for new hash types
   - `Argon2idHash` function with parameters
   - `Blake2bKdf` and `Blake2sKdf` functions

4. **`src/protocol.zig`**
   - Updated JSON serialization for new hash types
   - Support for salt and params in output

5. **`src/eval_extended.zig`**
   - Updated switch statements to handle new algorithms
   - Added algorithm name mappings

6. **`src/lib.zig`**
   - Exported hash module in types namespace

## Testing

Created comprehensive test coverage:
- `tests/test_hash_algorithms.zig` - Unit tests for all algorithms
- `tests/integration_hash_types.zig` - Integration tests with Geode
- CANARY tests for governance tracking

## Usage Examples

### Basic Hashing
```zig
const h = try hash.hash(allocator, .BLAKE2B_256, "data", null, null);
```

### Password Hashing
```zig
const params = hash.Argon2Presets.interactive;
const h = try hash.hash(allocator, .ARGON2ID, "password", salt, params);
```

### Key Derivation
```zig
const key = try hash.blake2bKdf(allocator, 32, "context", "master-key");
```

## Performance Characteristics

- **Blake2b**: Fast, parallelizable, suitable for large data
- **Blake2s**: Optimized for embedded systems and 32-bit platforms
- **Argon2id**: Memory-hard, resistant to GPU/ASIC attacks

## Compatibility

All implementations use Zig's standard library cryptographic functions from `std.crypto`, ensuring:
- Correct implementation
- Constant-time operations where needed
- Platform compatibility
- No external dependencies