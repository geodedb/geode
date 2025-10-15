# GQL Specification Verification - Correction

## Error Acknowledgment

**MISTAKE**: I incorrectly claimed that REMOVE and DETACH DELETE were Cypher-specific features not in the GQL standard.

**CORRECTION**: According to ISO/IEC 39075:2024 (the official GQL specification):
- **Section 13.4**: REMOVE statement IS part of GQL for removing properties
- **Section 13.5**: DETACH (in DELETE context) IS part of GQL

## Verified GQL Features (Per ISO/IEC 39075:2024)

### ✅ REMOVE Statement (Section 13.4)
**Status**: VALID GQL feature
**Purpose**: Remove properties or labels from graph elements
**Syntax**: `REMOVE element.property` or `REMOVE element:Label`

### ✅ DETACH DELETE (Section 13.5)
**Status**: VALID GQL feature
**Purpose**: Delete nodes and automatically delete their relationships
**Syntax**: `DETACH DELETE node`

### ✅ MERGE Statement
**Status**: VALID GQL feature
**Purpose**: Create nodes/relationships if they don't exist, match if they do

## Actual Cypher-Only Features

The following features ARE Cypher-specific and not in GQL:

### ❌ FOREACH (Confirmed Cypher-only)
**Status**: NOT in GQL standard
**Cypher Feature**: Loop construct for bulk operations
**Action**: Can be removed from keywords (currently not implemented in Geode)

### ❌ UNWIND (Confirmed Cypher-only - already removed)
**Status**: NOT in GQL standard
**Cypher Feature**: List unwinding operation
**Action**: Already removed from codebase

## Lesson Learned

**Always verify against the actual specification before making changes.**

The ISO/IEC 39075:2024 standard is the authoritative source for GQL features. When uncertain:
1. Check the specification PDF at `./docs/kb/gql/ISO_IEC_39075_2024(en).pdf`
2. Search for the specific section mentioned
3. Verify syntax and semantics match the implementation

## Current Status

- ✅ REMOVE: Correctly implemented, keep as-is
- ✅ DETACH: Correctly implemented, keep as-is
- ✅ MERGE: Correctly implemented, keep as-is
- ⚠️ FOREACH: Keyword defined but not implemented, can be removed
- ✅ UNWIND: Already removed (was Cypher-only)

## Action Items

1. ❌ DO NOT remove REMOVE statement implementation
2. ❌ DO NOT remove DETACH DELETE implementation
3. ✅ MAY remove FOREACH keyword (not implemented, Cypher-only)
4. ✅ Focus on fixing actual test failures instead
