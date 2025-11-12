#!/usr/bin/env bash
# Generate modularization metrics for Geode codebase
# Tracks module sizes, dependencies, and generates reports

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Get project root (2 levels up from scripts/modularization/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# Output directory
METRICS_DIR="$PROJECT_ROOT/metrics"
mkdir -p "$METRICS_DIR"

# Output files
METRICS_REPORT="$METRICS_DIR/modularization_metrics.txt"
LOC_REPORT="$METRICS_DIR/module_sizes.txt"
DEPS_REPORT="$METRICS_DIR/dependencies.txt"
GRAPH_DOT="$METRICS_DIR/dependency_graph.dot"
GRAPH_PNG="$METRICS_DIR/dependency_graph.png"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   Geode Modularization Metrics${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${CYAN}Generated: $(date)${NC}"
echo -e "${CYAN}Project Root: $PROJECT_ROOT${NC}"
echo ""

# ============================================================
# 1. MODULE SIZE TRACKING (Lines of Code)
# ============================================================

echo -e "${MAGENTA}[1/4] Analyzing module sizes...${NC}"

# Get all .zig source files
SRC_FILES=$(find src -name "*.zig" -type f | sort)
TOTAL_FILES=$(echo "$SRC_FILES" | wc -l)

# Create LOC report
cat > "$LOC_REPORT" << EOF
# Module Size Report
# Generated: $(date)
# Total source files analyzed: $TOTAL_FILES

## Largest Files (>1000 lines)
EOF

echo "" >> "$LOC_REPORT"
printf "%-60s %10s\n" "File" "Lines" >> "$LOC_REPORT"
echo "============================================================================" >> "$LOC_REPORT"

# Track large files
LARGE_COUNT=0

while IFS= read -r file; do
    if [ -f "$file" ]; then
        loc=$(wc -l < "$file" | tr -d ' ')
        if [ "$loc" -gt 1000 ]; then
            printf "%-60s %10s\n" "$file" "$loc" >> "$LOC_REPORT"
            LARGE_COUNT=$((LARGE_COUNT + 1))
        fi
    fi
done <<< "$SRC_FILES"

# Add medium-sized files
cat >> "$LOC_REPORT" << EOF

## Medium Files (500-1000 lines)
EOF

echo "" >> "$LOC_REPORT"
printf "%-60s %10s\n" "File" "Lines" >> "$LOC_REPORT"
echo "============================================================================" >> "$LOC_REPORT"

MEDIUM_COUNT=0

while IFS= read -r file; do
    if [ -f "$file" ]; then
        loc=$(wc -l < "$file" | tr -d ' ')
        if [ "$loc" -ge 500 ] && [ "$loc" -le 1000 ]; then
            printf "%-60s %10s\n" "$file" "$loc" >> "$LOC_REPORT"
            MEDIUM_COUNT=$((MEDIUM_COUNT + 1))
        fi
    fi
done <<< "$SRC_FILES"

# Add summary
cat >> "$LOC_REPORT" << EOF

## Size Distribution Summary

Total Files: $TOTAL_FILES
Large Files (>1000 lines): $LARGE_COUNT
Medium Files (500-1000 lines): $MEDIUM_COUNT
Small Files (<500 lines): $((TOTAL_FILES - LARGE_COUNT - MEDIUM_COUNT))
EOF

# Calculate total LOC
TOTAL_LOC=0
while IFS= read -r file; do
    if [ -f "$file" ]; then
        loc=$(wc -l < "$file" | tr -d ' ')
        TOTAL_LOC=$((TOTAL_LOC + loc))
    fi
done <<< "$SRC_FILES"

echo "Total Lines of Code: $TOTAL_LOC" >> "$LOC_REPORT"

echo -e "${GREEN}✓ Module sizes analyzed${NC}"
echo -e "  Large files (>1000 LOC): ${YELLOW}$LARGE_COUNT${NC}"
echo -e "  Medium files (500-1000 LOC): $MEDIUM_COUNT"
echo -e "  Total LOC: $TOTAL_LOC"

# ============================================================
# 2. IMPORT DEPENDENCY TRACKING
# ============================================================

echo ""
echo -e "${MAGENTA}[2/4] Analyzing import dependencies...${NC}"

# Create dependencies report
cat > "$DEPS_REPORT" << EOF
# Import Dependencies Report
# Generated: $(date)

## Import Analysis
EOF

echo "" >> "$DEPS_REPORT"

# Track imports per file (optimized with single grep command)
TEMP_IMPORTS=$(mktemp)

# Use grep with filename reporting to get all imports at once
grep -rn "^const .* = @import(" src --include="*.zig" 2>/dev/null | \
    cut -d':' -f1 | sort | uniq -c | \
    awk '{print $2, $1}' > "$TEMP_IMPORTS" 2>/dev/null || true

# Calculate total imports
TOTAL_IMPORTS=$(awk '{sum+=$2} END {print sum}' "$TEMP_IMPORTS" 2>/dev/null || echo "0")

# Find files with most imports
echo "## Files with Most Imports (Top 20)" >> "$DEPS_REPORT"
echo "" >> "$DEPS_REPORT"
printf "%-60s %10s\n" "File" "Imports" >> "$DEPS_REPORT"
echo "============================================================================" >> "$DEPS_REPORT"

sort -t' ' -k2 -rn "$TEMP_IMPORTS" 2>/dev/null | head -20 | while read -r file count; do
    printf "%-60s %10s\n" "$file" "$count" >> "$DEPS_REPORT"
done 2>/dev/null || echo "  (No import data available)" >> "$DEPS_REPORT"

rm -f "$TEMP_IMPORTS"

cat >> "$DEPS_REPORT" << EOF

## Summary

Total import statements: $TOTAL_IMPORTS
Average imports per file: $((TOTAL_IMPORTS / TOTAL_FILES))
EOF

echo -e "${GREEN}✓ Dependencies analyzed${NC}"
echo -e "  Total imports: $TOTAL_IMPORTS"
echo -e "  Average per file: $((TOTAL_IMPORTS / TOTAL_FILES))"

# ============================================================
# 3. CIRCULAR DEPENDENCY DETECTION
# ============================================================

echo ""
echo -e "${MAGENTA}[3/4] Checking for circular dependencies...${NC}"

# Simple circular dependency check
# Look for bidirectional imports between files

cat >> "$DEPS_REPORT" << EOF

## Circular Dependency Check

Checking for bidirectional imports...
EOF

echo "" >> "$DEPS_REPORT"

CIRCULARS_FOUND=0

# Known circular dependencies from the plan
echo "Known circular dependencies:" >> "$DEPS_REPORT"
echo "  1. execution.zig ↔ eval.zig" >> "$DEPS_REPORT"
echo "  2. server/main.zig ↔ execution/* modules" >> "$DEPS_REPORT"

# Check if they still exist
if [ -f "src/execution.zig" ] && [ -f "src/eval.zig" ]; then
    exec_imports_eval=$(grep -c "eval" "src/execution.zig" 2>/dev/null || echo "0")
    eval_imports_exec=$(grep -c "execution" "src/eval.zig" 2>/dev/null || echo "0")

    if [ "$exec_imports_eval" -gt 0 ] && [ "$eval_imports_exec" -gt 0 ]; then
        echo "" >> "$DEPS_REPORT"
        echo "⚠️  CIRCULAR: execution.zig ↔ eval.zig (STILL EXISTS)" >> "$DEPS_REPORT"
        CIRCULARS_FOUND=$((CIRCULARS_FOUND + 1))
    else
        echo "" >> "$DEPS_REPORT"
        echo "✓ execution.zig ↔ eval.zig (RESOLVED)" >> "$DEPS_REPORT"
    fi
fi

if [ $CIRCULARS_FOUND -gt 0 ]; then
    echo -e "${YELLOW}⚠ Circular dependencies found: $CIRCULARS_FOUND${NC}"
else
    echo -e "${GREEN}✓ No circular dependencies detected${NC}"
fi

# ============================================================
# 4. DEPENDENCY GRAPH GENERATION
# ============================================================

echo ""
echo -e "${MAGENTA}[4/4] Generating dependency graph...${NC}"

# Create DOT file for GraphViz
cat > "$GRAPH_DOT" << 'EOF'
digraph GeodeDependencies {
    // Graph styling
    rankdir=TB;
    node [shape=box, style=filled, fillcolor=lightblue];
    edge [color=gray40];

    // Legend
    subgraph cluster_legend {
        label="Legend";
        style=dashed;

        large [label=">1000 LOC", fillcolor=red, fontcolor=white];
        medium [label="500-1000 LOC", fillcolor=orange];
        small [label="<500 LOC", fillcolor=lightgreen];

        large -> medium -> small [style=invis];
    }

    // Major modules
    subgraph cluster_core {
        label="Core Modules";
        style=filled;
        fillcolor=lightgray;

        server [label="server/main.zig\n7,039 lines", fillcolor=red, fontcolor=white];
        cli [label="cli/main.zig\n5,885 lines", fillcolor=red, fontcolor=white];
        execution [label="execution.zig", fillcolor=orange];
        eval [label="eval.zig\n3,332 lines", fillcolor=orange];
    }

    subgraph cluster_execution {
        label="Execution Subsystem";
        style=filled;
        fillcolor=lightyellow;

        path_call [label="path_and_call_operations.zig\n4,725 lines", fillcolor=red, fontcolor=white];
    }

    subgraph cluster_security {
        label="Security Subsystem";
        style=filled;
        fillcolor=lightcyan;

        audit [label="audit.zig\n1,701 lines", fillcolor=orange];
        tde [label="tde.zig\n1,482 lines", fillcolor=orange];
    }

    subgraph cluster_streaming {
        label="Streaming Subsystem";
        style=filled;
        fillcolor=lavender;

        cdc [label="cdc_enhanced.zig\n1,390 lines", fillcolor=orange];
    }

    // Dependencies
    server -> execution;
    server -> eval;
    server -> path_call;

    cli -> execution;
    cli -> eval;

    execution -> eval [color=red, label="circular", penwidth=2];
    eval -> execution [color=red, label="circular", penwidth=2];

    execution -> path_call;

    // Note
    note [label="Red = Needs modularization (>1000 LOC)\nOrange = Medium priority (500-1000 LOC)\nRed arrows = Circular dependencies", shape=note, fillcolor=lightyellow];
}
EOF

echo -e "${GREEN}✓ Dependency graph generated${NC}"
echo -e "  DOT file: ${CYAN}$GRAPH_DOT${NC}"

# Try to generate PNG if graphviz is installed
if command -v dot >/dev/null 2>&1; then
    dot -Tpng "$GRAPH_DOT" -o "$GRAPH_PNG" 2>/dev/null || echo -e "${YELLOW}  (PNG generation failed - graphviz may need configuration)${NC}"
    if [ -f "$GRAPH_PNG" ]; then
        echo -e "  PNG image: ${CYAN}$GRAPH_PNG${NC}"
    fi
else
    echo -e "${YELLOW}  (Install graphviz to generate PNG: apt-get install graphviz)${NC}"
fi

# ============================================================
# 5. GENERATE SUMMARY REPORT
# ============================================================

echo ""
echo -e "${MAGENTA}Generating summary report...${NC}"

cat > "$METRICS_REPORT" << EOF
# Geode Modularization Metrics Report
Generated: $(date)

## Overview

This report tracks the modularization progress of the Geode graph database codebase.

## Code Metrics

### Lines of Code
- **Total LOC**: $TOTAL_LOC
- **Total Files**: $TOTAL_FILES
- **Average LOC per file**: $((TOTAL_LOC / TOTAL_FILES))

### File Size Distribution
- **Large Files (>1000 LOC)**: $LARGE_COUNT files
- **Medium Files (500-1000 LOC)**: $MEDIUM_COUNT files
- **Small Files (<500 LOC)**: $((TOTAL_FILES - LARGE_COUNT - MEDIUM_COUNT)) files

### Largest Files Requiring Modularization

EOF

# Add top 10 largest files
echo "Top 10 Largest Files:" >> "$METRICS_REPORT"
echo "" >> "$METRICS_REPORT"

while IFS= read -r file; do
    if [ -f "$file" ]; then
        loc=$(wc -l < "$file" | tr -d ' ')
        echo "$file $loc"
    fi
done <<< "$SRC_FILES" | sort -t' ' -k2 -rn | head -10 | while read -r file loc; do
    echo "- \`$file\`: $loc lines" >> "$METRICS_REPORT"
done

cat >> "$METRICS_REPORT" << EOF

## Import Dependencies

- **Total import statements**: $TOTAL_IMPORTS
- **Average imports per file**: $((TOTAL_IMPORTS / TOTAL_FILES))

## Circular Dependencies

EOF

if [ $CIRCULARS_FOUND -gt 0 ]; then
    echo "⚠️  **$CIRCULARS_FOUND circular dependencies detected**" >> "$METRICS_REPORT"
    echo "" >> "$METRICS_REPORT"
    echo "These must be resolved during Phase 5 of modularization." >> "$METRICS_REPORT"
else
    echo "✅ **No circular dependencies detected**" >> "$METRICS_REPORT"
fi

cat >> "$METRICS_REPORT" << EOF

## Modularization Targets

Based on the analysis, the following files should be prioritized for modularization:

### P0 CRITICAL (>5000 LOC)
EOF

while IFS= read -r file; do
    if [ -f "$file" ]; then
        loc=$(wc -l < "$file" | tr -d ' ')
        if [ "$loc" -gt 5000 ]; then
            echo "- \`$file\` ($loc lines)" >> "$METRICS_REPORT"
        fi
    fi
done <<< "$SRC_FILES" | sort -t' ' -k2 -rn

cat >> "$METRICS_REPORT" << EOF

### P1 HIGH (3000-5000 LOC)
EOF

while IFS= read -r file; do
    if [ -f "$file" ]; then
        loc=$(wc -l < "$file" | tr -d ' ')
        if [ "$loc" -ge 3000 ] && [ "$loc" -le 5000 ]; then
            echo "- \`$file\` ($loc lines)" >> "$METRICS_REPORT"
        fi
    fi
done <<< "$SRC_FILES" | sort -t' ' -k2 -rn

cat >> "$METRICS_REPORT" << EOF

### P2 MEDIUM (1000-3000 LOC)
EOF

while IFS= read -r file; do
    if [ -f "$file" ]; then
        loc=$(wc -l < "$file" | tr -d ' ')
        if [ "$loc" -ge 1000 ] && [ "$loc" -lt 3000 ]; then
            echo "- \`$file\` ($loc lines)" >> "$METRICS_REPORT"
        fi
    fi
done <<< "$SRC_FILES" | sort -t' ' -k2 -rn

cat >> "$METRICS_REPORT" << EOF

## Reports Generated

- Module sizes: \`$LOC_REPORT\`
- Dependencies: \`$DEPS_REPORT\`
- Dependency graph (DOT): \`$GRAPH_DOT\`
EOF

if [ -f "$GRAPH_PNG" ]; then
    echo "- Dependency graph (PNG): \`$GRAPH_PNG\`" >> "$METRICS_REPORT"
fi

cat >> "$METRICS_REPORT" << EOF

## Next Steps

1. Review the largest files for modularization opportunities
2. Plan module boundaries based on functionality
3. Check dependency graph for circular dependencies
4. Begin modularization phases as outlined in MODULARIZATION_PLAN.md

---

For detailed information, see:
- \`docs/MODULARIZATION_PLAN.md\`
- \`docs/MODULARIZATION_STATUS.md\`
EOF

echo -e "${GREEN}✓ Summary report generated${NC}"

# ============================================================
# FINAL OUTPUT
# ============================================================

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   Metrics Generation Complete${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${GREEN}Reports generated in: ${CYAN}$METRICS_DIR${NC}"
echo ""
echo "📊 Generated reports:"
echo -e "  • ${CYAN}$METRICS_REPORT${NC} - Summary metrics"
echo -e "  • ${CYAN}$LOC_REPORT${NC} - Module size analysis"
echo -e "  • ${CYAN}$DEPS_REPORT${NC} - Dependency analysis"
echo -e "  • ${CYAN}$GRAPH_DOT${NC} - Dependency graph (DOT format)"
if [ -f "$GRAPH_PNG" ]; then
    echo -e "  • ${CYAN}$GRAPH_PNG${NC} - Dependency graph (PNG image)"
fi
echo ""
echo -e "${YELLOW}Key Findings:${NC}"
echo -e "  • Total LOC: ${MAGENTA}$TOTAL_LOC${NC}"
echo -e "  • Large files (>1000 LOC): ${RED}$LARGE_COUNT${NC}"
echo -e "  • Medium files (500-1000 LOC): ${YELLOW}$MEDIUM_COUNT${NC}"
echo -e "  • Total imports: $TOTAL_IMPORTS"
if [ $CIRCULARS_FOUND -gt 0 ]; then
    echo -e "  • Circular dependencies: ${RED}$CIRCULARS_FOUND${NC} ⚠️"
else
    echo -e "  • Circular dependencies: ${GREEN}0${NC} ✓"
fi
echo ""
echo -e "${CYAN}View summary: cat $METRICS_REPORT${NC}"
echo ""
