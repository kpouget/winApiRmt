#!/bin/bash
# Test build script for the entire project

set -e

echo "Windows API Remoting Framework - Build Test"
echo "==========================================="

# Check if we're on Linux (guest components)
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "Building Linux guest components..."

    # Build kernel driver
    echo "Building VMBus client driver..."
    cd guest/driver
    make clean
    make
    echo "✓ VMBus client driver built successfully"
    cd ../..

    # Build userspace library and test client
    echo "Building userspace library and test client..."
    cd guest/userspace
    make clean
    make
    echo "✓ Userspace components built successfully"
    cd ../..

    echo ""
    echo "Linux guest components built successfully!"
    echo ""
    echo "Next steps:"
    echo "1. Load the kernel driver: sudo insmod guest/driver/winapi_client.ko"
    echo "2. Run tests: ./guest/userspace/test_client"

elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    echo "Windows host components require Windows Driver Kit (WDK)"
    echo "Please build using Visual Studio or WDK command line tools"
    echo ""
    echo "Host driver files:"
    echo "- host/driver/vmbus_provider.c"
    echo "- host/driver/api_handlers.c"
    echo "- host/inf/winapi_remoting.inf"

else
    echo "Unknown OS type: $OSTYPE"
    echo "This script supports Linux guest builds only"
    exit 1
fi

echo ""
echo "Build test completed successfully!"