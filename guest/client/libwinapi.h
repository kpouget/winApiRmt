/*
 * Windows API Remoting Library - Public Header
 *
 * This header provides the public API for applications to communicate
 * with the Windows host via the VMBus remoting framework.
 */

#ifndef LIBWINAPI_H
#define LIBWINAPI_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle for the library context */
typedef void* winapi_handle_t;

/* Buffer structure for API calls */
typedef struct {
    void *data;
    size_t size;
} winapi_buffer_t;

/* Buffer operations */
typedef enum {
    WINAPI_BUFFER_OP_READ = 1,
    WINAPI_BUFFER_OP_WRITE = 2,
    WINAPI_BUFFER_OP_VERIFY = 3
} winapi_buffer_operation_t;

/* Buffer test result */
typedef struct {
    uint64_t bytes_processed;
    uint32_t checksum;
    int status;
} winapi_buffer_test_result_t;

/* Performance test types */
typedef enum {
    WINAPI_PERF_LATENCY = 1,
    WINAPI_PERF_THROUGHPUT = 2
} winapi_perf_test_type_t;

/* Performance test parameters */
typedef struct {
    winapi_perf_test_type_t test_type;
    uint32_t iterations;
    uint64_t target_bytes;
} winapi_perf_test_params_t;

/* Performance test results */
typedef struct {
    uint64_t min_latency_ns;
    uint64_t max_latency_ns;
    uint64_t avg_latency_ns;
    uint64_t throughput_mbps;
    uint32_t iterations_completed;
} winapi_perf_test_result_t;

/* Library initialization and cleanup */
winapi_handle_t winapi_init(void);
void winapi_cleanup(winapi_handle_t handle);

/* API calls */
int winapi_echo(winapi_handle_t handle, const char *input, char *output, size_t output_size);

int winapi_buffer_test(winapi_handle_t handle,
                      winapi_buffer_t *buffers,
                      int buffer_count,
                      winapi_buffer_operation_t operation,
                      uint32_t test_pattern,
                      winapi_buffer_test_result_t *result);

int winapi_perf_test(winapi_handle_t handle,
                    winapi_perf_test_params_t *params,
                    winapi_buffer_t *buffers,
                    int buffer_count,
                    winapi_perf_test_result_t *result);

/* Helper functions */
int winapi_alloc_buffer(winapi_buffer_t *buffer, size_t size);
void winapi_free_buffer(winapi_buffer_t *buffer);

#ifdef __cplusplus
}
#endif

#endif /* LIBWINAPI_H */