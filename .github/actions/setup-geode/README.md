# Setup Geode Development Environment

A composite GitHub Action that sets up the complete Geode development environment including Nix, Zig, Go, and build artifact caching.

## Features

- ✅ **Nix Environment**: Sets up Nix with repository checkout
- ✅ **Zig Compiler**: Installs specified Zig version (default: 0.15.1)
- ✅ **Go Language**: Optional Go installation for client testing
- ✅ **Build Caching**: Automatic Zig build artifact caching
- ✅ **Verification**: Confirms tool installations with version checks

## Usage

### Basic Usage (Zig only)

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/setup-geode
        with:
          git-credentials: ${{ secrets.GIT_CREDENTIALS }}
          gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
          cachix-auth-token: ${{ secrets.CACHIX_AUTH_TOKEN }}

      - name: Build
        run: zig build
```

### With Go Support

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/setup-geode
        with:
          git-credentials: ${{ secrets.GIT_CREDENTIALS }}
          gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
          cachix-auth-token: ${{ secrets.CACHIX_AUTH_TOKEN }}
          go-version: '1.23'

      - name: Build
        run: make build

      - name: Test Go clients
        run: go test -v ./clients/go/...
```

### Custom Zig Version

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/setup-geode
        with:
          git-credentials: ${{ secrets.GIT_CREDENTIALS }}
          gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
          cachix-auth-token: ${{ secrets.CACHIX_AUTH_TOKEN }}
          zig-version: '0.16.0'  # Use a different Zig version
```

### Matrix Builds with Cache Isolation

```yaml
jobs:
  build:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
        zig: ['0.15.1']
    runs-on: ${{ matrix.os }}
    steps:
      - uses: ./.github/actions/setup-geode
        with:
          git-credentials: ${{ secrets.GIT_CREDENTIALS }}
          gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
          cachix-auth-token: ${{ secrets.CACHIX_AUTH_TOKEN }}
          zig-version: ${{ matrix.zig }}
          cache-key-prefix: ${{ matrix.os }}-

      - name: Build
        run: zig build
```

### Disable Caching

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/setup-geode
        with:
          git-credentials: ${{ secrets.GIT_CREDENTIALS }}
          gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
          cachix-auth-token: ${{ secrets.CACHIX_AUTH_TOKEN }}
          enable-cache: 'false'  # Disable build artifact caching
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `git-credentials` | Git credentials for private repositories | No | - |
| `gh-access-token` | GitHub access token | No | - |
| `cachix-auth-token` | Cachix authentication token | No | - |
| `zig-version` | Zig version to install | No | `0.15.1` |
| `go-version` | Go version to install (leave empty to skip) | No | `` |
| `enable-cache` | Enable Zig build artifact caching | No | `true` |
| `cache-key-prefix` | Prefix for cache key (useful for matrix builds) | No | `` |

## What It Does

### 1. Nix Setup
- Checks out the repository
- Sets up Nix environment
- Configures Cachix for binary caching
- Sets up Git credentials

### 2. Zig Installation
- Installs specified Zig version using `goto-bus-stop/setup-zig`
- Verifies installation with version check

### 3. Go Installation (Optional)
- Installs specified Go version if `go-version` is provided
- Verifies installation with version check

### 4. Build Caching
- Caches Zig build artifacts in `zig-cache`, `zig-out`, and `~/.cache/zig`
- Uses smart cache keys based on OS, Zig version, and source file hashes
- Supports custom cache key prefixes for matrix builds

## Migration Guide

### Before (Old Pattern)

```yaml
steps:
  - uses: spyderorg/workflows/.github/actions/nix-setup@main
    with:
      git-credentials: ${{ secrets.GIT_CREDENTIALS }}
      gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
      cachix-auth-token: ${{ secrets.CACHIX_AUTH_TOKEN }}

  - name: Setup Zig 0.15.1
    uses: goto-bus-stop/setup-zig@v2
    with:
      version: 0.15.1

  - name: Set up Go
    uses: actions/setup-go@v5
    with:
      go-version: '1.23'

  - name: Cache build artifacts
    uses: actions/cache@v4
    with:
      path: |
        zig-cache
        zig-out
      key: ${{ runner.os }}-zig-${{ hashFiles('build.zig','src/**/*.zig') }}
```

### After (New Pattern)

```yaml
steps:
  - uses: ./.github/actions/setup-geode
    with:
      git-credentials: ${{ secrets.GIT_CREDENTIALS }}
      gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
      cachix-auth-token: ${{ secrets.CACHIX_AUTH_TOKEN }}
      go-version: '1.23'
```

**Benefits**:
- Reduced from ~30 lines to ~6 lines per job
- Centralized version management
- Consistent caching strategy
- Automatic verification steps

## Maintenance

### Updating Default Zig Version

To update the default Zig version for all workflows:

1. Edit `.github/actions/setup-geode/action.yml`
2. Change the `zig-version` default value (line 20)
3. All workflows using this action will automatically use the new version

### Updating Default Go Version

Since Go versions vary more frequently, we intentionally don't set a default. Each workflow specifies its own Go version as needed.

## Examples

See these workflows for real-world usage examples:

- [`.github/workflows/build.yml`](../../workflows/build.yml) - Multi-platform builds
- [`.github/workflows/nightly.yml`](../../workflows/nightly.yml) - Extended testing
- [`.github/workflows/fuzz.yml`](../../workflows/fuzz.yml) - Fuzz testing
- [`.github/workflows/governance.yml`](../../workflows/governance.yml) - Governance checks

## Troubleshooting

### Cache Not Working

If build caching isn't working:
1. Check that `enable-cache` is set to `'true'` (it's the default)
2. Verify the cache key prefix matches between runs
3. Check GitHub Actions cache usage limits

### Go Not Found

If Go commands fail:
1. Ensure `go-version` input is provided
2. Check that the Go version is valid (e.g., `'1.23'`, `'1.22'`)
3. Verify Go installation in logs: look for "Verify Go installation" step

### Wrong Zig Version

If wrong Zig version is installed:
1. Check `zig-version` input
2. Verify the version is available in `goto-bus-stop/setup-zig`
3. Look at "Verify Zig installation" step output in logs
