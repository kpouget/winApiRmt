/*
 * User-space library for Windows API Remoting (WSL2)
 *
 * This library provides a simple C API for applications to communicate
 * with Windows host via Hyper-V sockets and shared memory.
 */

#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200112L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <linux/vm_sockets.h>  // For Hyper-V socket support
#include <arpa/inet.h>         // For htonl/ntohl network byte order
#include <netinet/in.h>        // For TCP socket support
#include <json-c/json.h>       // For JSON protocol

#include "libwinapi.h"
#include "../../common/protocol.h"

/* Hyper-V Socket Configuration */
#define HYPERV_SOCKET_PORT        0x400
#define TCP_FALLBACK_PORT         4660               // TCP fallback port
#define VMADDR_CID_PARENT         0x2     // Connect to parent (Windows host)
#define SHARED_MEMORY_PATH        "/mnt/c/temp/winapi_shared_memory"
#define SHARED_MEMORY_SIZE        (32 * 1024 * 1024) // 32MB
#define REQUEST_TIMEOUT_MS        5000

/* Shared Memory Layout */
#define HEADER_SIZE               4096
#define REQUEST_BUFFER_SIZE       (15 * 1024 * 1024) // 15MB
#define RESPONSE_BUFFER_SIZE      (15 * 1024 * 1024) // 15MB

/* SafeMemoryWrite boundary constants */
#define SAFE_WRITE_BOUNDARY       (32 * 1024)  // 32KB before buffer end
#define SAFE_WRITE_OFFSET         (RESPONSE_BUFFER_SIZE - SAFE_WRITE_BOUNDARY)

/* Magic values */
#define WINAPI_MAGIC              0x57494E41  // "WINA"
#define PROTOCOL_VERSION          1

/* Shared memory header */
struct shared_memory_header {
    uint32_t magic;
    uint32_t version;
    uint32_t request_count;
    uint32_t flags;
    uint64_t request_offset;
    uint64_t response_offset;
    uint32_t request_size;
    uint32_t response_size;
    uint32_t reserved[12];
};

/* Private context structure */
struct winapi_context {
    int socket_fd;
    int is_connected;
    void *shared_memory;
    struct shared_memory_header *header;
    void *request_buffer;
    void *response_buffer;
    uint32_t next_request_id;
};

/* Helper to get Windows host IP (default gateway) */
static int get_windows_host_ip(char* ip_buffer, size_t buffer_size) {
    FILE* fp;
    char line[256];

    // Get default gateway from route table
    fp = popen("ip route show default", "r");
    if (!fp) {
        return -1;
    }

    if (fgets(line, sizeof(line), fp)) {
        char* via_pos = strstr(line, "via ");
        if (via_pos) {
            via_pos += 4; // Skip "via "
            char* space_pos = strchr(via_pos, ' ');
            if (space_pos) {
                size_t ip_len = space_pos - via_pos;
                if (ip_len < buffer_size) {
                    strncpy(ip_buffer, via_pos, ip_len);
                    ip_buffer[ip_len] = '\0';
                    pclose(fp);
                    return 0;
                }
            }
        }
    }

    pclose(fp);
    return -1;
}

/* JSON Protocol Helpers */
static json_object* create_request(const char* api, uint32_t request_id) {
    json_object *root = json_object_new_object();
    json_object *api_obj = json_object_new_string(api);
    json_object *id_obj = json_object_new_int(request_id);
    json_object *version_obj = json_object_new_int(PROTOCOL_VERSION);

    json_object_object_add(root, "api", api_obj);
    json_object_object_add(root, "request_id", id_obj);
    json_object_object_add(root, "version", version_obj);

    return root;
}

