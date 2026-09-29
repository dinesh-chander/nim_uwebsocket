#!/bin/bash
# Build bundled uSockets sources for nim_usockets.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USOCKETS_DIR="$SCRIPT_DIR/usockets"

echo "Building bundled uSockets..."

if [ ! -d "$USOCKETS_DIR/src" ]; then
    echo "Error: expected bundled sources at $USOCKETS_DIR"
    exit 1
fi

cd "$USOCKETS_DIR"

# Detect OS and set appropriate flags
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS - use GCD (Grand Central Dispatch) for best performance
    echo "Detected macOS - building with GCD support..."
    make clean
    WITH_GCD=1 make
    LINK_FLAGS="-framework CoreFoundation"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux - use default epoll
    echo "Detected Linux - building with epoll support..."
    make clean
    make
    LINK_FLAGS="-lpthread -ldl"
else
    echo "Warning: Unknown OS '$OSTYPE', attempting default build..."
    make clean
    make
    LINK_FLAGS=""
fi

echo ""
echo "Build complete!"
echo ""
echo "Library location: $USOCKETS_DIR/uSockets.a"
echo ""

if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "To compile your Nim application on macOS, use:"
    echo "  nim c -d:release --passL:\"$USOCKETS_DIR/uSockets.a -framework CoreFoundation\" your_app.nim"
else
    echo "To compile your Nim application, use:"
    echo "  nim c -d:release --passL:\"$USOCKETS_DIR/uSockets.a $LINK_FLAGS\" your_app.nim"
fi
