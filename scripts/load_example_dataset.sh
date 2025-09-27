#!/bin/bash
# Load the example social network dataset into Geode
# Usage: ./scripts/load_example_dataset.sh [--host HOST] [--port PORT]

set -e

# Default values
HOST="127.0.0.1"
PORT="8443"
DATA_DIR="./data"
GEODEC="./zig-out/bin/geodec"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --host)
            HOST="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --data-dir)
            DATA_DIR="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--host HOST] [--port PORT] [--data-dir DIR]"
            echo "  --host      Geode server host (default: 127.0.0.1)"
            echo "  --port      Geode server port (default: 8443)"
            echo "  --data-dir  Data directory path (default: ./data)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Geode Example Dataset Loader ===${NC}"
echo "Server: quic://${HOST}:${PORT}"
echo "Data directory: ${DATA_DIR}"
echo ""

# Check if geodec exists
if [ ! -f "$GEODEC" ]; then
    echo -e "${RED}Error: geodec not found at ${GEODEC}${NC}"
    echo "Please build Geode first: zig build -Drelease-safe"
    exit 1
fi

# Check if migrations directory exists
if [ ! -d "migrations" ]; then
    echo -e "${RED}Error: migrations directory not found${NC}"
    echo "Please run this script from the Geode root directory"
    exit 1
fi

# Test connection
echo -e "${YELLOW}Testing connection to Geode server...${NC}"
if ! $GEODEC --host "$HOST" --port "$PORT" "RETURN 1 AS test" > /dev/null 2>&1; then
    echo -e "${RED}Error: Cannot connect to Geode server${NC}"
    echo "Is the server running? Start it with:"
    echo "  ./zig-out/bin/geoded --data_dir ${DATA_DIR} --log_json"
    exit 1
fi
echo -e "${GREEN}✓ Connection successful${NC}"

# Function to run a migration file
run_migration() {
    local file=$1
    local name=$(basename "$file" .gql)
    
    echo -e "${YELLOW}Loading ${name}...${NC}"
    
    if $GEODEC --host "$HOST" --port "$PORT" < "$file" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ ${name} loaded successfully${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to load ${name}${NC}"
        return 1
    fi
}

# Load migrations in order
echo ""
echo -e "${GREEN}Loading dataset migrations:${NC}"

MIGRATIONS=(
    "migrations/001_social_network_schema.gql"
    "migrations/002_social_network_data.gql"
    "migrations/003_social_network_relationships.gql"
    "migrations/004_social_network_events_products.gql"
)

for migration in "${MIGRATIONS[@]}"; do
    if [ -f "$migration" ]; then
        if ! run_migration "$migration"; then
            echo -e "${RED}Migration failed. Stopping.${NC}"
            exit 1
        fi
    else
        echo -e "${YELLOW}Warning: Migration file not found: ${migration}${NC}"
    fi
done

echo ""
echo -e "${GREEN}Verifying dataset:${NC}"

# Count nodes
NODE_COUNT=$($GEODEC --host "$HOST" --port "$PORT" "MATCH (n) RETURN count(n) AS count" 2>/dev/null | grep -o '"count":[0-9]*' | cut -d: -f2)
echo "  Nodes created: ${NODE_COUNT:-0}"

# Count edges
EDGE_COUNT=$($GEODEC --host "$HOST" --port "$PORT" "MATCH ()-[r]->() RETURN count(r) AS count" 2>/dev/null | grep -o '"count":[0-9]*' | cut -d: -f2)
echo "  Edges created: ${EDGE_COUNT:-0}"

# Count by type
echo ""
echo -e "${GREEN}Node distribution:${NC}"
$GEODEC --host "$HOST" --port "$PORT" "MATCH (n) RETURN labels(n)[0] AS label, count(n) AS count ORDER BY count DESC" 2>/dev/null | \
    grep -o '"label":"[^"]*","count":[0-9]*' | \
    sed 's/"label":"\([^"]*\)","count":\([0-9]*\)/  \1: \2/' || echo "  Unable to get node distribution"

echo ""
echo -e "${GREEN}=== Dataset loaded successfully! ===${NC}"
echo ""
echo "Try these example queries:"
echo "  # Find top influencers:"
echo "  $GEODEC \"MATCH (u:User) WHERE u.follower_count > 1000 RETURN u.username, u.follower_count ORDER BY u.follower_count DESC LIMIT 5\""
echo ""
echo "  # Network security analysis:"
echo "  $GEODEC \"MATCH (d:Device)-[:CONNECTED_FROM]->(u:User) WHERE ip_is_private(d.ip_address) RETURN u.username, d.ip_address, d.trust_score\""
echo ""
echo "  # Geographic search (events near SF):"
echo "  $GEODEC \"MATCH (e:Event) WHERE distance_haversine(e.location, LatLon(37.7749, -122.4194)) < 100000 RETURN e.title, e.venue\""
echo ""
echo "For more examples, see migrations/README.md"