static int send_json_request(int socket_fd, json_object *request) {
    const char *json_string = json_object_to_json_string(request);
    size_t json_len = strlen(json_string);

    // Send length first (4 bytes)
    uint32_t msg_len = htonl(json_len);
    if (send(socket_fd, &msg_len, sizeof(msg_len), 0) != sizeof(msg_len)) {
        return -1;
    }

    // Send JSON data
    if (send(socket_fd, json_string, json_len, 0) != (ssize_t)json_len) {
        return -1;
    }

    return 0;
}

static json_object* receive_json_response(int socket_fd) {
    // Receive length first
    uint32_t msg_len;
    if (recv(socket_fd, &msg_len, sizeof(msg_len), MSG_WAITALL) != sizeof(msg_len)) {
        return NULL;
    }

    msg_len = ntohl(msg_len);
    if (msg_len > 65536) { // Reasonable limit
        return NULL;
    }

    // Receive JSON data
    char *buffer = malloc(msg_len + 1);
    if (!buffer) return NULL;

    if (recv(socket_fd, buffer, msg_len, MSG_WAITALL) != (ssize_t)msg_len) {
        free(buffer);
        return NULL;
    }

    buffer[msg_len] = '\0';
    json_object *response = json_tokener_parse(buffer);
    free(buffer);

    return response;
}

