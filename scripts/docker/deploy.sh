#!/bin/bash
# Deployment script for Geode Docker environments

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$PROJECT_ROOT"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse command line arguments
MODE="singleton"
ACTION="up"
BUILD_FRESH=false
MONITORING=false

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -m, --mode MODE        Deployment mode: singleton|distributed (default: singleton)"
    echo "  -a, --action ACTION    Action: up|down|restart|status|logs (default: up)"
    echo "  -b, --build            Force fresh build"
    echo "  -M, --monitoring       Include monitoring stack (Prometheus + Grafana)"
    echo "  -h, --help             Show this help message"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--mode)
            MODE="$2"
            shift 2
            ;;
        -a|--action)
            ACTION="$2"
            shift 2
            ;;
        -b|--build)
            BUILD_FRESH=true
            shift
            ;;
        -M|--monitoring)
            MONITORING=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate mode
if [[ "$MODE" != "singleton" && "$MODE" != "distributed" ]]; then
    echo -e "${RED}Invalid mode: $MODE${NC}"
    usage
fi

# Select compose file based on mode
if [[ "$MODE" == "singleton" ]]; then
    COMPOSE_FILE="docker-compose.yml"
else
    COMPOSE_FILE="docker-compose.distributed.yml"
fi

# Add monitoring profile if requested
COMPOSE_PROFILES=""
if [[ "$MONITORING" == true ]]; then
    COMPOSE_PROFILES="--profile monitoring"
fi

# Function to check if containers are healthy
check_health() {
    local service=$1
    local max_wait=60
    local elapsed=0
    
    echo -n "Waiting for $service to be healthy..."
    while [[ $elapsed -lt $max_wait ]]; do
        if docker-compose -f "$COMPOSE_FILE" ps "$service" 2>/dev/null | grep -q "healthy"; then
            echo -e " ${GREEN}healthy${NC}"
            return 0
        fi
        echo -n "."
        sleep 2
        elapsed=$((elapsed + 2))
    done
    echo -e " ${RED}timeout${NC}"
    return 1
}

# Generate certificates if they don't exist
generate_certs() {
    if [[ ! -f "$PROJECT_ROOT/certs/server.crt" ]]; then
        echo -e "${YELLOW}Generating TLS certificates...${NC}"
        make cert-gen || {
            echo -e "${YELLOW}cert_gen not found, using openssl...${NC}"
            mkdir -p "$PROJECT_ROOT/certs"
            openssl req -x509 -newkey rsa:4096 -keyout "$PROJECT_ROOT/certs/server.key" \
                -out "$PROJECT_ROOT/certs/server.crt" -days 365 -nodes \
                -subj "/C=US/ST=State/L=City/O=Organization/CN=localhost"
        }
    fi
}

# Execute action
case $ACTION in
    up)
        echo -e "${GREEN}Starting Geode in $MODE mode...${NC}"
        
        # Generate certs if needed
        generate_certs
        
        # Build if requested
        if [[ "$BUILD_FRESH" == true ]]; then
            echo -e "${YELLOW}Building fresh images...${NC}"
            docker-compose -f "$COMPOSE_FILE" build --no-cache
        fi
        
        # Start containers
        docker-compose -f "$COMPOSE_FILE" $COMPOSE_PROFILES up -d
        
        # Check health
        if [[ "$MODE" == "singleton" ]]; then
            check_health "geode"
        else
            check_health "geode-leader"
            check_health "geode-follower-1"
            check_health "geode-follower-2"
        fi
        
        echo -e "${GREEN}Geode is running in $MODE mode${NC}"
        
        # Display access information
        echo ""
        echo "Access points:"
        if [[ "$MODE" == "singleton" ]]; then
            echo "  - QUIC: localhost:7567"
            echo "  - Metrics: http://localhost:9090"
        else
            echo "  - Leader QUIC: localhost:7567"
            echo "  - Follower-1 QUIC: localhost:7569"
            echo "  - Follower-2 QUIC: localhost:7571"
            echo "  - Load Balancer: QUIC-aware balancer required (see docs)"
        fi
        
        if [[ "$MONITORING" == true ]]; then
            echo "  - Prometheus: http://localhost:9091"
            echo "  - Grafana: http://localhost:3000 (admin/admin)"
        fi
        ;;
        
    down)
        echo -e "${YELLOW}Stopping Geode...${NC}"
        docker-compose -f "$COMPOSE_FILE" $COMPOSE_PROFILES down
        echo -e "${GREEN}Geode stopped${NC}"
        ;;
        
    restart)
        echo -e "${YELLOW}Restarting Geode...${NC}"
        docker-compose -f "$COMPOSE_FILE" $COMPOSE_PROFILES restart
        echo -e "${GREEN}Geode restarted${NC}"
        ;;
        
    status)
        echo -e "${YELLOW}Geode status:${NC}"
        docker-compose -f "$COMPOSE_FILE" ps
        ;;
        
    logs)
        docker-compose -f "$COMPOSE_FILE" logs -f
        ;;
        
    *)
        echo -e "${RED}Invalid action: $ACTION${NC}"
        usage
        ;;
esac