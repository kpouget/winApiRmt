# WinAPI Remoting for WSL2

High-performance Windows API remoting system for WSL2 using Hyper-V sockets and shared memory.

## Overview

This project enables Linux applications running in WSL2 to make high-performance API calls to Windows host services. It uses WSL2's officially supported communication mechanisms for optimal performance:

- **Hyper-V Sockets**: For control plane and metadata exchange
- **Memory-Mapped Files**: For zero-copy bulk data transfer

## Architecture

```
┌─────────────────┐    Hyper-V Socket     ┌─────────────────┐
│   WSL2 Client   │◄──── (Metadata) ────►│ Windows Service │
│                 │                       │                 │
│   libwinapi.a   │    Memory-Mapped      │  WinAPIService  │
│                 │◄──── (Bulk Data) ────►│                 │
└─────────────────┘                       └─────────────────┘
```

### Key Benefits

- ✅ **WSL2 Compatible**: Uses only officially supported WSL2 APIs
- ✅ **High Performance**: Zero-copy transfers for bulk data via shared memory
- ✅ **Simple Protocol**: JSON over Hyper-V sockets + binary shared memory
- ✅ **No Drivers Required**: Pure userspace implementation
- ✅ **Concurrent Operations**: Multiple outstanding requests supported

## Requirements

### Windows Host
- Windows 10/11 with WSL2 enabled
- Visual Studio 2019+ or Build Tools for Visual Studio
- Administrator privileges (for service installation)

### WSL2 Guest
- WSL2 distribution (Ubuntu, Debian, etc.)
- GCC or Clang compiler
- Make build system

## Quick Start

### 1. Build

Run the build script from the project root:

```bash
./build.sh
```

This builds:
- WSL2 client library (`guest/client/libwinapi.a`)
- Test client (`guest/client/test_client`)
- Windows service (if Windows environment detected)

### 2. Install Windows Service

On Windows (as Administrator):

```cmd
cd host\service
install.cmd
```

### 3. Test Communication

In WSL2:

```bash
cd guest/client
./test_client
```

## API Reference

### Initialization

```c
#include "libwinapi.h"

// Initialize the library
winapi_handle_t handle = winapi_init();
if (!handle) {
    // Handle initialization error
}

// Clean up when done
winapi_cleanup(handle);
```

### Echo API

Simple request/response validation:

```c
char output[256];
int result = winapi_echo(handle, "Hello Windows!", output, sizeof(output));
if (result == 0) {
    printf("Echo response: %s\n", output);
}
```

### Buffer Testing

Test large data transfers:

```c
// Allocate test buffer
winapi_buffer_t buffer;
winapi_alloc_buffer(&buffer, 1024 * 1024); // 1MB

// Fill with test pattern
memset(buffer.data, 0xAA, buffer.size);

// Test buffer operations
winapi_buffer_test_result_t result;
int status = winapi_buffer_test(handle, &buffer, 1,
                               WINAPI_BUFFER_OP_WRITE,
                               0xAABBCCDD, &result);

printf("Transferred: %lu bytes, Checksum: 0x%08X\n",
       result.bytes_processed, result.checksum);

winapi_free_buffer(&buffer);
```

### Performance Testing

Measure latency and throughput:

```c
winapi_perf_test_params_t params = {
    .test_type = WINAPI_PERF_THROUGHPUT,
    .iterations = 1000,
    .target_bytes = 1024 * 1024 * 10 // 10MB
};

winapi_buffer_t buffers[4];
// Allocate and initialize buffers...

winapi_perf_test_result_t result;
int status = winapi_perf_test(handle, &params, buffers, 4, &result);

printf("Throughput: %lu MB/s\n", result.throughput_mbps);
printf("Avg Latency: %lu ns\n", result.avg_latency_ns);
```

## Communication Protocol

### Hyper-V Socket Messages (JSON)

```json
{
  "request_id": 12345,
  "api": "echo|buffer_test|performance",
  "payload_size": 1048576,
  "payload_offset": 0,
  "flags": ["zero_copy", "async"]
}
```

### Shared Memory Layout

```
┌─────────────────┬──────────────────┬─────────────────┐
│   Header (4KB)  │  Request (4MB)   │  Response (4MB) │
├─────────────────┼──────────────────┼─────────────────┤
│ - Magic: "WINA" │ - API payloads   │ - API results   │
│ - Version       │ - Test buffers   │ - Response data │
│ - Request count │ - Performance    │ - Error info    │
│ - Sync flags    │   data           │ - Statistics    │
└─────────────────┴──────────────────┴─────────────────┘
```

## Configuration

### Default Settings

- **Hyper-V Socket Port**: `0x1234`
- **Shared Memory File**: `/mnt/c/temp/winapi_shared_memory`
- **Memory Size**: 8MB (4KB header + 2×4MB buffers)
- **Connection Timeout**: 30 seconds

### Environment Variables

```bash
export WINAPI_DEBUG=1              # Enable debug logging
export WINAPI_SOCKET_PORT=0x5678   # Custom socket port
export WINAPI_SHARED_MEM=/custom/path # Custom shared memory path
```

## Building from Source

### WSL2 Client

```bash
cd guest/client
make clean
make

# Static library: libwinapi.a
# Test client: test_client
```

### Windows Service

```cmd
cd host\service
build.cmd

# Service executable: WinAPIService.exe
# Installer script: install.cmd
```

### Manual Build (Advanced)

```bash
# WSL2 client with custom flags
cd guest/client
gcc -O3 -DDEBUG -o test_client test_client.c libwinapi.c -lpthread
```

## Testing

### Unit Tests

```bash
cd guest/client
./test_client --test echo
./test_client --test buffer
./test_client --test performance
```

### Integration Tests

```bash
# Full end-to-end test suite
./test_client --integration

# Stress testing
./test_client --stress --iterations 10000
```

### Performance Benchmarks

```bash
# Latency benchmark
./test_client --benchmark latency

# Throughput benchmark
./test_client --benchmark throughput --size 100MB
```

## Troubleshooting

### Common Issues

**"Connection refused" error:**
- Ensure Windows service is running: `sc query WinAPIService`
- Check Windows Firewall settings
- Verify Hyper-V socket support: `dmesg | grep hyperv`

**"Shared memory access denied":**
- Check file permissions on `/mnt/c/temp/winapi_shared_memory`
- Ensure Windows service has write access to temp directory
- Try running as administrator on Windows side

**Poor performance:**
- Verify shared memory is being used (check debug logs)
- Monitor memory usage: `cat /proc/meminfo`
- Check for memory fragmentation

### Debug Logging

Enable detailed logging:

```bash
export WINAPI_DEBUG=1
export WINAPI_LOG_LEVEL=TRACE
./test_client
```

### Service Status

Check Windows service status:

```cmd
sc query WinAPIService
Get-EventLog -LogName Application -Source "WinAPIService"
```

## Architecture Details

For detailed technical documentation, see [ARCHITECTURE.md](ARCHITECTURE.md).

## License

This project is provided as-is for educational and testing purposes.

## Contributing

This is a proof-of-concept implementation. For production use, consider:

- Adding authentication/authorization
- Implementing rate limiting
- Adding comprehensive error recovery
- Security hardening for shared memory access
- Performance optimizations for specific use cases