/* Initialize the API remoting library */
winapi_handle_t winapi_init(void)
{
    struct winapi_context *ctx;
    //struct sockaddr_vm vsock_addr;
    struct sockaddr_in tcp_addr;
    char host_ip[64];
    int fd;
    int vsock_failed = 0;

    ctx = malloc(sizeof(*ctx));
    if (!ctx) {
        return NULL;
    }

    memset(ctx, 0, sizeof(*ctx));
    ctx->socket_fd = -1;
    ctx->next_request_id = 1;

    // Skip VSOCK and go directly to TCP for debugging
    printf("Skipping VSOCK, using TCP connection directly...\n");
    vsock_failed = 1;

    /*
    // Try VSOCK first (optimal performance) - DISABLED FOR DEBUGGING
    printf("Attempting VSOCK connection to Windows host...\n");
    fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (fd < 0) {
        printf("❌ VSOCK socket creation failed: %s\n", strerror(errno));
        vsock_failed = 1;
    } else {
        printf("✅ VSOCK socket created\n");

        // Connect to Windows host via VSOCK
        memset(&vsock_addr, 0, sizeof(vsock_addr));
        vsock_addr.svm_family = AF_VSOCK;
        vsock_addr.svm_cid = VMADDR_CID_HOST;  // Connect to host
        vsock_addr.svm_port = HYPERV_SOCKET_PORT;

        if (connect(fd, (struct sockaddr*)&vsock_addr, sizeof(vsock_addr)) < 0) {
            printf("❌ VSOCK connection failed: %s\n", strerror(errno));
            close(fd);
            vsock_failed = 1;
        } else {
            printf("✅ VSOCK connection successful\n");
            ctx->socket_fd = fd;
            ctx->is_connected = 1;
        }
    }
    */

    // Fallback to TCP if VSOCK failed
    if (vsock_failed) {
        printf("Using TCP connection...\n");

        // Get Windows host IP
        if (get_windows_host_ip(host_ip, sizeof(host_ip)) < 0) {
            printf("❌ Failed to determine Windows host IP address\n");
            free(ctx);
            return NULL;
        }
        printf("Windows host IP: %s\n", host_ip);

        // Create TCP socket
        fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            printf("❌ TCP socket creation failed: %s\n", strerror(errno));
            free(ctx);
            return NULL;
        }
        printf("✅ TCP socket created\n");

        // Setup address
        memset(&tcp_addr, 0, sizeof(tcp_addr));
        tcp_addr.sin_family = AF_INET;
        tcp_addr.sin_port = htons(TCP_FALLBACK_PORT);
        if (inet_pton(AF_INET, host_ip, &tcp_addr.sin_addr) <= 0) {
            printf("❌ Invalid host IP address: %s\n", host_ip);
            close(fd);
            free(ctx);
            return NULL;
        }

        // Set socket to non-blocking for connection timeout
        int flags = fcntl(fd, F_GETFL, 0);
        if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
            printf("⚠️  Warning: Could not set non-blocking mode\n");
        }

        // Connect to Windows host via TCP (with timeout)
        printf("Connecting to %s:%d...\n", host_ip, TCP_FALLBACK_PORT);
        int connect_result = connect(fd, (struct sockaddr*)&tcp_addr, sizeof(tcp_addr));

        if (connect_result < 0) {
            if (errno == EINPROGRESS) {
                // Connection in progress, wait with timeout
                fd_set write_fds;
                struct timeval timeout;
                timeout.tv_sec = 10;  // 10 second timeout
                timeout.tv_usec = 0;

                FD_ZERO(&write_fds);
                FD_SET(fd, &write_fds);

                int select_result = select(fd + 1, NULL, &write_fds, NULL, &timeout);
                if (select_result > 0) {
                    // Check if connection succeeded
                    int socket_error;
                    socklen_t len = sizeof(socket_error);
                    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socket_error, &len) < 0 || socket_error != 0) {
                        printf("❌ TCP connection failed: %s\n", strerror(socket_error ? socket_error : errno));
                        printf("   Make sure Windows service is running and listening on port %d\n", TCP_FALLBACK_PORT);
                        close(fd);
                        free(ctx);
                        return NULL;
                    }
                } else if (select_result == 0) {
                    printf("❌ TCP connection failed: Connection timeout\n");
                    printf("   Make sure Windows service is running and listening on port %d\n", TCP_FALLBACK_PORT);
                    close(fd);
                    free(ctx);
                    return NULL;
                } else {
                    printf("❌ TCP connection failed: %s\n", strerror(errno));
                    close(fd);
                    free(ctx);
                    return NULL;
                }
            } else {
                printf("❌ TCP connection failed: %s\n", strerror(errno));
                printf("   Make sure Windows service is running and listening on port %d\n", TCP_FALLBACK_PORT);
                close(fd);
                free(ctx);
                return NULL;
            }
        }

        // Restore blocking mode
        if (fcntl(fd, F_SETFL, flags) < 0) {
            printf("⚠️  Warning: Could not restore blocking mode\n");
        }

        printf("✅ TCP connection successful\n");
        printf("ℹ️  Using TCP mode - checking for shared memory...\n");
        ctx->socket_fd = fd;
        ctx->is_connected = 1;
    }

    // Try to map shared memory (works for both VSOCK and TCP on same machine)
    int shm_fd = open(SHARED_MEMORY_PATH, O_RDWR);
    if (shm_fd < 0) {
        printf("❌ Shared memory not available - using TCP-only mode\n");
        printf("   File not found: %s\n", SHARED_MEMORY_PATH);
        printf("   Error: %s\n", strerror(errno));
        printf("   Note: For zero-copy performance, ensure shared memory file exists\n");
        ctx->shared_memory = NULL;
        ctx->header = NULL;
        ctx->request_buffer = NULL;
        ctx->response_buffer = NULL;
    } else {
        ctx->shared_memory = mmap(NULL, SHARED_MEMORY_SIZE, PROT_READ | PROT_WRITE,
                                  MAP_SHARED, shm_fd, 0);
        close(shm_fd);

        if (ctx->shared_memory == MAP_FAILED) {
            printf("❌ Shared memory mapping failed - using TCP-only mode\n");
            printf("   Error: %s\n", strerror(errno));
            ctx->shared_memory = NULL;
            ctx->header = NULL;
            ctx->request_buffer = NULL;
            ctx->response_buffer = NULL;
        } else {
            // Set up memory layout
            ctx->header = (struct shared_memory_header*)ctx->shared_memory;
            ctx->request_buffer = (char*)ctx->shared_memory + HEADER_SIZE;
            ctx->response_buffer = (char*)ctx->shared_memory + HEADER_SIZE + REQUEST_BUFFER_SIZE;

            // Verify magic
            if (ctx->header->magic != WINAPI_MAGIC) {
                printf("Invalid shared memory magic: 0x%x (expected 0x%x)\n",
                       ctx->header->magic, WINAPI_MAGIC);
                munmap(ctx->shared_memory, SHARED_MEMORY_SIZE);
                close(fd);
                free(ctx);
                return NULL;
            }
            printf("✅ Shared memory connected for zero-copy transfers (TCP + shared memory hybrid)\n");
            printf("   Magic verified: 0x%X\n", ctx->header->magic);
        }
    }

    printf("Connected to Windows API remoting service\n");
    return ctx;
}

