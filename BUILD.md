# Building the Windows API Remoting Framework

This document describes how to build and install the API remoting framework components.

## Prerequisites

### Windows Host
- Windows 10/11 or Windows Server 2016+
- Visual Studio 2019+ with Windows Driver Kit (WDK)
- VMBus support enabled (Hyper-V environment)

### Linux Guest
- Linux kernel 4.4+ with VMBus support
- GCC compiler
- Kernel development headers
- Make build system

## Building Host Components (Windows)

### Option 1: Visual Studio
1. Open Visual Studio with WDK installed
2. Create a new "Kernel Mode Driver" project
3. Add the source files:
   - `host/driver/vmbus_provider.c`
   - `host/driver/api_handlers.c`
4. Build the project to generate `winapi_remoting.sys`

### Option 2: WDK Command Line
```cmd
# Set up build environment
call "C:\Program Files (x86)\Windows Kits\10\bin\SetEnv.cmd"

# Navigate to host/driver directory
cd host\driver

# Build the driver
msbuild winapi_remoting.vcxproj /p:Platform=x64 /p:Configuration=Release
```

### Installing the Host Driver
1. Copy the built `winapi_remoting.sys` to a target directory
2. Use the provided INF file to install:
```cmd
# Install driver (requires Administrator privileges)
pnputil /add-driver host\inf\winapi_remoting.inf /install

# Alternatively, use Device Manager to install manually
```

## Building Guest Components (Linux)

### Quick Build
Use the provided test script:
```bash
chmod +x tests/test_build.sh
./tests/test_build.sh
```

### Manual Build

#### 1. Build the Kernel Driver
```bash
cd guest/driver
make clean
make

# Install (optional)
sudo make install
```

#### 2. Build Userspace Library and Test Client
```bash
cd guest/userspace
make clean
make

# Install library system-wide (optional)
sudo make install
```

## Installation and Testing

### 1. Load the Linux Driver
```bash
# Load the driver module
sudo insmod guest/driver/winapi_client.ko

# Verify it's loaded
lsmod | grep winapi_client

# Check for device node
ls -l /dev/winapi
```

### 2. Run Tests
```bash
# Run all tests
./guest/userspace/test_client

# Run specific tests
./guest/userspace/test_client --echo-only
./guest/userspace/test_client --buffer-only
./guest/userspace/test_client --perf-only
```

### 3. Unload Driver (when done)
```bash
sudo rmmod winapi_client
```

## Troubleshooting

### Common Issues

#### "No such device" error
- Ensure the Windows host driver is installed and running
- Verify VMBus connectivity between host and guest
- Check that the VMBus GUID matches in both drivers

#### Build failures on Linux
- Install kernel headers: `sudo apt-get install linux-headers-$(uname -r)`
- Ensure GCC and make are installed: `sudo apt-get install build-essential`

#### Permission errors
- Ensure the device node has correct permissions: `sudo chmod 666 /dev/winapi`
- Or run test client as root: `sudo ./test_client`

### Debug Information

#### Check kernel messages
```bash
# View driver messages
dmesg | grep winapi

# Continuous monitoring
sudo dmesg -w | grep winapi
```

#### Verify VMBus connectivity
```bash
# List VMBus devices
ls /sys/bus/vmbus/devices/

# Check for our device
cat /sys/bus/vmbus/devices/*/device_id | grep "6ac83d8f-6e16-4e5c"
```

## Performance Optimization

### For best performance:
1. Use large page sizes when possible
2. Align buffers to page boundaries
3. Minimize the number of API calls for large data transfers
4. Use the buffer test APIs to verify zero-copy operation

### Expected Performance (reference):
- **Latency**: < 100μs for simple RPC calls
- **Throughput**: > 1GB/s for large buffer transfers
- **Memory**: Zero-copy for buffers > 4KB

## Development Tips

### Adding New APIs
1. Add API ID to `common/protocol.h`
2. Implement handler in `host/driver/api_handlers.c`
3. Add IOCTL support in `guest/driver/vmbus_client.c`
4. Update userspace library `guest/userspace/libwinapi.c`
5. Add tests to `guest/userspace/test_client.c`

### Debugging
- Use kernel debugging tools on Windows (WinDbg)
- Enable debug prints in Linux driver (`pr_debug`)
- Use VMBus tracing tools if available