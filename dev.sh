#!/bin/bash
# Geode Docker Development Environment Helper Script
# Simplifies common development tasks

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
COMPOSE_FILE="docker-compose.dev.yml"
DEV_CONTAINER="geode-dev"

# Helper functions
info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
}

warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Check if Docker is running
check_docker() {
    if ! docker info > /dev/null 2>&1; then
        error "Docker is not running. Please start Docker first."
        exit 1
    fi
}

# Show usage
usage() {
    cat << EOF
🚀 Geode Docker Development Environment

Usage: ./dev.sh [command] [options]

Commands:
  start           Start the development environment
  stop            Stop the development environment
  restart         Restart the development environment
  shell           Open a shell in the development container
  exec            Execute a command in the development container
  build           Build the geode project
  test            Run tests
  clean           Clean build artifacts
  logs            View logs from all services
  status          Show status of all services
  down            Stop and remove all containers and volumes
  rebuild         Rebuild the development Docker image
  monitoring      Start with monitoring stack (Prometheus + Grafana)

Examples:
  ./dev.sh start              # Start development environment
  ./dev.sh shell              # Open interactive shell
  ./dev.sh exec zig build     # Build the project
  ./dev.sh exec make test     # Run tests
  ./dev.sh logs -f geode-dev  # Follow logs
  ./dev.sh monitoring         # Start with monitoring

EOF
}

# Start development environment
cmd_start() {
    info "Starting Geode development environment..."
    check_docker

    # Check if image exists, build if not
    if ! docker images | grep -q "geode-dev"; then
        warning "Development image not found. Building..."
        cmd_rebuild
    fi

    docker-compose -f $COMPOSE_FILE up -d
    success "Development environment started!"
    info "Run './dev.sh shell' to enter the development container"
    info "Services available:"
    echo "  • Vault:      http://localhost:8200 (token: geode-dev-token)"
    echo "  • MinIO:      http://localhost:9001 (admin/geode-dev-secret-123)"
    echo "  • Redis:      localhost:6379 (password: geode-dev-password)"
}

# Stop development environment
cmd_stop() {
    info "Stopping Geode development environment..."
    docker-compose -f $COMPOSE_FILE stop
    success "Development environment stopped"
}

# Restart development environment
cmd_restart() {
    info "Restarting Geode development environment..."
    docker-compose -f $COMPOSE_FILE restart
    success "Development environment restarted"
}

# Open shell in development container
cmd_shell() {
    check_docker
    if ! docker ps | grep -q $DEV_CONTAINER; then
        error "Development container is not running. Start it with './dev.sh start'"
        exit 1
    fi

    info "Opening shell in development container..."
    docker exec -it $DEV_CONTAINER /bin/bash
}

# Execute command in development container
cmd_exec() {
    check_docker
    if ! docker ps | grep -q $DEV_CONTAINER; then
        error "Development container is not running. Start it with './dev.sh start'"
        exit 1
    fi

    docker exec -it $DEV_CONTAINER "$@"
}

# Build the project
cmd_build() {
    info "Building Geode..."
    cmd_exec zig build -Doptimize=ReleaseSafe
    success "Build completed successfully"
}

# Run tests
cmd_test() {
    info "Running tests..."
    cmd_exec make test
}

# Clean build artifacts
cmd_clean() {
    info "Cleaning build artifacts..."
    cmd_exec rm -rf zig-out zig-cache .zig-cache
    success "Build artifacts cleaned"
}

# View logs
cmd_logs() {
    docker-compose -f $COMPOSE_FILE logs "$@"
}

# Show status
cmd_status() {
    info "Development environment status:"
    docker-compose -f $COMPOSE_FILE ps
}

# Stop and remove everything
cmd_down() {
    warning "This will stop and remove all containers and volumes"
    read -p "Are you sure? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        info "Stopping and removing development environment..."
        docker-compose -f $COMPOSE_FILE down -v
        success "Development environment removed"
    else
        info "Cancelled"
    fi
}

# Rebuild development image
cmd_rebuild() {
    info "Rebuilding development Docker image..."
    check_docker
    docker-compose -f $COMPOSE_FILE build --no-cache geode-dev
    success "Development image rebuilt successfully"
}

# Start with monitoring
cmd_monitoring() {
    info "Starting development environment with monitoring stack..."
    check_docker
    docker-compose -f $COMPOSE_FILE --profile monitoring up -d
    success "Development environment with monitoring started!"
    info "Additional services:"
    echo "  • Prometheus: http://localhost:9090"
    echo "  • Grafana:    http://localhost:3000 (admin/geode-dev-password)"
}

# Main command router
case "${1:-}" in
    start)
        cmd_start
        ;;
    stop)
        cmd_stop
        ;;
    restart)
        cmd_restart
        ;;
    shell)
        cmd_shell
        ;;
    exec)
        shift
        cmd_exec "$@"
        ;;
    build)
        cmd_build
        ;;
    test)
        cmd_test
        ;;
    clean)
        cmd_clean
        ;;
    logs)
        shift
        cmd_logs "$@"
        ;;
    status)
        cmd_status
        ;;
    down)
        cmd_down
        ;;
    rebuild)
        cmd_rebuild
        ;;
    monitoring)
        cmd_monitoring
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
