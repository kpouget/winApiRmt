#!/bin/bash
# Prepare WSL2 Kernel Sources for Module Building
# Automatically downloads the correct WSL2 kernel version and configures it
# This script is idempotent - safe to run multiple times

set -e

echo "=========================================="
echo "  WSL2 Kernel Source Preparation"
echo "=========================================="
echo

# Get the kernel version without extra suffixes
KERNEL_BASE_VERSION=$(uname -r | cut -d- -f1)
WSL2_TAG="linux-msft-wsl-${KERNEL_BASE_VERSION}"
LIVE_KERNEL_VERSION=$(uname -r)

echo "Current kernel: ${LIVE_KERNEL_VERSION}"
echo "Base version: ${KERNEL_BASE_VERSION}"
echo "Target tag: ${WSL2_TAG}"
echo

# Check if we're running in WSL2
if ! uname -r | grep -q "WSL2"; then
    echo "❌ ERROR: This script is designed for WSL2 environments only!"
    echo "   Current kernel: ${LIVE_KERNEL_VERSION}"
    echo "   Expected: A kernel version containing 'WSL2'"
    echo ""
    echo "💡 This script downloads Microsoft's WSL2 kernel sources."
    echo "   For regular Linux distributions, use distribution-specific kernel packages:"
    echo "   • Ubuntu/Debian: sudo apt install linux-headers-\$(uname -r)"
    echo "   • CentOS/RHEL: sudo yum install kernel-devel kernel-headers"
    echo "   • Fedora: sudo dnf install kernel-devel kernel-headers"
    exit 1
fi

echo "✅ WSL2 environment detected"

# Check and install required packages
echo "🔧 Checking required packages..."
REQUIRED_PACKAGES=("make" "bc" "git" "gcc" "flex" "bison" "elfutils-libelf-devel" "awk")
MISSING_PACKAGES=()

for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! command -v "$pkg" >/dev/null 2>&1 && ! rpm -q "$pkg" >/dev/null 2>&1; then
        MISSING_PACKAGES+=("$pkg")
    fi
done

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    echo "📦 Installing missing packages: ${MISSING_PACKAGES[*]}"
    sudo dnf install -y "${MISSING_PACKAGES[@]}"
    if [ $? -ne 0 ]; then
        echo "❌ ERROR: Failed to install required packages"
        echo "   Please install manually: sudo dnf install -y ${MISSING_PACKAGES[*]}"
        exit 1
    fi
    echo "✅ Required packages installed successfully"
else
    echo "✅ All required packages are already installed"
fi

# Check if we have access to live kernel config
if [ ! -f /proc/config.gz ]; then
    echo "❌ ERROR: /proc/config.gz not found!"
    echo "   This script requires access to the live kernel configuration."
    echo "   Make sure CONFIG_IKCONFIG_PROC=y is enabled in your kernel."
    exit 1
fi

echo "✅ Live kernel config available"
echo

# Function to check if kernel setup is already complete
check_kernel_setup() {
    # Check if kernel directory exists
    if [ ! -d "kernel" ]; then
        return 1
    fi

    cd kernel

    # Check if it's a git repository
    if [ ! -d ".git" ]; then
        echo "⚠️  Kernel directory exists but is not a git repository"
        cd ..
        return 1
    fi

    # Check if we're on the right tag/commit
    CURRENT_TAG=$(git describe --tags --exact-match 2>/dev/null || echo "")
    if [ "${CURRENT_TAG}" = "${WSL2_TAG}" ]; then
        echo "✅ Kernel sources already at correct tag: ${WSL2_TAG}"
    else
        echo "⚠️  Kernel sources at different version: ${CURRENT_TAG:-"unknown"}"
        cd ..
        return 1
    fi

    # Check if .config exists and is newer than /proc/config.gz
    if [ ! -f ".config" ]; then
        echo "⚠️  No .config file found"
        cd ..
        return 1
    fi

    # Check if config is up to date (compare timestamps)
    if [ ".config" -ot "/proc/config.gz" ]; then
        echo "⚠️  Config file is older than live kernel config"
        cd ..
        return 1
    fi

    # Check if build environment is prepared
    if [ ! -f "scripts/mod/modpost" ] || [ ! -f "Module.symvers" ]; then
        echo "⚠️  Build environment not prepared"
        cd ..
        return 1
    fi

    # Check for completion marker
    if [ ! -f ".kernel_setup_complete" ]; then
        echo "⚠️  Setup not marked as complete"
        cd ..
        return 1
    fi

    cd ..
    echo "✅ Kernel setup is already complete and up to date"
    return 0
}

# Check if setup is already complete
if check_kernel_setup; then
    echo
    echo "🎯 Kernel environment already properly configured!"
    echo "   To force refresh, remove the 'kernel' directory and run again"
    echo "   Or run: rm -rf kernel && ./prepare_kernel.sh"
    echo
    echo "✨ Ready to build kernel modules!"
    echo "   cd driver && make"
    exit 0
fi

# Remove any existing incomplete kernel directory
if [ -d "kernel" ]; then
    echo "🗑️  Removing incomplete kernel directory..."
    rm -rf kernel
fi

# Clone WSL2 kernel repository with specific tag
echo "📥 Cloning WSL2 kernel repository (tag: ${WSL2_TAG})..."
if git clone --depth 1 --branch "${WSL2_TAG}" https://github.com/microsoft/WSL2-Linux-Kernel.git kernel; then
    echo "✅ Successfully cloned WSL2 kernel sources"
else
    echo "❌ Failed to clone tag ${WSL2_TAG}"
    echo "   Available tags can be found at: https://github.com/microsoft/WSL2-Linux-Kernel/tags"
    exit 1
fi

cd kernel

echo
echo "📋 Copying live kernel configuration..."
zcat /proc/config.gz > .config
echo "✅ Kernel config copied from live system"

echo
echo "🔧 Preparing kernel build environment..."

# Update config for any new options (non-interactive)
echo "   Running 'make olddefconfig' (accepting defaults for new options)..."
make olddefconfig

# Prepare for module building
echo "   Running 'make modules_prepare'..."
make modules_prepare

# Build scripts needed for external modules
echo "   Running 'make scripts'..."
make scripts

# Create a completion marker
echo "$(date): Kernel setup completed for ${WSL2_TAG} on ${LIVE_KERNEL_VERSION}" > .kernel_setup_complete

echo
echo "✅ Kernel preparation complete!"
echo
echo "📁 Kernel sources ready in: $(pwd)"
echo "🔧 Build environment configured for: $(make kernelversion)"

# Verify some key configurations
echo
echo "🔍 Verifying key configurations:"
echo "   CONFIG_MODULES: $(grep '^CONFIG_MODULES=' .config || echo 'NOT SET')"
echo "   CONFIG_HYPERV: $(grep '^CONFIG_HYPERV=' .config || echo 'NOT SET')"
echo "   CONFIG_HYPERV_VMBUS: $(grep '^CONFIG_HYPERV_VMBUS=' .config || echo 'NOT SET')"

# Final verification
if [ -f "scripts/mod/modpost" ] && [ -f ".config" ] && [ -f "Module.symvers" ]; then
    echo
    echo "✅ All build prerequisites verified!"
else
    echo
    echo "⚠️  Some build files may be missing - build might fail"
fi

echo
echo "✨ Ready to build kernel modules!"
echo "   cd ../driver && make"
echo
echo "💡 This script is idempotent - safe to run again if needed"