/* Cleanup the API remoting library */
void winapi_cleanup(winapi_handle_t handle)
{
    struct winapi_context *ctx = (struct winapi_context *)handle;

    if (ctx) {
        if (ctx->shared_memory && ctx->shared_memory != MAP_FAILED) {
            munmap(ctx->shared_memory, SHARED_MEMORY_SIZE);
        }
        if (ctx->is_connected && ctx->socket_fd >= 0) {
            close(ctx->socket_fd);
        }
        free(ctx);
    }
}

/* Echo API call */
int winapi_echo(winapi_handle_t handle, const char *input, char *output, size_t output_size)
{
    struct winapi_context *ctx = (struct winapi_context *)handle;
    json_object *request, *response;
    json_object *input_obj, *result_obj;
    const char *result_str;
    uint32_t request_id;
    size_t input_len;

    if (!ctx || !ctx->is_connected || !input || !output) {
        return -1;
    }

    input_len = strlen(input);
    if (input_len > 4096) { // Reasonable limit
        fprintf(stderr, "Input string too long\n");
        return -1;
    }

    // Create JSON request
    request_id = ctx->next_request_id++;
    request = create_request("echo", request_id);
    input_obj = json_object_new_string(input);
    json_object_object_add(request, "input", input_obj);

    // Send request
    if (send_json_request(ctx->socket_fd, request) < 0) {
        fprintf(stderr, "Failed to send echo request\n");
        json_object_put(request);
        return -1;
    }
    json_object_put(request);

    // Receive response
    response = receive_json_response(ctx->socket_fd);
    if (!response) {
        fprintf(stderr, "Failed to receive echo response\n");
        return -1;
    }

    // Parse response
    if (!json_object_object_get_ex(response, "result", &result_obj)) {
        fprintf(stderr, "Invalid echo response format\n");
        json_object_put(response);
        return -1;
    }

    result_str = json_object_get_string(result_obj);
    if (strlen(result_str) >= output_size) {
        fprintf(stderr, "Echo response too long\n");
        json_object_put(response);
        return -1;
    }

    strcpy(output, result_str);
    json_object_put(response);
    return 0;
}

