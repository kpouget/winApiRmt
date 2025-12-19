# WSL2 API Remoting Architecture

## Overview

High-performance API remoting using WSL2's supported communication mechanisms:
- **Hyper-V Sockets**: For control plane and metadata
- **Memory-Mapped Files**: For bulk data transfer (zero-copy)

## Components

### Windows Host Service (`host/service/`)
```cpp
// Windows Service that:
// 1. Creates shared memory region
// 2. Listens on Hyper-V socket (VMID_PARENT, well-known port)
// 3. Handles API requests via socket protocol
// 4. Manages memory-mapped file access
```

### WSL2 Guest Client (`guest/client/`)
```c
// Linux client library that:
// 1. Connects to Hyper-V socket (VMID_PARENT, well-known port)
// 2. Maps shared memory file
// 3. Sends API requests via socket
// 4. Reads bulk data from memory-mapped region
```

## Communication Flow

### 1. Initialization
```
Windows Service                WSL2 Client
├─ CreateFileMapping()         ├─ socket(AF_HYPERV)
├─ MapViewOfFile()             ├─ connect(VMID_PARENT, port)
└─ listen(AF_HYPERV)           └─ mmap("/mnt/c/shared_mem")
```

### 2. API Request
```
Client                         Service
├─ Write JSON metadata         ├─ Read JSON request
├─ to Hyper-V socket          ├─ from Hyper-V socket
├─ Write payload to           ├─ Read payload from
└─ shared memory              └─ shared memory
```

### 3. Response
```
Service                        Client
├─ Write JSON response         ├─ Read JSON response
├─ to Hyper-V socket          ├─ from Hyper-V socket
├─ Write result to            ├─ Read result from
└─ shared memory              └─ shared memory
```

## Protocol

### Hyper-V Socket Protocol (JSON)
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
│ - Magic number  │ - API payloads   │ - API results   │
│ - Version       │ - Test buffers   │ - Response data │
│ - Request count │ - Performance    │ - Error info    │
│ - Sync flags    │   data           │ - Statistics    │
└─────────────────┴──────────────────┴─────────────────┘
```

## Benefits

- ✅ **WSL2 Compatible**: Uses only officially supported APIs
- ✅ **High Performance**: Zero-copy for bulk data
- ✅ **Simple Protocol**: JSON + binary data
- ✅ **No Drivers**: Pure userspace implementation
- ✅ **Bidirectional**: Both request/response patterns
- ✅ **Concurrent**: Multiple outstanding requests

## API Functions

1. **Echo API**: Simple request/response validation
2. **Buffer Test**: Large data transfer testing
3. **Performance**: Latency and throughput measurement

## Well-Known Values

- **Hyper-V Socket Port**: `0x1234` (configurable)
- **Shared Memory File**: `/mnt/c/temp/winapi_shared_memory`
- **Memory Size**: 8MB (header + 2 x 4MB buffers)
- **Magic Number**: `0x57494E41` ("WINA")