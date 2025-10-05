#!/usr/bin/env bash
# Script to update all tests to use unified geode CLI instead of separate geodec/geoded binaries
# This script performs systematic replacements across all test files

set -e

echo "=== Updating Tests for Unified CLI ==="
echo "Converting all tests from geodec/geoded to unified geode CLI"
echo

# Track what we're updating
UPDATED_FILES=0

# Function to update a file
update_file() {
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
    
    # Update geodec calls to geode query (most specific patterns first)
    # Pattern: ./zig-out/bin/geodec "QUERY" --no-quic
    # Replace: ./zig-out/bin/geode query "QUERY" --no-quic
    sed -i 's|geodec \(.*\) --no-quic|geode query \1 --no-quic|g' "$file"
    
    # Pattern: ./zig-out/bin/geodec "QUERY" --format
    # Replace: ./zig-out/bin/geode query "QUERY" --format
    sed -i 's|geodec \(.*\) --format|geode query \1 --format|g' "$file"
    
    # Pattern: ./zig-out/bin/geodec "QUERY" --process
    # Replace: ./zig-out/bin/geode query "QUERY" --no-quic (remove --process)
    sed -i 's|geodec \(.*\) --process [^ ]*|geode query \1 --no-quic|g' "$file"
    
    # Update geoded server references  
    # Pattern: ./zig-out/bin/geoded --data-dir
    # Replace: ./zig-out/bin/geode serve --data-dir
    sed -i 's|geoded \(.*\)|geode serve \1|g' "$file"
    
    # Update remaining standalone geodec/geoded references
    sed -i 's|geodec|geode query|g' "$file"
    sed -i 's|geoded|geode serve|g' "$file"
    
    # Fix potential double commands that might occur
    sed -i 's|geode query query|geode query|g' "$file"
    sed -i 's|geode serve serve|geode serve|g' "$file"
    
    UPDATED_FILES=$((UPDATED_FILES + 1))
    echo "  -> Updated successfully"
}

# Update all shell test scripts
echo "Updating shell test scripts..."
for file in tests/*.sh; do
    update_file "$file"
done

echo
echo "=== Update Summary ==="
echo "Files updated: $UPDATED_FILES"
echo "Backup files created with .backup extension"
echo

# Run a quick verification
echo "=== Verification ==="
remaining_refs=$(find tests/ -name "*.sh" -exec grep -l "geodec\|geoded" {} \; 2>/dev/null | wc -l)
echo "Shell scripts still containing old references: $remaining_refs"

if [[ $remaining_refs -eq 0 ]]; then
    echo "✅ All shell scripts successfully updated!"
else
    echo "⚠️  Some files may need manual review:"
    find tests/ -name "*.sh" -exec grep -l "geodec\|geoded" {} \; 2>/dev/null || true
fi

echo
echo "To restore from backups if needed: find tests/ -name '*.backup' -exec sh -c 'mv \"\$1\" \"\${1%.backup}\"' _ {} \;"