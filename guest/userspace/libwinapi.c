/*
 * User-space library for Windows API Remoting
 *
 * This library provides a simple C API for applications to make
 * API calls to the Windows host via the VMBus driver.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#include "libwinapi.h"
#include "../../common/protocol.h"

/* Private context structure */
struct winapi_context {
    int fd;
    int is_open;
};

/* IOCTL structures (duplicate from kernel driver) */
struct winapi_ioctl_echo {
    char input[WINAPI_MAX_INLINE_DATA];
    char output[WINAPI_MAX_INLINE_DATA];
    uint32_t input_len;
    uint32_t output_len;
};

struct winapi_ioctl_buffer_test {
    void *buffers[WINAPI_MAX_BUFFERS];
    uint32_t buffer_sizes[WINAPI_MAX_BUFFERS];
    uint32_t buffer_count;
    uint32_t operation;
    uint32_t test_pattern;
    uint64_t bytes_processed;
    uint32_t checksum;
    int status;
};

struct winapi_ioctl_perf_test {
    uint32_t test_type;
    uint32_t iterations;
    uint64_t target_bytes;
    void *buffers[WINAPI_MAX_BUFFERS];
    uint32_t buffer_sizes[WINAPI_MAX_BUFFERS];
    uint32_t buffer_count;
    uint64_t min_latency_ns;
    uint64_t max_latency_ns;
    uint64_t avg_latency_ns;
    uint64_t throughput_mbps;
    uint32_t iterations_completed;
};

/* IOCTL definitions */
#define WINAPI_IOC_MAGIC 'W'
#define WINAPI_IOC_ECHO          _IOWR(WINAPI_IOC_MAGIC, 1, struct winapi_ioctl_echo)
#define WINAPI_IOC_BUFFER_TEST   _IOWR(WINAPI_IOC_MAGIC, 2, struct winapi_ioctl_buffer_test)
#define WINAPI_IOC_PERF_TEST     _IOWR(WINAPI_IOC_MAGIC, 3, struct winapi_ioctl_perf_test)

/* Initialize the API remoting library */
winapi_handle_t winapi_init(void)
{
    struct winapi_context *ctx;

    ctx = malloc(sizeof(*ctx));
    if (!ctx) {
        return NULL;
    }

    ctx->fd = open("/dev/winapi", O_RDWR);
    if (ctx->fd < 0) {
        fprintf(stderr, "Failed to open /dev/winapi: %s\n", strerror(errno));
        free(ctx);
        return NULL;
    }

    ctx->is_open = 1;
    return ctx;
}

/* Cleanup the API remoting library */
void winapi_cleanup(winapi_handle_t handle)
{
    struct winapi_context *ctx = (struct winapi_context *)handle;

    if (ctx) {
        if (ctx->is_open && ctx->fd >= 0) {
            close(ctx->fd);
        }
        free(ctx);
    }
}

/* Echo API call */
int winapi_echo(winapi_handle_t handle, const char *input, char *output, size_t output_size)
{
    struct winapi_context *ctx = (struct winapi_context *)handle;
    struct winapi_ioctl_echo args;
    size_t input_len;
    int ret;

    if (!ctx || !input || !output) {
        return -1;
    }

    input_len = strlen(input);
    if (input_len >= sizeof(args.input)) {
        fprintf(stderr, "Input string too long\n");
        return -1;
    }

    memset(&args, 0, sizeof(args));
    strcpy(args.input, input);
    args.input_len = input_len;

    ret = ioctl(ctx->fd, WINAPI_IOC_ECHO, &args);
    if (ret < 0) {
        fprintf(stderr, "Echo IOCTL failed: %s\n", strerror(errno));
        return -1;
    }

    /* Copy output, ensuring null termination */
    size_t copy_len = (args.output_len < output_size - 1) ? args.output_len : output_size - 1;
    memcpy(output, args.output, copy_len);
    output[copy_len] = '\0';

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
    struct winapi_ioctl_buffer_test args;
    int i, ret;

    if (!ctx || !buffers || buffer_count <= 0 || buffer_count > WINAPI_MAX_BUFFERS || !result) {
        return -1;
    }

    memset(&args, 0, sizeof(args));
    args.buffer_count = buffer_count;
    args.operation = operation;
    args.test_pattern = test_pattern;

    for (i = 0; i < buffer_count; i++) {
        args.buffers[i] = buffers[i].data;
        args.buffer_sizes[i] = buffers[i].size;
    }

    ret = ioctl(ctx->fd, WINAPI_IOC_BUFFER_TEST, &args);
    if (ret < 0) {
        fprintf(stderr, "Buffer test IOCTL failed: %s\n", strerror(errno));
        return -1;
    }

    /* Copy results */
    result->bytes_processed = args.bytes_processed;
    result->checksum = args.checksum;
    result->status = args.status;

    return 0;
}

/* Performance test API call */
int winapi_perf_test(winapi_handle_t handle,
                    winapi_perf_test_params_t *params,
                    winapi_buffer_t *buffers,
                    int buffer_count,
                    winapi_perf_test_result_t *result)
{
    struct winapi_context *ctx = (struct winapi_context *)handle;
    struct winapi_ioctl_perf_test args;
    int i, ret;

    if (!ctx || !params || !result) {
        return -1;
    }

    if (buffer_count > WINAPI_MAX_BUFFERS) {
        return -1;
    }

    memset(&args, 0, sizeof(args));
    args.test_type = params->test_type;
    args.iterations = params->iterations;
    args.target_bytes = params->target_bytes;
    args.buffer_count = buffer_count;

    for (i = 0; i < buffer_count; i++) {
        args.buffers[i] = buffers[i].data;
        args.buffer_sizes[i] = buffers[i].size;
    }

    ret = ioctl(ctx->fd, WINAPI_IOC_PERF_TEST, &args);
    if (ret < 0) {
        fprintf(stderr, "Performance test IOCTL failed: %s\n", strerror(errno));
        return -1;
    }

    /* Copy results */
    result->min_latency_ns = args.min_latency_ns;
    result->max_latency_ns = args.max_latency_ns;
    result->avg_latency_ns = args.avg_latency_ns;
    result->throughput_mbps = args.throughput_mbps;
    result->iterations_completed = args.iterations_completed;

    return 0;
}

/* Helper function to allocate aligned buffers for better performance */
int winapi_alloc_buffer(winapi_buffer_t *buffer, size_t size)
{
    if (!buffer || size == 0) {
        return -1;
    }

    /* Allocate page-aligned memory for better performance */
    buffer->data = aligned_alloc(4096, (size + 4095) & ~4095);
    if (!buffer->data) {
        return -1;
    }

    buffer->size = size;
    return 0;
}

/* Helper function to free allocated buffers */
void winapi_free_buffer(winapi_buffer_t *buffer)
{
    if (buffer && buffer->data) {
        free(buffer->data);
        buffer->data = NULL;
        buffer->size = 0;
    }
}