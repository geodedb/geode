# Docker Log Level Configuration

## Summary

The geode server's log level is the `geode serve --log-level <level>`
option (or `log_level` in a config file). Every image that runs
`geode serve` passes it in its `CMD`, with `error` as the image default.

geode reads no `LOG_LEVEL` environment variable. The images used to set
`ENV LOG_LEVEL=error` and this page documented it as the server's log
level, but only the vendored QUIC library's own logger reads that variable
(and its default is already `error`), so the server ran at its default
`info` (SONNY-6442). The variable was removed from the images.

## Images

| Image | Entrypoint | Default `CMD` |
| --- | --- | --- |
| `Dockerfile`, `Dockerfile.prebuilt` | `geode serve` | `--data-dir /data --log-level error --enable-auth` |
| `Dockerfile.simple` | `geode serve` | `--data-dir /data --listen 0.0.0.0:3141 --log-level error --enable-auth` |
| `Dockerfile.reliable` | `geode serve` | `--data-dir /data --listen 0.0.0.0:7567 --log-level error --enable-auth` |
| `Dockerfile.release*`, `Dockerfile.ci*`, `Dockerfile.devimage*` | `geode` | `serve --data-dir /data --log-level error ...` |

## Usage

The `CMD` is replaced as a whole by the arguments given to `docker run` (or
a compose `command:`), so give the log level together with the other
options:

```bash
# Default: error
docker run ghcr.io/spyderorg/geode:main

# Debug logging (images whose entrypoint is `geode serve`)
docker run ghcr.io/spyderorg/geode:main --data-dir /data --log-level debug --enable-auth

# Release images (entrypoint `geode`)
docker run ghcr.io/spyderorg/geode:latest serve --data-dir /data --log-level debug
```

In a compose file:

```yaml
services:
  geode:
    # geode does not read GEODE_LOG_LEVEL: compose substitutes it here.
    command: ["--data-dir", "/data", "--log-level", "${GEODE_LOG_LEVEL:-info}", "--enable-auth"]
```

(`${GEODE_LOG_LEVEL:-info}` is compose interpolation of the operator's own
shell variable; the server does not read it.) Arguments given without
`--log-level` run the server at its default, `info`.

## Log Levels

From least to most verbose: `critical`, `error`, `warn`, `info`, `debug`,
`trace` (see `geode serve --help`).

## Testing

`zig build test-sonny6430-deploy-docs-truth` checks that no Dockerfile sets
`LOG_LEVEL` or a geode variable no source file reads, and that every
image that runs `geode serve` passes `--log-level`.
