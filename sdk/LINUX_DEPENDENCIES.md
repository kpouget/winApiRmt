# WSL2/Linux Dependencies Tracking

Track installation progress and dependency status for the WSL2 client build.

## Dependencies Status

| Component | Status | Installation Command | Version | Notes |
|-----------|--------|---------------------|---------|-------|
| **Build Tools** | ✅ | `sudo dnf install gcc make` | | Core compilation tools |
| **json-c Library** | ✅ | `sudo dnf install json-c-devel` | | JSON protocol support - **SOLVED** |
| **AF_VSOCK Support** | ✅ | Built into WSL2 kernel | | Hyper-V socket communication |
| **Python3** | ✅ | Usually pre-installed | | For testing and utilities |
| **Project Files** | ✅ | Located at `/mnt/c/Users/azureuser/winApiRmt/` | | Shared Windows filesystem |

## Installation History

### ✅ SOLVED: json-c dependency (Remote Windows System)
```bash
# On Fedora/RHEL/CentOS WSL2 - COMPLETED
sudo dnf install json-c-devel

# This resolved the build error:
# #include <json-c/json.h>       // For JSON protocol
```

### Build Commands Used
```bash
# Build tools (if needed)
sudo dnf install gcc make

# JSON library for protocol communication - INSTALLED
sudo dnf install json-c-devel

# Verify installations
gcc --version
pkg-config --libs json-c
```

### Alternative Commands for Other Distributions
```bash
# Ubuntu/Debian
sudo apt update && sudo apt install build-essential libjson-c-dev

# Arch Linux
sudo pacman -S base-devel json-c
```

## Remote System Configuration

### Project Location
- **Remote WSL2 Path**: `/mnt/c/Users/azureuser/winApiRmt/`
- **Remote Windows Path**: `C:\Users\azureuser\winApiRmt\`
- **Shared filesystem**: Both WSL2 and Windows can access same files

### AF_VSOCK Verification (Remote System)
```bash
# ✅ CONFIRMED: AF_VSOCK protocol available
grep -i vsock /proc/net/protocols
# Output: AF_VSOCK  1224      0      -1   NI       0   yes  kernel      y  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n
```

### Build Process (Remote System)
```bash
cd /mnt/c/Users/azureuser/winApiRmt/guest/client

# Clean previous builds
make clean

# Build with json-c support
make all

# Expected files after successful build:
# - libwinapi.a (static library)
# - libwinapi.so (shared library)
# - test_client (test executable)
```

## Shared Memory Setup (Remote System)

```bash
# Create directory accessible from both WSL2 and Windows
sudo mkdir -p /mnt/c/temp
sudo chmod 777 /mnt/c/temp

# This creates C:\temp\ on Windows side for service access
```

## Dependencies Resolution Log

### Issue #1: Missing json-c Header ✅ SOLVED
- **Error**: `#include <json-c/json.h>` not found
- **Solution**: `sudo dnf install json-c-devel` on Fedora WSL2
- **Status**: Resolved successfully
- **Date**: Current session

### Issue #2: AF_VSOCK Support ✅ CONFIRMED
- **Check**: Hyper-V socket protocol availability
- **Result**: Built into WSL2 kernel, fully supported
- **Status**: Available and working

## Next Steps Checklist

- [x] Install build dependencies
- [x] Install json-c library (**COMPLETED**)
- [x] Verify AF_VSOCK support
- [x] Create shared memory directory
- [ ] Complete WSL2 client build
- [ ] Build Windows service (vcpkg + jsoncpp)
- [ ] Test end-to-end communication

## System Information

### Remote Windows System (WSL2)
- **Distribution**: Fedora in WSL2
- **Project Path**: `/mnt/c/Users/azureuser/winApiRmt/`
- **JSON Library**: json-c-devel (dnf package)
- **Socket Support**: AF_VSOCK built into kernel
- **Build System**: GCC + Make

### Local Development System
- **Project Path**: `/var/home/kpouget/pod-virt/winApiRmt/`
- **Purpose**: Code development and documentation
- **Build Status**: Not intended for compilation

## Windows Service Dependencies (Separate)

See `WINDOWS_SETUP.md` for Windows-side dependency tracking:
- vcpkg package manager
- jsoncpp library (C++ JSON support)
- Visual Studio Build Tools
- CMake (optional)