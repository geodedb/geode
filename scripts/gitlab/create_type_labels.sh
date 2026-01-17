#!/bin/bash
# CANARY: REQ=REQ-GITLAB-LABELS-001; FEATURE="GitLab Label Taxonomy"; ASPECT=Tooling; STATUS=EXEMPT; OWNER=tooling; UPDATED=2026-01-14
# GAP-0164: Create type:: labels in GitLab for consistent issue classification
#
# Usage: ./create_type_labels.sh
# Requires: GITLAB_TOKEN environment variable with api scope
# Project: devnw/geode/geode

set -e

PROJECT_ID="devnw%2Fgeode%2Fgeode"
GITLAB_API_BASE="https://gitlab.com/api/v4"

if [ -z "$GITLAB_TOKEN" ]; then
    echo "Error: GITLAB_TOKEN environment variable not set"
    echo "Generate a token at: https://gitlab.com/-/user_settings/personal_access_tokens"
    echo "Required scope: api"
    exit 1
fi

# Function to create a label if it doesn't exist
create_label() {
    local name="$1"
    local color="$2"
    local description="$3"

    echo "Creating label: $name"

    # Check if label exists
    existing=$(curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "$GITLAB_API_BASE/projects/$PROJECT_ID/labels?search=$name" | grep -c "\"name\":\"$name\"" || true)

    if [ "$existing" -gt 0 ]; then
        echo "  Label '$name' already exists, skipping"
        return 0
    fi

    # Create the label
    response=$(curl -s -w "%{http_code}" -o /tmp/label_response.json \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "{\"name\":\"$name\",\"color\":\"$color\",\"description\":\"$description\"}" \
        "$GITLAB_API_BASE/projects/$PROJECT_ID/labels")

    if [ "$response" = "201" ]; then
        echo "  Created: $name"
    else
        echo "  Failed to create: $name (HTTP $response)"
        cat /tmp/label_response.json
        return 1
    fi
}

echo "=== Creating type:: labels for Geode project ==="
echo ""

# Type labels with distinct colors
create_label "type::feature"     "#428bca" "New feature or capability"
create_label "type::bug"         "#d9534f" "Something isn't working correctly"
create_label "type::enhancement" "#5cb85c" "Improvement to existing functionality"
create_label "type::security"    "#f0ad4e" "Security-related issue or fix"
create_label "type::docs"        "#5bc0de" "Documentation improvements"
create_label "type::test"        "#999999" "Test-related changes"
create_label "type::refactor"    "#9b59b6" "Code refactoring"
create_label "type::ci-cd"       "#1abc9c" "CI/CD pipeline changes"
create_label "type::performance" "#e74c3c" "Performance-related issue"

echo ""
echo "=== Label creation complete ==="
echo ""
echo "To verify, run:"
echo "  glab api 'projects/$PROJECT_ID/labels?search=type::'"
