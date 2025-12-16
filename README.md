# Windows API Remoting Framework - VMBus POC

A proof-of-concept implementation of API remoting between Windows host and Linux guest using VMBus protocol.

## Architecture

- **Host (Windows)**: VMBus provider driver that handles API requests and manages shared memory
- **Guest (Linux)**: VMBus client driver with userspace library for API calls
- **Communication**: VMBus channels with ring buffers for small data, direct GPA mapping for large buffers

## Features

- Simple RPC mechanism (echo API)
- Zero-copy large buffer sharing
- Performance measurement tools
- Variable buffer size support (4KB to 10MB+)

## Project Structure

```
├── host/           # Windows VMBus provider
├── guest/          # Linux VMBus client
├── common/         # Shared protocol definitions
└── tests/          # Test applications and scripts
```

## Quick Start

### 1. Build Windows Driver

```bash
# From project root (works in Linux/WSL/SSH/Windows)
./build.sh
```

### 2. Install Driver on Windows

```cmd
REM Run as Administrator from host/driver/winApiRemoting/
install_driver.cmd
```

### 3. Test Installation

```cmd
REM Check driver status
sc query winApiRemoting
```

## Building

### Windows Host Driver

**Requirements**: Visual Studio 2019/2022 + Windows Driver Kit (WDK)

**Quick Setup**:
```bash
# Download development tools (Linux/WSL)
cd sdk/
./download_windows_dev_tools.sh

# Install on Windows (run as Administrator)
install_on_windows.cmd
```

**Build**:
```bash
# Cross-platform build script
./build.sh
```

**Manual build**:
```cmd
REM From host/driver/winApiRemoting/ in VS Developer Command Prompt
build_driver_manual.cmd
```

For detailed instructions: [COMPILE.md](host/driver/winApiRemoting/COMPILE.md)

### Linux Guest Driver

*Coming soon - Linux VMBus client implementation*

## Installation & Loading

### Windows Driver Installation

**Automated**:
```cmd
REM Run as Administrator from driver directory
install_driver.cmd
```

**Manual**:
```cmd
REM Enable test signing (requires reboot)
bcdedit /set testsigning on
shutdown /r /t 0

REM Install and start driver
pnputil /add-driver winApiRemoting.inf /install
sc start winApiRemoting
```

**Management**:
- **Status**: `sc query winApiRemoting`
- **Stop**: `sc stop winApiRemoting`
- **Uninstall**: `uninstall_driver.cmd`

For complete installation guide: [DRIVER_INSTALLATION.md](DRIVER_INSTALLATION.md)

## Testing

1. **Install Windows host driver** (see above)
2. **Set up Linux guest** with VMBus client (development in progress)
3. **Test APIs**:
   - Echo API - Simple request/response
   - Buffer Test - Zero-copy buffer operations
   - Performance Test - Latency and throughput measurements

## Performance

Target metrics:
- RPC latency: < 100μs
- Buffer throughput: > 1GB/s for large transfers