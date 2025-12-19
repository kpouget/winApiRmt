# Windows VMBus API Remoting Driver

This Windows kernel-mode driver provides VMBus-based API remoting services, allowing Linux guests to make high-performance API calls to the Windows host.

## Overview

The WinAPI Remoting Driver is part of a proof-of-concept system for enabling efficient cross-VM API calls between a Linux guest and Windows host using the VMBus protocol. It supports:

- **Low-latency RPC calls** (target: <100μs)
- **High-throughput data transfer** (target: >1GB/s)
- **Zero-copy buffer operations** for large data transfers
- **Multiple concurrent API calls**

## Architecture

### Key Components

- **vmbus_privder.c**: Main VMBus provider driver implementation
- **api_handlers.c**: API request handler implementations
- **../../../common/protocol.h**: Shared protocol definitions
- **winApiRemoting.inf**: Driver installation configuration

### Supported APIs

1. **Echo API**: Simple text echo for connectivity testing
2. **Buffer Test API**: Read/Write/Verify operations on shared buffers
3. **Performance Test API**: Latency and throughput benchmarking

## Prerequisites

### Development Environment

- **Windows 10/11** or **Windows Server 2016+**
- **Visual Studio 2019** or later with C++ tools
- **Windows Driver Kit (WDK)** 10.0.22000 or later
- **Windows SDK** 10.0.22000 or later

### Runtime Requirements

- **Hyper-V role** enabled
- **VMBus support** (built into Windows)
- **Test signing** enabled (for development/testing)

## Building the Driver

### Common Build Issue: Spectre Mitigation

If you encounter this error:
```
Spectre-mitigated libraries are required for this project. Install them from the Visual Studio installer.
```

**Solution 1 (Recommended)**: Install Spectre-mitigated libraries:
1. Open Visual Studio Installer
2. Click "Modify" on your VS installation
3. Go to "Individual components" tab
4. Search for "Spectre" and install:
   - "MSVC v143 - VS 2022 C++ x64/x86 Spectre-mitigated libs"
   - "MSVC v143 - VS 2022 C++ ARM64 Spectre-mitigated libs" (if needed)

**Solution 2 (Quick Fix)**: The project is already configured to disable Spectre mitigation for POC purposes.

### Option 1: Visual Studio

1. Open `winApiRemoting.sln` in Visual Studio
2. Select your target configuration:
   - **Debug x64** (recommended for development)
   - **Release x64** (for production)
   - **Debug/Release ARM64** (for ARM64 systems)
3. Build the solution using **Build > Build Solution** (Ctrl+Shift+B)

The driver will be built to:
```
host/driver/winApiRemoting/x64/Debug/winApiRemoting.sys
```

### Option 2: Command Line (MSBuild)

```cmd
# Navigate to the driver directory
cd host\driver\winApiRemoting

# Build for x64 Debug
msbuild winApiRemoting.vcxproj /p:Configuration=Debug /p:Platform=x64

# Build for x64 Release
msbuild winApiRemoting.vcxproj /p:Configuration=Release /p:Platform=x64
```

## Installing the Driver

### Prerequisites for Installation

1. **Enable Test Signing** (required for development):
   ```cmd
   bcdedit /set testsigning on
   ```
   Reboot after running this command.

2. **Disable Driver Signature Enforcement** (alternative method):
   - Hold Shift and click Restart
   - Choose Troubleshoot > Advanced options > Startup Settings
   - Click Restart and press F7 for "Disable driver signature enforcement"

### Installation Steps

1. **Copy driver files** to a temporary directory:
   ```cmd
   mkdir C:\temp\winApiRemoting
   copy winApiRemoting.sys C:\temp\winApiRemoting\
   copy winApiRemoting.inf C:\temp\winApiRemoting\
   ```

2. **Install the driver**:
   ```cmd
   # Method 1: Using pnputil (Windows 10+)
   pnputil /add-driver C:\temp\winApiRemoting\winApiRemoting.inf /install

   # Method 2: Using Device Manager
   # - Open Device Manager
   # - Right-click "System Devices"
   # - Select "Add legacy hardware"
   # - Browse to the .inf file
   ```

3. **Verify installation**:
   ```cmd
   # Check if driver is loaded
   sc query winApiRemoting

   # Check Windows Event Log for any errors
   eventvwr.msc
   ```

## Configuration

### VMBus Channel GUID

The driver uses VMBus channel GUID: `6ac83d8f-6e16-4e5c-ab3d-fd8c5a4b7e21`

This GUID must match the one used by the Linux guest driver for proper communication.

### Registry Configuration

No additional registry configuration is required. The driver uses default VMBus mechanisms for channel discovery.

## Testing

### Basic Connectivity Test

1. **Start the Windows driver**:
   ```cmd
   sc start winApiRemoting
   ```

2. **Load the Linux guest driver** (on guest VM)
3. **Run echo test** from Linux guest:
   ```bash
   echo "Hello World" > /dev/winapi_echo
   cat /dev/winapi_echo
   ```

### Performance Testing

Use the built-in performance APIs to measure:
- **Latency**: Round-trip time for API calls
- **Throughput**: Data transfer rate for buffer operations

## Debugging

### Debug Output

The driver uses `KdPrintEx` for debug output. To view debug messages:

1. **Enable debug output**:
   ```cmd
   bcdedit /debug on
   ```

2. **Use DebugView** (SysInternals) or connect a kernel debugger

3. **Set debug filter levels**:
   ```cmd
   # Enable all debug messages
   reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Debug Print Filter" /v DEFAULT /t REG_DWORD /d 0xFFFFFFFF
   ```

### Common Issues

1. **Driver fails to load**:
   - Check Event Viewer for error messages
   - Verify test signing is enabled
   - Ensure all dependencies are met

2. **VMBus channel not opening**:
   - Verify Hyper-V is enabled
   - Check GUID matches between host and guest
   - Ensure guest VM has VMBus support

3. **API calls failing**:
   - Check debug output for error messages
   - Verify protocol version compatibility
   - Test with echo API first

## Security Considerations

⚠️ **Important**: This is a proof-of-concept driver with minimal security features:

- **Trusted guest assumption**: The guest is considered trusted
- **Limited input validation**: Basic parameter checking only
- **No access control**: All APIs are accessible to guest

**For production use**, implement:
- Comprehensive input validation
- Guest authentication and authorization
- Rate limiting and resource quotas
- Audit logging

## Development Notes

### Code Structure

- **Protocol-agnostic design**: Core driver logic separated from API implementations
- **Extensible API framework**: Easy to add new API handlers
- **Performance monitoring**: Built-in timing and throughput measurement

### Adding New APIs

1. **Define protocol structures** in `common/protocol.h`
2. **Implement handler function** in `api_handlers.c`
3. **Add dispatcher case** in `vmbus_privder.c`
4. **Update protocol version** if needed

### Building for Different Architectures

The project supports multiple architectures:
- **x64**: Primary target for most systems
- **ARM64**: For ARM64-based Windows systems

## License

This code is provided as a proof-of-concept for educational and research purposes.

## Contributing

When contributing:
1. Follow Windows driver development best practices
2. Add appropriate debug logging
3. Test on both debug and release builds
4. Update documentation for new features

## Support

For issues and questions:
1. Check debug output and Event Viewer
2. Review this documentation
3. Test with minimal configuration first
4. Provide detailed error information when reporting issues