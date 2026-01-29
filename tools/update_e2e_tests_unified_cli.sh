#!/usr/bin/env bash
# Script to update E2E integration tests to use unified geode CLI instead of separate geodec/geoded binaries

set -e

echo "=== Updating E2E Integration Tests for Unified CLI ==="
echo "Converting all E2E tests from geodec/geoded to unified geode CLI"
echo

# Track what we're updating
UPDATED_FILES=0

# Function to update a file
update_e2e_file() {
    local file="$1"
    local backup_file="${file}.backup"

    # Skip if file doesn't exist
    if [[ ! -f "$file" ]]; then
        return
    fi

    # Check if file contains old binary references
    if ! grep -q "geodec\|geoded" "$file"; then
        return
    fi

    echo "Updating: $file"

    # Create backup
    cp "$file" "$backup_file"

    # Update Zig files patterns:
    # Pattern: const exe = "./zig-out/bin/geodec";
    # Replace: const exe = "./zig-out/bin/geode";
    sed -i 's|"./zig-out/bin/geodec"|"./zig-out/bin/geode"|g' "$file"
    sed -i 's|"./zig-out/bin/geoded"|"./zig-out/bin/geode"|g' "$file"

    # Pattern: &.{ exe, "QUERY" }
    # Replace: &.{ exe, "query", "QUERY" }
    # This is more complex - need to handle different patterns

    # For files that have simple query patterns, add "query" subcommand
    # First, handle patterns like: run(&.{ exe, "RETURN ..." });
    # We need to insert "query" as the second argument
    sed -i 's|run(&\.{ exe, "\([^"]*\)" })|run(\&.{ exe, "query", "\1" })|g' "$file"

    # Handle more complex patterns with multiple arguments
    # Pattern: &.{ exe, "QUERY", "--flag" }
    # Replace: &.{ exe, "query", "QUERY", "--flag" }
    sed -i 's|&\.{ exe, "\([^"]*\)", \([^}]*\)|&.{ exe, "query", "\1", \2|g' "$file"

    # Handle patterns that might be using geoded with serve subcommand
    # Pattern: &.{ exe, "--data-dir" } (geoded usage)
    # Replace: &.{ exe, "serve", "--data-dir" }
    sed -i 's|&\.{ exe, "--\([^"]*\)"|&.{ exe, "serve", "--\1"|g' "$file"

    # For any remaining standalone exe references in certain contexts
    # This is more complex and might need manual review

    UPDATED_FILES=$((UPDATED_FILES + 1))
    echo "  -> Updated successfully"
}

# Update all E2E Zig test files
echo "Updating E2E integration test files..."
for file in tests/e2e_*.zig tests/cli_test.zig tests/*test*.zig tests/canary_*.zig tests/profile_*.zig tests/fuzz_*.zig; do
    if [[ -f "$file" ]]; then
        update_e2e_file "$file"
    fi
done

# Update integration test directory
for file in tests/integration/*.zig; do
    if [[ -f "$file" ]]; then
        update_e2e_file "$file"
    fi
done

echo
echo "=== Update Summary ==="
echo "Files updated: $UPDATED_FILES"
echo "Backup files created with .backup extension"
echo

# Run a quick verification
echo "=== Verification ==="
remaining_refs=$(find tests/ -name "*.zig" -exec grep -l "geodec\|geoded" {} \; 2>/dev/null | wc -l)
echo "Zig test files still containing old references: $remaining_refs"

if [[ $remaining_refs -eq 0 ]]; then
    echo "✅ All E2E integration tests successfully updated!"
else
    echo "⚠️  Some files may need manual review:"
    find tests/ -name "*.zig" -exec grep -l "geodec\|geoded" {} \; 2>/dev/null | head -10 || true
    echo "..."
fi

echo
echo "Note: The sed replacements are simple and may require manual review"
echo "for complex argument patterns. Check a few key test files manually."
echo
echo "To restore from backups if needed: find tests/ -name '*.backup' -exec sh -c 'mv \"\$1\" \"\${1%.backup}\"' _ {} \;"
