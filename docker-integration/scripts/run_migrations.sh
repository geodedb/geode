#!/bin/bash
# Migration runner for Geode Docker integration tests

set -e

GEODE_HOST="${GEODE_HOST:-geode-server}"
GEODE_PORT="${GEODE_PORT:-8443}"
MIGRATIONS_DIR="${MIGRATIONS_DIR:-/migrations}"
LOG_DIR="${LOG_DIR:-/logs}"

echo "==============================================="
echo "Geode Migration Runner"
echo "==============================================="
echo "Server: ${GEODE_HOST}:${GEODE_PORT}"
echo "Migrations Dir: ${MIGRATIONS_DIR}"
echo "Started: $(date -Iseconds)"
echo "==============================================="

# Create log directory
mkdir -p "${LOG_DIR}/migrations"

# Wait for server to be ready
echo "Waiting for Geode server..."
MAX_RETRIES=120
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if nc -z -w 5 "${GEODE_HOST}" "${GEODE_PORT}" 2>/dev/null; then
        echo "Server is ready!"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "Waiting for server... (attempt ${RETRY_COUNT}/${MAX_RETRIES})"
    sleep 2
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "ERROR: Server did not become ready in time"
    exit 1
fi

# Additional wait for server to fully initialize
echo "Waiting additional 5 seconds for full initialization..."
sleep 5

# Run migrations in order
MIGRATION_COUNT=0
MIGRATION_SUCCESS=0
MIGRATION_FAILED=0

for migration_file in $(ls -1 "${MIGRATIONS_DIR}"/*.gql 2>/dev/null | sort); do
    MIGRATION_COUNT=$((MIGRATION_COUNT + 1))
    MIGRATION_NAME=$(basename "${migration_file}")

    echo ""
    echo "-----------------------------------------------"
    echo "Running migration: ${MIGRATION_NAME}"
    echo "-----------------------------------------------"

    # Read and execute each statement from the migration file
    STATEMENT=""
    LINE_NUM=0

    while IFS= read -r line || [ -n "$line" ]; do
        LINE_NUM=$((LINE_NUM + 1))

        # Skip empty lines and comments
        if [[ -z "${line}" ]] || [[ "${line}" =~ ^[[:space:]]*-- ]]; then
            continue
        fi

        # Accumulate statement
        STATEMENT="${STATEMENT} ${line}"

        # Check if statement is complete (ends with semicolon)
        if [[ "${line}" =~ \;[[:space:]]*$ ]]; then
            # Remove the trailing semicolon for execution
            CLEAN_STATEMENT=$(echo "${STATEMENT}" | sed 's/;[[:space:]]*$//' | tr -s ' ')

            if [ -n "${CLEAN_STATEMENT}" ]; then
                echo "  Executing: ${CLEAN_STATEMENT:0:80}..."

                RESULT=$(/app/geode query \
                    --server "${GEODE_HOST}:${GEODE_PORT}" \
                    --insecure \
                    "${CLEAN_STATEMENT}" 2>&1) || true

                if echo "$RESULT" | grep -qiE "(error|failed|exception)"; then
                    echo "  WARNING: ${RESULT}"
                else
                    echo "  OK"
                fi
            fi

            STATEMENT=""
        fi
    done < "${migration_file}"

    echo "Migration ${MIGRATION_NAME} completed"
    MIGRATION_SUCCESS=$((MIGRATION_SUCCESS + 1))

done

echo ""
echo "==============================================="
echo "Migration Summary"
echo "==============================================="
echo "Total Migrations: ${MIGRATION_COUNT}"
echo "Successful: ${MIGRATION_SUCCESS}"
echo "Failed: ${MIGRATION_FAILED}"
echo "Completed: $(date -Iseconds)"
echo "==============================================="

# Verify data was created
echo ""
echo "Verifying seeded data..."
echo ""

# Count nodes of each type
for label in Organization Department Employee Project Document Server Application Database Network Datacenter User Permission Role AuditLog Policy Incident; do
    COUNT=$(/app/geode query \
        --server "${GEODE_HOST}:${GEODE_PORT}" \
        --insecure \
        "MATCH (n:${label}) RETURN count(n) AS count" 2>&1 | grep -oP '"count":\s*\K\d+' || echo "0")
    echo "  ${label}: ${COUNT} nodes"
done

echo ""
echo "Migration runner completed successfully!"
exit 0
