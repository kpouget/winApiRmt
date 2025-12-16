# Windows API Remoting Framework - Architecture Overview

## Overview

This framework enables efficient API remoting from Linux guests to Windows hosts using the VMBus transport protocol. It provides a high-performance, low-latency mechanism for Linux applications to invoke Windows APIs with zero-copy data transfer for large buffers.

## Architecture Components

### 1. Windows Host (Provider)
```
┌─────────────────────────────────────────────┐
│               Windows Host                  │
├─────────────────────────────────────────────┤
│  VMBus Provider Driver (winapi_remoting.sys)│
│  ┌─────────────────────────────────────────┐ │
│  │           API Handlers                  │ │
│  │  • Echo API                             │ │
│  │  • Buffer Test API                      │ │
│  │  • Performance Test API                 │ │
│  └─────────────────────────────────────────┘ │
│  ┌─────────────────────────────────────────┐ │
│  │         Memory Management               │ │
│  │  • GPA to Host VA Mapping              │ │
│  │  • Zero-copy Buffer Access             │ │
│  │  • MDL Management                      │ │
│  └─────────────────────────────────────────┘ │
│  ┌─────────────────────────────────────────┐ │
│  │        VMBus Interface                  │ │
│  │  • Channel Management                   │ │
│  │  • Message Processing                   │ │
│  │  • Event Handling                       │ │
│  └─────────────────────────────────────────┘ │
└─────────────────────────────────────────────┘
```

### 2. Linux Guest (Client)
```
┌─────────────────────────────────────────────┐
│               Linux Guest                   │
├─────────────────────────────────────────────┤
│           User Applications                 │
│  ┌─────────────────────────────────────────┐ │
│  │        Application Code                 │ │
│  │  • test_client.c (demo)                 │ │
│  │  • Custom applications                  │ │
│  └─────────────────────────────────────────┘ │
│              │                              │
│  ┌─────────────────────────────────────────┐ │
│  │        libwinapi.so                     │ │
│  │  • High-level API wrappers             │ │
│  │  • Buffer management                    │ │
│  │  • IOCTL interface                      │ │
│  └─────────────────────────────────────────┘ │
│              │                              │
│  ┌─────────────────────────────────────────┐ │
│  │    Kernel Driver (winapi_client.ko)    │ │
│  │  • VMBus Channel Management            │ │
│  │  • Request/Response Handling           │ │
│  │  • Page Pinning & GPA Mapping          │ │
│  │  • Character Device Interface          │ │
│  └─────────────────────────────────────────┘ │
└─────────────────────────────────────────────┘
```

## Communication Protocol

### 1. VMBus Channel
- **GUID**: `6ac83d8f-6e16-4e5c-ab3d-fd8c5a4b7e21`
- **Ring Buffer Size**: 4KB for commands and small data
- **Direct GPA Mapping**: For large buffer transfers (zero-copy)

### 2. Message Format
```c
struct winapi_message {
    winapi_message_header_t header;     // 64 bytes - fixed size
    winapi_buffer_desc_t buffers[8];    // Buffer descriptors
    uint8_t inline_data[3072];          // Small data payload
};
```

### 3. Data Flow

#### Small Data (< 3KB)
```
Guest App → libwinapi → Driver → VMBus Ring Buffer → Host Driver → API Handler → Response
```

#### Large Data (> 3KB)
```
Guest App → Page Allocation → GPA Sharing → VMBus Notification → Host GPA Mapping → Zero-copy Access
```

## Key Features

### 1. Zero-Copy Buffer Transfer
- Guest allocates pages and shares Guest Physical Addresses (GPA)
- Host maps GPA directly to Host Virtual Address (HVA)
- No data copying for large buffers (> 4KB)

### 2. Synchronous RPC Model
- Request-response pattern with unique request IDs
- Blocking calls with timeout support
- Simple programming model for applications

### 3. Multiple Buffer Support
- Up to 8 buffers per API call
- Variable buffer sizes (4KB to 64MB per buffer)
- Independent buffer operations

### 4. Performance Monitoring
- Built-in latency measurement
- Throughput testing capabilities
- Checksum verification for data integrity

## API Surface

### Current APIs (POC)

1. **Echo API** (`WINAPI_API_ECHO`)
   - Simple text echo for connectivity testing
   - Uses inline data only (< 3KB)

2. **Buffer Test API** (`WINAPI_API_BUFFER_TEST`)
   - Read/Write/Verify operations on shared buffers
   - Demonstrates zero-copy capabilities
   - Supports multiple buffers

3. **Performance Test API** (`WINAPI_API_PERF_TEST`)
   - Latency measurement
   - Throughput benchmarking
   - Performance characterization

### Extending the Framework

To add new APIs:
1. Define API ID in `common/protocol.h`
2. Implement handler in Windows driver
3. Add Linux driver IOCTL support
4. Update userspace library
5. Add test cases

## Performance Characteristics

### Target Performance
- **RPC Latency**: < 100μs (simple calls)
- **Buffer Throughput**: > 1GB/s (large transfers)
- **Memory Overhead**: Minimal (zero-copy design)

### Scalability
- **Concurrent Requests**: Supported via request ID multiplexing
- **Buffer Size**: Up to 64MB per buffer, 8 buffers per call
- **Multiple Clients**: Shared device with proper synchronization

## Security Considerations (POC)

### Current Status
- **Minimal Security**: POC focuses on functionality
- **Trust Model**: Guest is trusted
- **Input Validation**: Basic parameter checking only

### Production Considerations
- Add comprehensive input validation
- Implement capability-based access control
- Add audit logging
- Secure buffer sharing mechanisms
- Rate limiting and DoS protection

## Platform Requirements

### Windows Host
- Windows 10/11 or Server 2016+
- Hyper-V role enabled
- VMBus support
- WDK for driver development

### Linux Guest
- Kernel 4.4+ with VMBus support
- CONFIG_HYPERV enabled
- Modern GCC compiler
- Root access for driver loading

## Future Enhancements

### Planned Features
1. **Asynchronous APIs**: Non-blocking call support
2. **Streaming APIs**: Continuous data transfer
3. **Event Notifications**: Host-to-guest events
4. **API Versioning**: Protocol evolution support
5. **Security Hardening**: Production-ready security

### Performance Optimizations
1. **Batch Operations**: Multiple API calls per message
2. **Memory Pools**: Pre-allocated buffer management
3. **NUMA Awareness**: CPU affinity optimizations
4. **Interrupt Coalescing**: Reduced context switching

## Debugging and Troubleshooting

### Linux Debug Commands
```bash
# Driver messages
dmesg | grep winapi

# VMBus device info
ls /sys/bus/vmbus/devices/

# Performance monitoring
./test_client --perf-only
```

### Windows Debug Tools
- WinDbg for kernel debugging
- Event Tracing for Windows (ETW)
- Performance Toolkit (WPT)

This architecture provides a solid foundation for high-performance API remoting while maintaining simplicity and extensibility.