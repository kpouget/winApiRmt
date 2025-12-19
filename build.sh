#!/bin/bash
# Build script for WinAPI Remoting WSL2 Implementation
# Builds both Windows service and WSL2 client components

set -e

echo "🔨 Building WinAPI Remoting for WSL2..."
echo "======================================"

# Build WSL2 client
echo "📦 Building WSL2 client components..."
cd guest/client/

if [ ! -f "Makefile" ]; then
    echo "❌ Error: Makefile not found in guest/client/"
    exit 1
fi

make clean
make

if [ -f "test_client" ]; then
    echo "✅ WSL2 client built successfully"
    echo "📦 Client binary: $(pwd)/test_client"
    echo "📦 Library: $(pwd)/libwinapi.a"
    echo "📏 Size: $(ls -lh test_client | awk '{print $5}')"
else
    echo "❌ WSL2 client build failed"
    exit 1
fi

cd ../..

# Build Windows service (if on Windows or WSL with Windows access)
if command -v cmd.exe >/dev/null 2>&1; then
    echo ""
    echo "📦 Building Windows service..."

    if [ -d "host/service" ]; then
        cd host/service/

        # Check for build script
        if [ -f "build.cmd" ]; then
            cmd.exe /c build.cmd
            SERVICE_EXIT_CODE=$?

            if [ $SERVICE_EXIT_CODE -eq 0 ]; then
                echo "✅ Windows service built successfully"
            else
                echo "⚠️  Windows service build failed (exit code: $SERVICE_EXIT_CODE)"
            fi
        else
            echo "⚠️  Windows service build script not found"
            echo "   Create host/service/build.cmd to build the service"
        fi

        cd ../..
    else
        echo "⚠️  Windows service directory not found"
    fi
else
    echo ""
    echo "⚠️  Windows build environment not detected"
    echo "   Windows service must be built separately on Windows"
fi

echo ""
echo "🎯 Next steps:"
echo "   • Install Windows service: host/service/install.cmd (as Administrator)"
echo "   • Test WSL2 client: guest/client/test_client"
echo "   • Check communication: Look for Hyper-V socket connection"
echo ""
echo "✨ Build completed!"
