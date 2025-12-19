#!/bin/bash
# Simple build script for WinAPI Remoting Driver
# Can be run from WSL or any Linux environment that can access Windows

set -e

echo "🔨 Building WinAPI Remoting Driver..."
echo "=================================="

# Check if we're in WSL or have access to Windows
if command -v cmd.exe >/dev/null 2>&1; then
    echo "✅ Windows access detected (WSL/SSH)"

    # Navigate to the driver directory
    DRIVER_DIR="host/driver/winApiRemoting"

    if [ ! -f "$DRIVER_DIR/build_driver_manual.cmd" ]; then
        echo "❌ Error: build_driver_manual.cmd not found"
        echo "   Please run this script from the project root directory"
        exit 1
    fi

    echo "📂 Entering driver directory: $DRIVER_DIR"
    cd "$DRIVER_DIR"

    # Run the Windows build script (it will handle environment setup)
    echo "🚀 Starting build..."
    echo ""

    cmd.exe /c build_driver_manual.cmd

    BUILD_EXIT_CODE=$?

    echo ""
    if [ $BUILD_EXIT_CODE -eq 0 ]; then
        if [ -f "x64/Debug/winApiRemoting.sys" ]; then
            echo "🎉 BUILD SUCCESSFUL!"
            echo "📦 Driver created: $(pwd)/x64/Debug/winApiRemoting.sys"
            echo "📏 Size: $(ls -lh x64/Debug/winApiRemoting.sys | awk '{print $5}')"
            echo ""
            echo "🎯 Next steps:"
            echo "   • Quick Install (Windows): install_driver.cmd (run as Administrator)"
            echo "   • Manual Install: pnputil /add-driver winApiRemoting.inf /install"
            echo "   • Check Status: sc query winApiRemoting"
            echo "   • Debug Signing Issues: debug_cert_signing.ps1 (run as Administrator)"
            echo "   • Test: Connect Linux guest via VMBus"
        else
            echo "❌ Build reported success but driver file not found"
            exit 1
        fi
    else
        echo "❌ BUILD FAILED (exit code: $BUILD_EXIT_CODE)"
        echo "💡 Try running from Windows Developer Command Prompt for more details"
        exit $BUILD_EXIT_CODE
    fi

elif [ -d "/mnt/c" ]; then
    echo "✅ WSL detected but cmd.exe not available"
    echo "🔄 Trying alternative WSL approach..."

    # Alternative WSL approach using /mnt/c
    DRIVER_DIR="/mnt/c/Users/$(whoami)/winApiRmt/host/driver/winApiRemoting"

    if [ ! -d "$DRIVER_DIR" ]; then
        # Try common locations
        for base_dir in /mnt/c/Users/*/; do
            if [ -d "${base_dir}winApiRmt/host/driver/winApiRemoting" ]; then
                DRIVER_DIR="${base_dir}winApiRmt/host/driver/winApiRemoting"
                break
            fi
        done
    fi

    if [ ! -d "$DRIVER_DIR" ]; then
        echo "❌ Error: Cannot find winApiRmt project in WSL"
        echo "   Expected: $DRIVER_DIR"
        exit 1
    fi

    echo "📂 Found project at: $DRIVER_DIR"
    cd "$DRIVER_DIR"

    # Use PowerShell through WSL
    powershell.exe -Command "& { Set-Location '$DRIVER_DIR'; & cmd /c 'build_driver_manual.cmd' }"

else
    echo "❌ Error: No Windows access detected"
    echo "   This script requires WSL, SSH to Windows, or Windows environment"
    exit 1
fi

echo ""
echo "✨ Build script completed"
