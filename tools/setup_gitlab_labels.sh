#!/usr/bin/env bash
set -euo pipefail
# CANARY: REQ=REQ-LABEL-TAXONOMY-001; FEATURE="GitLab Label Setup"; ASPECT=Core; STATUS=IMPL; OWNER=ci; UPDATED=2026-01-14
# GAP-0164: Script to create required type:: labels for gap analysis taxonomy
#
# Usage: ./tools/setup_gitlab_labels.sh
# Requires: glab CLI authenticated with project access

set -e

PROJECT="devnw/codepros/geode"
LABEL_PREFIX="type::"

# Required labels per gap analysis labeling rules
LABELS=(
    "type::feature:Feature addition or enhancement:#34a853"
    "type::bug:Bug fix:#ea4335"
    "type::enhancement:Improvement to existing functionality:#fbbc04"
    "type::security:Security-related change:#8e24aa"
    "type::docs:Documentation update:#4285f4"
    "type::test:Test addition or fix:#ff6d01"
    "type::ci:CI/CD pipeline change:#00897b"
    "type::refactor:Code refactoring:#607d8b"
)

echo "=== Setting up GitLab labels for $PROJECT ==="
echo "GAP-0164: Creating type:: label taxonomy"
echo

# Check for glab authentication
if ! glab auth status &>/dev/null; then
    echo "Error: Not authenticated with glab CLI"
    echo "Run 'glab auth login' first"
    exit 1
fi

# Create each label
for label_spec in "${LABELS[@]}"; do
    IFS=':' read -r name description color <<< "$label_spec"
    label_name="${LABEL_PREFIX}${name#type::}"

    echo -n "Creating label '$label_name'... "

    # Check if label exists
    if glab api "projects/${PROJECT//\//%2F}/labels?search=${label_name}" 2>/dev/null | grep -q "\"name\":\"${label_name}\""; then
        echo "already exists"
        continue
    fi

    # Create the label
    if glab api --method POST "projects/${PROJECT//\//%2F}/labels" \
        --field "name=${label_name}" \
        --field "description=${description}" \
        --field "color=${color}" &>/dev/null; then
        echo "created"
    else
        echo "failed (may need project maintainer access)"
    fi
done

echo
echo "=== Label setup complete ==="
echo "Verify at: https://gitlab.com/${PROJECT}/-/labels"
