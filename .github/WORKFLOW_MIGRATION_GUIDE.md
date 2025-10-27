# GitHub Workflows Migration Guide

This guide explains how to migrate existing workflows to use the new `setup-geode` composite action.

## What Changed

We've created a reusable composite action (`.github/actions/setup-geode`) that combines:
- Nix environment setup
- Zig compiler installation
- Go language setup (optional)
- Build artifact caching

This reduces boilerplate code in workflows from ~25-30 lines down to ~6 lines per job.

## Benefits

### ✅ **Less Boilerplate**
- **Before**: 25-30 lines of setup code per job
- **After**: 6 lines of setup code per job
- **Reduction**: ~80% less code

### ✅ **Centralized Version Management**
- Update Zig version in one place (composite action)
- All workflows automatically use the new version
- No need to update 12+ workflow files

### ✅ **Consistent Caching**
- Unified caching strategy across all workflows
- Proper cache key generation
- Automatic restoration and storage

### ✅ **Better Maintainability**
- Single source of truth for setup logic
- Easier to add new tools or configuration
- Reduced chance of inconsistencies

## Migration Steps

### Step 1: Identify Workflow Pattern

Look for this pattern in your workflows:

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

  - name: Set up Go  # Optional - may not be present
    uses: actions/setup-go@v5
    with:
      go-version: '1.23'

  - name: Cache build artifacts  # Optional - may not be present
    uses: actions/cache@v4
    with:
      path: |
        zig-cache
        zig-out
      key: ${{ runner.os }}-zig-${{ hashFiles('build.zig','src/**/*.zig') }}
```

### Step 2: Replace with Composite Action

Replace the above with:

```yaml
steps:
  - uses: ./.github/actions/setup-geode
    with:
      git-credentials: ${{ secrets.GIT_CREDENTIALS }}
      gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
      cachix-auth-token: ${{ secrets.CACHIX_AUTH_TOKEN }}
      # Only add these if the original workflow had them:
      go-version: '1.23'  # Add only if Go was being set up
```

### Step 3: Verify Custom Configurations

Some workflows may have custom configurations that need special attention:

#### Custom Zig Version

If a workflow uses a different Zig version:

```yaml
# Before
- name: Setup Zig
  uses: goto-bus-stop/setup-zig@v2
  with:
    version: 0.16.0  # Custom version

# After
- uses: ./.github/actions/setup-geode
  with:
    git-credentials: ${{ secrets.GIT_CREDENTIALS }}
    gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
    cachix-auth-token: ${{ secrets.CACHIX_AUTH_TOKEN }}
    zig-version: '0.16.0'  # Specify custom version
```

#### Matrix Builds with Cache Isolation

For matrix builds where you need separate caches:

```yaml
# Before
strategy:
  matrix:
    os: [ubuntu-latest, macos-latest]
steps:
  - uses: actions/cache@v4
    with:
      path: zig-cache
      key: ${{ matrix.os }}-zig-${{ hashFiles('**/*.zig') }}

# After
strategy:
  matrix:
    os: [ubuntu-latest, macos-latest]
steps:
  - uses: ./.github/actions/setup-geode
    with:
      git-credentials: ${{ secrets.GIT_CREDENTIALS }}
      gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
      cachix-auth-token: ${{ secrets.CACHIX_AUTH_TOKEN }}
      cache-key-prefix: ${{ matrix.os }}-  # Ensures separate caches
```

#### Disabling Cache

If a workflow explicitly doesn't want caching:

```yaml
- uses: ./.github/actions/setup-geode
  with:
    git-credentials: ${{ secrets.GIT_CREDENTIALS }}
    gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
    cachix-auth-token: ${{ secrets.CACHIX_AUTH_TOKEN }}
    enable-cache: 'false'
```

## Migration Checklist

Use this checklist for each workflow file:

- [ ] Locate the nix-setup + Zig setup + (optional) Go setup pattern
- [ ] Replace with the composite action
- [ ] Check if Go is needed (add `go-version` if yes)
- [ ] Check for custom Zig version (add `zig-version` if non-standard)
- [ ] Check for matrix builds (add `cache-key-prefix` if needed)
- [ ] Remove explicit cache steps (they're now automatic)
- [ ] Remove any "Zig version" verification steps (now automatic)
- [ ] Test the workflow in a PR or with workflow_dispatch

## Workflow-by-Workflow Guide

### 1. build.yml
**Jobs to migrate**: All 7 jobs (build-and-test, build, cross-platform-stdio-test, cross-builds, build-test, dev-release, tcp-go-client)

**Special considerations**:
- Most jobs need Go (`go-version: '1.23'`)
- `cross-builds` job has matrix - use `cache-key-prefix: ${{ matrix.archive_os }}-${{ matrix.archive_arch }}-`
- Some jobs use Zig 0.15.1 explicitly

**Example migration (build-and-test job)**:
```yaml
# Before: Lines 23-35 (13 lines)
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
  - name: Zig version
    run: zig version

