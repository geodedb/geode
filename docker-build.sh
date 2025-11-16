#!/bin/bash
# Docker build script for Geode with OpenSSL FIPS and MsQUIC support
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse arguments
STAGE="${1:-all}"
TAG="${2:-geode:latest}"
PLATFORM="${3:-}"

echo -e "${GREEN}Building Geode Docker image with OpenSSL FIPS and MsQUIC${NC}"
echo "Stage: $STAGE"
echo "Tag: $TAG"
echo ""

# Build based on stage
if [ "$STAGE" = "openssl" ]; then
    echo -e "${YELLOW}Building OpenSSL FIPS stage only...${NC}"
    docker build --target openssl-builder -t geode:openssl-fips -f Dockerfile .
elif [ "$STAGE" = "msquic" ]; then
    echo -e "${YELLOW}Building MsQUIC stage...${NC}"
    docker build --target msquic-builder -t geode:msquic -f Dockerfile .
elif [ "$STAGE" = "builder" ]; then
    echo -e "${YELLOW}Building Geode builder stage...${NC}"
    PLATFORM_ARG=""
    if [ -n "$PLATFORM" ]; then
        PLATFORM_ARG="--platform $PLATFORM"
    fi
    docker build $PLATFORM_ARG --target builder -t geode:builder -f Dockerfile .
elif [ "$STAGE" = "all" ] || [ "$STAGE" = "runtime" ]; then
    echo -e "${YELLOW}Building complete Geode runtime image...${NC}"
    PLATFORM_ARG=""
    if [ -n "$PLATFORM" ]; then
        PLATFORM_ARG="--platform $PLATFORM"
    fi
    docker build $PLATFORM_ARG -t "$TAG" -f Dockerfile .
else
    echo -e "${RED}Unknown stage: $STAGE${NC}"
    echo "Usage: $0 [openssl|msquic|builder|runtime|all] [tag] [platform]"
    echo "Examples:"
    echo "  $0 openssl                    # Build OpenSSL FIPS stage only"
    echo "  $0 msquic                     # Build MsQUIC stage"
    echo "  $0 builder                    # Build up to Geode builder"
    echo "  $0 all geode:v1.0             # Build complete image with custom tag"
    echo "  $0 all geode:arm64 linux/arm64 # Build for specific platform"
    exit 1
fi

echo -e "${GREEN}✓ Build complete!${NC}"

# Show image info
if [ "$STAGE" = "all" ] || [ "$STAGE" = "runtime" ]; then
    echo ""
    echo "Image information:"
    docker images "$TAG" | head -2
    echo ""
    echo "To run the image:"
    echo "  docker run -p 8443:8443/udp $TAG"
    echo ""
    echo "To run with custom data directory:"
    echo "  docker run -p 8443:8443/udp -v ./data:/data $TAG --data-dir /data"
fi
