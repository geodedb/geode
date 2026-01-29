# Docker LOG_LEVEL Configuration Changes

## Summary

Updated all Docker containers to use the `LOG_LEVEL` environment variable with a default value of `error` for production deployments. This can be overridden when starting containers.

## Changes Made

### Dockerfiles Updated

1. **Dockerfile** (main production image)
   - Added: `ENV LOG_LEVEL=error`
   - Removed: `--log-level info` from CMD
   - Location: Line 75

2. **Dockerfile.prod** (optimized production with GPU)
   - Added: `ENV LOG_LEVEL=error`
   - Location: Line 81

3. **Dockerfile.simple** (simplified build)
   - Added: `ENV LOG_LEVEL=error`
   - Removed: `--log-level debug` from CMD
   - Location: Line 111

4. **Dockerfile.reliable** (reliable build with mirrors)
   - Added: `ENV LOG_LEVEL=error`
   - Removed: `--log-level info` from CMD
   - Location: Line 95

### Docker Compose Files Updated

1. **docker-compose.yml** (main compose file)
   - Changed: `GEODE_LOG_LEVEL=info` → `LOG_LEVEL=${LOG_LEVEL:-error}`
   - Removed: `--log-level info` from command
   - The `${LOG_LEVEL:-error}` syntax allows overriding via environment

2. **docker-compose.distributed.yml** (3-node cluster)
   - Updated all 3 nodes (leader + 2 followers)
   - Changed: `GEODE_LOG_LEVEL=info` → `LOG_LEVEL=${LOG_LEVEL:-error}`

3. **docker-compose.example.yml** (example dataset)
   - Changed: `GEODE_LOG_LEVEL=info` → `LOG_LEVEL=${LOG_LEVEL:-error}`

4. **docker-compose.override.yml** (development overrides)
   - Changed: `GEODE_LOG_LEVEL=debug` → `LOG_LEVEL=debug`
   - Removed: `--log-level debug` from command
   - This file automatically overrides for local development

## Usage Examples

### Using Docker Run

```bash
# Use default error level (production)
docker run ghcr.io/spyderorg/geode:main

# Override to debug level (development/troubleshooting)
docker run -e LOG_LEVEL=debug ghcr.io/spyderorg/geode:main

# Override to info level
docker run -e LOG_LEVEL=info ghcr.io/spyderorg/geode:main
```

### Using Docker Compose

```bash
# Use default error level
docker-compose up

# Override to debug level
LOG_LEVEL=debug docker-compose up

# Or export it first
export LOG_LEVEL=debug
docker-compose up
```

### Development Mode

The `docker-compose.override.yml` file automatically sets `LOG_LEVEL=debug` for local development, so running `docker-compose up` will use debug logging when the override file is present.

## Benefits

1. **Cleaner Production Logs**: Default `error` level reduces log noise in production
2. **Easy Override**: Can be changed without rebuilding images
3. **Consistent**: All containers use the same `LOG_LEVEL` variable
4. **Flexible**: Supports all log levels: `error`, `warn`, `info`, `debug`, `trace`
5. **Docker-Native**: Uses standard Docker environment variable patterns

## Log Levels

From least to most verbose:

- `error` - Only errors and critical issues (production default)
- `warn` - Warnings and errors
- `info` - General informational messages
- `debug` - Detailed debugging information
- `trace` - Very detailed trace-level logging

## Testing

To verify the configuration:

```bash
# Check the environment variable in a container
docker run --rm ghcr.io/spyderorg/geode:main env | grep LOG_LEVEL

# Check with override
docker run --rm -e LOG_LEVEL=debug ghcr.io/spyderorg/geode:main env | grep LOG_LEVEL

# Verify logs are filtered (production)
docker run ghcr.io/spyderorg/geode:main  # Should show minimal logs

# Verify logs are verbose (debug)
docker run -e LOG_LEVEL=debug ghcr.io/spyderorg/geode:main  # Should show detailed logs
```

## Migration Notes

For existing deployments:

- **No action required**: Default `error` level will be used automatically
- **To restore previous behavior**: Set `LOG_LEVEL=info` in your environment
- **For debugging**: Set `LOG_LEVEL=debug` temporarily

## Related Files

- All Dockerfiles in root directory
- All docker-compose*.yml files
- Server code respects LOG_LEVEL via `vendor/quic/src/quic/logger.zig`
- CLI code uses `std.log` which respects log level environment