# After: (6 lines)
steps:
  - uses: ./.github/actions/setup-geode
    with:
      git-credentials: ${{ secrets.GIT_CREDENTIALS }}
      gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
      cachix-auth-token: ${{ secrets.CACHIX_AUTH_TOKEN }}
      go-version: '1.23'
```

### 2. nightly.yml
**Jobs to migrate**: nightly-build

**Special considerations**:
- Uses Go version 1.21
- Has env variable ZIG_VERSION

**Example**: See `.github/workflows/nightly.example.yml`

### 3. fuzz.yml
**Jobs to migrate**: fuzz-linux, fuzz-nightly

**Special considerations**:
- Has explicit cache steps to remove
- Uses Zig 0.15.1

### 4. cross-compile-clients.yml
**Jobs to migrate**: cross-compile, test-matrix

**Special considerations**:
- Uses Go version 1.21
- Matrix build in test-matrix job

### 5. governance.yml
**Jobs to migrate**: canary-governance, telemetry-smoke

**Special considerations**:
- Has explicit cache steps
- canary-governance uses Go 1.22
- telemetry-smoke doesn't need Go

### 6. docker-publish.yml
**Jobs to migrate**: build-and-push, build-and-push-alpine, test-images, security-scan, create-release

**Special considerations**:
- None of these jobs need Go
- Just nix-setup + Zig

### 7. release.yml
**Jobs to migrate**: build-matrix, publish-release

**Special considerations**:
- Uses env.ZIG_VERSION
- Matrix build with cross-compilation
- publish-release doesn't need Zig/Go (just nix-setup)

### 8. build-binaries.yml
**Jobs to migrate**: build

**Special considerations**:
- Has explicit cache step to remove
- Needs Zig 0.15.1

### 9. deploy-pages.yml
**Jobs to migrate**: build

**Special considerations**:
- Only needs nix-setup (no Zig/Go)
- Uses a composite action `devnw/docs-pages@main`

### 10. build-and-publish.yml
**Jobs to migrate**: build

**Special considerations**:
- Has explicit cache step
- Needs Zig 0.15.1

### 11. nightly-governance.yml
**Jobs to migrate**: nightly-governance

**Special considerations**:
- Has explicit cache step
- Doesn't need Go
- Runs on self-hosted runner

### 12. automerge.yml
**Jobs to migrate**: NONE

**Reason**: Uses `pascalgn/automerge-action` only, doesn't need our setup

## Testing Migration

### Test Individual Workflow

1. Migrate one workflow file
2. Create a feature branch
3. Push to trigger the workflow (or use `workflow_dispatch` if available)
4. Check logs for:
   - "Nix setup with checkout" step
   - "Setup Zig" step with correct version
   - "Verify Zig installation" step showing version
   - "Cache Zig build artifacts" step (if enabled)
   - "Setup Go" step (if go-version was provided)
5. Verify build succeeds

### Test All Workflows

Create a PR that triggers all workflows and verify:
- All jobs complete successfully
- Build times are similar or faster (due to better caching)
- No unexpected errors in setup steps

## Rollback Plan

If issues arise, rollback is simple:

1. **Revert the workflow file**: Git revert the commit
2. **Keep the composite action**: It doesn't affect non-migrated workflows
3. **Investigate the issue**: Check logs, test locally
4. **Fix and retry**: Update the composite action or workflow as needed

The composite action is backward compatible - old workflows continue to work while you migrate.

## Future Improvements

Once all workflows are migrated, we can:

1. **Update default Zig version globally**: Edit composite action only
2. **Add new tools**: Update composite action, all workflows benefit
3. **Improve caching strategy**: Change in one place
4. **Add validation steps**: Automatic in all workflows

## Questions?

See the composite action's README: `.github/actions/setup-geode/README.md`

## Summary

**Migration Impact**:
- 12 workflows
- ~200 lines of code removed
- ~60 lines of code added (mostly in composite action)
- Net reduction: ~140 lines (70% less setup code)

**Estimated Time**: 1-2 hours for all migrations

**Risk Level**: Low (can test one workflow at a time, easy rollback)

**Benefit**: Significantly easier maintenance and version management
