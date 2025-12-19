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
#include <json-c/json.h>       // For JSON protocol

#include "libwinapi.h"
#include "../../common/protocol.h"

/* Hyper-V Socket Configuration */
#define HYPERV_SOCKET_PORT        0x1234
#define VMADDR_CID_PARENT         0x2     // Connect to parent (Windows host)
#define SHARED_MEMORY_PATH        "/mnt/c/temp/winapi_shared_memory"
#define SHARED_MEMORY_SIZE        (8 * 1024 * 1024)  // 8MB
#define REQUEST_TIMEOUT_MS        5000

/* Shared Memory Layout */
#define HEADER_SIZE               4096
#define REQUEST_BUFFER_SIZE       (4 * 1024 * 1024)  // 4MB
#define RESPONSE_BUFFER_SIZE      (4 * 1024 * 1024)  // 4MB

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
    struct sockaddr_vm addr;
    int fd;

    ctx = malloc(sizeof(*ctx));
    if (!ctx) {
        return NULL;
    }

    memset(ctx, 0, sizeof(*ctx));
    ctx->socket_fd = -1;
    ctx->next_request_id = 1;

    // Create Hyper-V socket
    fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (fd < 0) {
        printf("Failed to create Hyper-V socket: %s\n", strerror(errno));
        free(ctx);
        return NULL;
    }

    // Connect to Windows host
    memset(&addr, 0, sizeof(addr));
    addr.svm_family = AF_VSOCK;
    addr.svm_cid = VMADDR_CID_HOST;  // Connect to host
    addr.svm_port = HYPERV_SOCKET_PORT;

    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        printf("Failed to connect to Windows host: %s\n", strerror(errno));
        close(fd);
        free(ctx);
        return NULL;
    }

    ctx->socket_fd = fd;
    ctx->is_connected = 1;

    // Map shared memory
    int shm_fd = open(SHARED_MEMORY_PATH, O_RDWR);
    if (shm_fd < 0) {
        printf("Failed to open shared memory: %s\n", strerror(errno));
        close(fd);
        free(ctx);
        return NULL;
    }

    ctx->shared_memory = mmap(NULL, SHARED_MEMORY_SIZE, PROT_READ | PROT_WRITE,
                              MAP_SHARED, shm_fd, 0);
    close(shm_fd);

    if (ctx->shared_memory == MAP_FAILED) {
        printf("Failed to map shared memory: %s\n", strerror(errno));
        close(fd);
        free(ctx);
        return NULL;
    }

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

    printf("Connected to Windows API remoting service\n");
    return ctx;
}

/* Cleanup the API remoting library */
void winapi_cleanup(winapi_handle_t handle)
{
    struct winapi_context *ctx = (struct winapi_context *)handle;

    if (ctx) {
        if (ctx->shared_memory != MAP_FAILED && ctx->shared_memory != NULL) {
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

    if (total_size > REQUEST_BUFFER_SIZE) {
        fprintf(stderr, "Total buffer size too large: %lu > %d\n", total_size, REQUEST_BUFFER_SIZE);
        return -1;
    }

    // Copy data to shared memory (for write operations)
    if (operation == WINAPI_BUFFER_OP_WRITE || operation == WINAPI_BUFFER_OP_VERIFY) {
        size_t offset = 0;
        for (i = 0; i < buffer_count; i++) {
            memcpy((char*)ctx->request_buffer + offset, buffers[i].data, buffers[i].size);
            offset += buffers[i].size;
        }
    }

    // Create JSON request
    request_id = ctx->next_request_id++;
    request = create_request("buffer_test", request_id);
    op_obj = json_object_new_int(operation);
    pattern_obj = json_object_new_int(test_pattern);
    size_obj = json_object_new_int64(total_size);

    json_object_object_add(request, "operation", op_obj);
    json_object_object_add(request, "test_pattern", pattern_obj);
    json_object_object_add(request, "payload_size", size_obj);

    // Send request
    if (send_json_request(ctx->socket_fd, request) < 0) {
        fprintf(stderr, "Failed to send buffer test request\n");
        json_object_put(request);
        return -1;
    }
    json_object_put(request);

    // Receive response
    response = receive_json_response(ctx->socket_fd);
    if (!response) {
        fprintf(stderr, "Failed to receive buffer test response\n");
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

    // Copy data from shared memory (for read operations)
    if (operation == WINAPI_BUFFER_OP_READ && result->status == 0) {
        size_t offset = 0;
        for (i = 0; i < buffer_count; i++) {
            memcpy(buffers[i].data, (char*)ctx->response_buffer + offset, buffers[i].size);
            offset += buffers[i].size;
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