/* Buffer test API call */
int winapi_buffer_test(winapi_handle_t handle,
                      winapi_buffer_t *buffers,
                      int buffer_count,
                      winapi_buffer_operation_t operation,
                      uint32_t test_pattern,
                      winapi_buffer_test_result_t *result)
{
    struct winapi_context *ctx = (struct winapi_context *)handle;
    json_object *request, *response;
    json_object *op_obj, *pattern_obj, *size_obj, *result_obj;
    uint32_t request_id;
    uint64_t total_size = 0;
    int i;

    if (!ctx || !ctx->is_connected || !buffers || buffer_count <= 0 || !result) {
        return -1;
    }

    // Calculate total buffer size
    for (i = 0; i < buffer_count; i++) {
        total_size += buffers[i].size;
    }

    // Determine transfer method based on buffer size and shared memory availability
    int use_socket_transfer;
    if (!ctx->request_buffer) {
        // No shared memory available, must use socket
        use_socket_transfer = 1;
        printf("[INFO] Using socket transfer (no shared memory available)\n");
    } else if (total_size > REQUEST_BUFFER_SIZE) {
        // Buffer too large for shared memory, use socket transfer
        use_socket_transfer = 1;
        printf("[INFO] Using socket transfer (buffer %zu bytes > shared memory %d bytes)\n", total_size, REQUEST_BUFFER_SIZE);
    } else {
        // Use shared memory for optimal performance
        use_socket_transfer = 0;
        printf("[INFO] Using shared memory transfer (%zu bytes)\n", total_size);
    }

    // Handle buffer data transfer
    if (operation == WINAPI_BUFFER_OP_WRITE || operation == WINAPI_BUFFER_OP_VERIFY) {
        if (!use_socket_transfer) {
            // Use shared memory (zero-copy)
            size_t offset = 0;
            for (i = 0; i < buffer_count; i++) {
                memcpy((char*)ctx->request_buffer + offset, buffers[i].data, buffers[i].size);
                offset += buffers[i].size;
            }
        } else {
            // Use socket transfer - buffer data will be sent after JSON request
        }
    }

    // Create JSON request
    request_id = ctx->next_request_id++;
    request = create_request("buffer_test", request_id);
    op_obj = json_object_new_int(operation);
    pattern_obj = json_object_new_int64((int64_t)test_pattern);  // Ensure unsigned values are handled correctly
    size_obj = json_object_new_int64(total_size);

    json_object_object_add(request, "operation", op_obj);
    json_object_object_add(request, "test_pattern", pattern_obj);
    json_object_object_add(request, "payload_size", size_obj);

    // Add flag for socket buffer transfer
    json_object *socket_transfer_obj = json_object_new_boolean(use_socket_transfer);
    json_object_object_add(request, "socket_transfer", socket_transfer_obj);


    // Send request
    if (send_json_request(ctx->socket_fd, request) < 0) {
        fprintf(stderr, "ERROR: Failed to send buffer test request: %s\n", strerror(errno));
        json_object_put(request);
        return -1;
    }
    json_object_put(request);

    // Send buffer data over socket if using socket transfer
    if (use_socket_transfer && (operation == WINAPI_BUFFER_OP_WRITE || operation == WINAPI_BUFFER_OP_VERIFY)) {
        for (i = 0; i < buffer_count; i++) {
            ssize_t sent = send(ctx->socket_fd, buffers[i].data, buffers[i].size, 0);
            if (sent != (ssize_t)buffers[i].size) {
                fprintf(stderr, "ERROR: Failed to send buffer data: sent %zd/%zu bytes, error: %s\n",
                        sent, buffers[i].size, strerror(errno));
                return -1;
            }
        }
    }

    // Receive response
    response = receive_json_response(ctx->socket_fd);
    if (!response) {
        fprintf(stderr, "ERROR: Failed to receive buffer test response: %s\n", strerror(errno));
        fprintf(stderr, "       This may indicate server crash or connection loss\n");
        return -1;
    }

    // Parse response
    if (!json_object_object_get_ex(response, "result", &result_obj)) {
        fprintf(stderr, "Invalid buffer test response format\n");
        json_object_put(response);
        return -1;
    }

    // Extract results
    json_object *bytes_obj, *checksum_obj, *status_obj;
    json_object_object_get_ex(result_obj, "bytes_processed", &bytes_obj);
    json_object_object_get_ex(result_obj, "checksum", &checksum_obj);
    json_object_object_get_ex(result_obj, "status", &status_obj);

    result->bytes_processed = json_object_get_int64(bytes_obj);
    result->checksum = json_object_get_int(checksum_obj);
    result->status = json_object_get_int(status_obj);

    // Handle buffer data reception
    if (operation == WINAPI_BUFFER_OP_READ && result->status == 0) {
        if (!use_socket_transfer) {
            // Use shared memory (zero-copy)
            size_t offset = 0;
            for (i = 0; i < buffer_count; i++) {
                memcpy(buffers[i].data, (char*)ctx->response_buffer + offset, buffers[i].size);
                offset += buffers[i].size;
            }
        } else {
            // Receive buffer data over socket
            for (i = 0; i < buffer_count; i++) {
                if (recv(ctx->socket_fd, buffers[i].data, buffers[i].size, MSG_WAITALL) != (ssize_t)buffers[i].size) {
                    fprintf(stderr, "Failed to receive buffer data\n");
                    json_object_put(response);
                    return -1;
                }
            }
        }
    }

    json_object_put(response);
    return result->status;
}

