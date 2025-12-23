# Dynamic Shared Buffer Architecture

## Overview

This document describes the new dynamic shared buffer system that allows the guest to create, manage, and clean up shared memory buffers of any size on demand.

## 🏗️ **New Architecture vs Old**

### **Old System (Fixed Shared Memory):**
- Single 32MB shared memory file created by host
- Fixed layout: 4KB header + 15MB request + 15MB response
- Limited to buffer sizes ≤ 15MB
- Host manages memory allocation

### **New System (Dynamic Guest-Managed):**
- Guest creates temporary shared memory files of any size
- No size limitations (beyond system memory)
- Guest fully controls buffer lifecycle
- Host optionally maps files on demand

## 📋 **API Reference**

### **New Client API Functions:**

```c
typedef struct {
    void *data;              // Mapped memory pointer
    size_t size;             // Buffer size in bytes
    char file_path[256];     // Path to backing file
    int fd;                  // File descriptor
    uint32_t buffer_id;      // Unique buffer identifier
} winapi_shared_buffer_t;

/* Allocate a new shared memory buffer */
int winapi_alloc_shared_buffer(winapi_handle_t handle, size_t size, winapi_shared_buffer_t *buffer);

/* Send shared buffer to host for processing */
int winapi_process_shared_buffer(winapi_handle_t handle, winapi_shared_buffer_t *buffer, const char *operation);

/* Free a shared memory buffer */
void winapi_free_shared_buffer(winapi_shared_buffer_t *buffer);
```

## 🔄 **Workflow**

### **1. Guest Allocates Buffer:**
```c
winapi_shared_buffer_t buffer;
winapi_alloc_shared_buffer(handle, 64 * 1024 * 1024, &buffer);  // 64MB buffer
```

**What happens internally:**
- Creates unique temporary file: `/mnt/c/temp/winapi_shared_buffer_1_1234`
- Sets file size with `ftruncate()`
- Maps file into guest memory with `mmap()`
- Returns mapped pointer and metadata

### **2. Guest Fills Buffer:**
```c
uint32_t *data = (uint32_t *)buffer.data;
for (size_t i = 0; i < buffer.size / sizeof(uint32_t); i++) {
    data[i] = test_pattern;
}
```

### **3. Guest Sends to Host:**
```c
winapi_process_shared_buffer(handle, &buffer, "process");
```

**What happens internally:**
- Sends JSON message over TCP control channel:
```json
{
  "api": "shared_buffer",
  "operation": "process",
  "file_path": "/mnt/c/temp/winapi_shared_buffer_1_1234",
  "buffer_size": 67108864,
  "buffer_id": 1
}
```

### **4. Host Processes (Optional):**
```cpp
// Convert path: /mnt/c/temp/file → C:\temp\file
// Optionally map the file for processing
HANDLE file_handle = CreateFileA(windows_path.c_str(), ...);
LPVOID mapped_memory = MapViewOfFile(...);
// [do actual processing]
UnmapViewOfFile(mapped_memory);
CloseHandle(file_handle);
```

### **5. Guest Cleans Up:**
```c
winapi_free_shared_buffer(&buffer);
```

**What happens internally:**
- `munmap()` unmaps memory from guest
- `close()` closes file descriptor
- `unlink()` removes backing file
- Zeros buffer structure

## 📁 **File Naming Convention**

Format: `/mnt/c/temp/winapi_shared_buffer_{ID}_{PID}`

**Example:** `/mnt/c/temp/winapi_shared_buffer_1_1234`
- **ID**: Unique buffer identifier (1, 2, 3...)
- **PID**: Process ID for uniqueness across processes

## 🌉 **Path Translation**

| Guest Path (Linux) | Host Path (Windows) |
|-------------------|---------------------|
| `/mnt/c/temp/winapi_shared_buffer_1_1234` | `C:\temp\winapi_shared_buffer_1_1234` |
| `/mnt/c/Users/user/data.bin` | `C:\Users\user\data.bin` |

## 🎯 **Benefits**

### **Flexibility:**
- ✅ **Any buffer size** - No 15MB limit
- ✅ **Multiple concurrent buffers** - Create as many as needed
- ✅ **Dynamic allocation** - Allocate only when needed

### **Performance:**
- ⚡ **Zero-copy transfers** - Direct memory mapping
- ⚡ **No data copying** - Host maps same physical file
- ⚡ **Memory-speed access** - Same as old system

### **Resource Management:**
- 🧹 **Automatic cleanup** - Guest controls entire lifecycle
- 🧹 **No memory leaks** - Files removed when done
- 🧹 **Process isolation** - Each process has unique files

### **Scalability:**
- 📈 **Unlimited size** - Only limited by available disk/memory
- 📈 **Concurrent operations** - Multiple buffers simultaneously
- 📈 **No host state** - Host is stateless for buffer management

## 🧪 **Testing**

### **Run Dynamic Shared Buffer Tests:**
```bash
./test_client --shared-only
```

### **Expected Output:**
```
=== Dynamic Shared Buffer Test ===
Testing 1.00 MB dynamic buffer...
✅ Allocated shared buffer: /mnt/c/temp/winapi_shared_buffer_1_1234 (1048576 bytes)
  Filling buffer with test pattern...
  Sending to host for processing...
✅ Host processed shared buffer: /mnt/c/temp/winapi_shared_buffer_1_1234
  Verifying buffer integrity...
  ✅ Buffer integrity verified
✅ Cleaned up shared buffer: /mnt/c/temp/winapi_shared_buffer_1_1234
  ✅ Buffer cleaned up

Testing 8.00 MB dynamic buffer...
[... similar output ...]

Testing 32.00 MB dynamic buffer...
[... similar output ...]

Dynamic shared buffer tests completed successfully!
```

## 🔧 **Implementation Details**

### **Buffer ID Generation:**
```c
static uint32_t g_next_buffer_id = 1;
buffer->buffer_id = g_next_buffer_id++;
```

### **Error Handling:**
- **File creation fails**: Returns -1, no cleanup needed
- **mmap() fails**: Closes fd, removes file, returns -1
- **Host processing fails**: Guest still owns cleanup responsibility

### **Thread Safety:**
- Buffer IDs use static counter (not thread-safe)
- Each buffer is independent after creation
- Cleanup is guest's responsibility

## 🚀 **Future Enhancements**

### **Possible Extensions:**
- **Async processing**: Non-blocking host operations
- **Buffer pools**: Reuse buffers for better performance
- **Compression**: Compress data before sending to host
- **Encryption**: Encrypt shared memory contents
- **Permissions**: Fine-grained access control

### **Host Processing Options:**
- **Read-only mapping**: Host only reads data
- **Read-write mapping**: Host can modify buffer contents
- **Multiple operations**: Chain multiple processing steps
- **Background processing**: Long-running operations

## 📝 **Protocol Extension**

### **New JSON API:**
```json
{
  "api": "shared_buffer",
  "request_id": 123,
  "operation": "process",
  "file_path": "/mnt/c/temp/winapi_shared_buffer_1_1234",
  "buffer_size": 67108864,
  "buffer_id": 1
}
```

### **Response:**
```json
{
  "request_id": 123,
  "status": "success",
  "result": {
    "operation": "process",
    "buffer_id": 1,
    "bytes_processed": 67108864,
    "status": "processed"
  }
}
```

This new architecture provides a much more flexible and scalable foundation for shared memory operations while maintaining the performance benefits of zero-copy transfers! 🎉