/* Performance test API call */
int winapi_perf_test(winapi_handle_t handle,
                    winapi_perf_test_params_t *params,
                    winapi_buffer_t *buffers,
                    int buffer_count,
                    winapi_perf_test_result_t *result)
{
    struct winapi_context *ctx = (struct winapi_context *)handle;
    json_object *request, *response;
    json_object *type_obj, *iter_obj, *bytes_obj, *result_obj;
    uint32_t request_id;
    uint64_t total_size = 0;
    int i;

    if (!ctx || !ctx->is_connected || !params || !result) {
        return -1;
    }

    if (buffers && buffer_count > 0) {
        for (i = 0; i < buffer_count; i++) {
            total_size += buffers[i].size;
        }
    }

    // Create JSON request
    request_id = ctx->next_request_id++;
    request = create_request("performance", request_id);
    type_obj = json_object_new_int(params->test_type);
    iter_obj = json_object_new_int(params->iterations);
    bytes_obj = json_object_new_int64(params->target_bytes);

    json_object_object_add(request, "test_type", type_obj);
    json_object_object_add(request, "iterations", iter_obj);
    json_object_object_add(request, "target_bytes", bytes_obj);

    // Send request
    if (send_json_request(ctx->socket_fd, request) < 0) {
        fprintf(stderr, "Failed to send performance test request\n");
        json_object_put(request);
        return -1;
    }
    json_object_put(request);

    // Receive response
    response = receive_json_response(ctx->socket_fd);
    if (!response) {
        fprintf(stderr, "Failed to receive performance test response\n");
        return -1;
    }

    // Parse response
    if (!json_object_object_get_ex(response, "result", &result_obj)) {
        fprintf(stderr, "Invalid performance test response format\n");
        json_object_put(response);
        return -1;
    }

    // Extract results
    json_object *min_obj, *max_obj, *avg_obj, *tput_obj, *completed_obj;
    json_object_object_get_ex(result_obj, "min_latency_ns", &min_obj);
    json_object_object_get_ex(result_obj, "max_latency_ns", &max_obj);
    json_object_object_get_ex(result_obj, "avg_latency_ns", &avg_obj);
    json_object_object_get_ex(result_obj, "throughput_mbps", &tput_obj);
    json_object_object_get_ex(result_obj, "iterations_completed", &completed_obj);

    result->min_latency_ns = json_object_get_int64(min_obj);
    result->max_latency_ns = json_object_get_int64(max_obj);
    result->avg_latency_ns = json_object_get_int64(avg_obj);
    result->throughput_mbps = json_object_get_int64(tput_obj);
    result->iterations_completed = json_object_get_int(completed_obj);

    json_object_put(response);
    return 0;
}

/* Helper function to allocate aligned buffer */
int winapi_alloc_buffer(winapi_buffer_t *buffer, size_t size)
{
    if (!buffer || size == 0) {
        return -1;
    }

    /* Allocate page-aligned memory for better performance */
    size_t aligned_size = (size + 4095) & ~4095;
    int ret = posix_memalign(&buffer->data, 4096, aligned_size);
    if (ret != 0 || !buffer->data) {
        return -1;
    }

    buffer->size = size;
    return 0;
}

/* Helper function to free buffer */
void winapi_free_buffer(winapi_buffer_t *buffer)
{
    if (buffer && buffer->data) {
        free(buffer->data);
        buffer->data = NULL;
        buffer->size = 0;
    }
}
