/*
 * Test Client for Windows API Remoting
 *
 * This program demonstrates the basic functionality of the API remoting
 * framework, including echo calls, buffer operations, and performance tests.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/time.h>
#include <stdbool.h>

#include "libwinapi.h"

/* Test configuration */
#define TEST_BUFFER_SIZES_COUNT 8
static const size_t test_buffer_sizes[] = {
    4096,            /* 4KB */
    64 * 1024,       /* 64KB */
    256 * 1024,      /* 256KB */
    1024 * 1024,     /* 1MB */
    4 * 1024 * 1024, /* 4MB */
    8 * 1024 * 1024, /* 8MB */
    12 * 1024 * 1024, /* 12MB */
    15 * 1024 * 1024 /* 15MB - Max shared memory buffer */
};

/* Helper function to format bytes */
static void format_bytes(uint64_t bytes, char *buf, size_t buf_size)
{
    const char *units[] = {"B", "KB", "MB", "GB"};
    double size = bytes;
    int unit = 0;

    while (size >= 1024 && unit < 3) {
        size /= 1024;
        unit++;
    }

    snprintf(buf, buf_size, "%.2f %s", size, units[unit]);
}

/* Test echo functionality */
static int test_echo(winapi_handle_t handle)
{
    const char *test_messages[] = {
        "Hello, Windows!",
        "Testing API remoting",
        "VMBus communication works!",
        "This is a longer message to test buffer handling capabilities"
    };
    char response[1024];
    size_t i;

    printf("\n=== Echo API Test ===\n");

    for (i = 0; i < sizeof(test_messages) / sizeof(test_messages[0]); i++) {
        printf("Sending: \"%s\"\n", test_messages[i]);

        if (winapi_echo(handle, test_messages[i], response, sizeof(response)) < 0) {
            printf("ERROR: Echo failed for message %ld\n", i);
            return -1;
        }

        printf("Received: \"%s\"\n\n", response);
    }

    printf("Echo tests completed successfully!\n");
    return 0;
}

/* Test buffer operations */
static int test_buffer_operations(winapi_handle_t handle)
{
    winapi_buffer_t buffer;
    winapi_buffer_test_result_t result;
    uint32_t test_pattern = 0xDEADBEEF;
    char size_str[32];
    int i, ret = 0;

    printf("\n=== Buffer Operations Test ===\n");

    for (i = 0; i < TEST_BUFFER_SIZES_COUNT; i++) {
        size_t size = test_buffer_sizes[i];
        format_bytes(size, size_str, sizeof(size_str));

        printf("Testing %s buffer...\n", size_str);

        /* Allocate buffer */
        if (winapi_alloc_buffer(&buffer, size) < 0) {
            printf("ERROR: Failed to allocate %s buffer\n", size_str);
            ret = -1;
            continue;
        }

        /* Test 1: Write pattern to buffer */
        printf("  Writing test pattern...\n");
        if (winapi_buffer_test(handle, &buffer, 1, WINAPI_BUFFER_OP_WRITE,
                              test_pattern, &result) < 0) {
            printf(" FAILED\n");
            winapi_free_buffer(&buffer);
            ret = -1;
            continue;
        }
        printf(" OK (processed %llu bytes, checksum: 0x%08x)\n",
               (unsigned long long)result.bytes_processed, result.checksum);

        /* Test 2: Verify pattern in buffer */
        printf("  Verifying test pattern...\n");
        if (winapi_buffer_test(handle, &buffer, 1, WINAPI_BUFFER_OP_VERIFY,
                              test_pattern, &result) < 0) {
            printf(" FAILED\n");
            winapi_free_buffer(&buffer);
            ret = -1;
            continue;
        }
        if (result.status == 0) {
            printf(" OK\n");
        } else {
            printf(" FAILED (verification error)\n");
            ret = -1;
        }

        /* Test 3: Read buffer and get checksum */
        printf("  Reading buffer checksum...\n");
        if (winapi_buffer_test(handle, &buffer, 1, WINAPI_BUFFER_OP_READ,
                              0, &result) < 0) {
            printf(" FAILED\n");
            winapi_free_buffer(&buffer);
            ret = -1;
            continue;
        }
        printf(" OK (checksum: 0x%08x)\n", result.checksum);

        winapi_free_buffer(&buffer);
        printf("\n");
    }

    if (ret == 0) {
        printf("Buffer operation tests completed successfully!\n");
    }

    return ret;
}

/* Test multiple buffer operations */
static int test_multi_buffer(winapi_handle_t handle)
{
    winapi_buffer_t buffers[4];
    winapi_buffer_test_result_t result;
    uint32_t test_pattern = 0x12345678;
    int i;

    printf("\n=== Multi-Buffer Test ===\n");

    /* Allocate multiple buffers of different sizes */
    printf("Allocating buffers: 4KB, 64KB, 256KB, 1MB\n");
    for (i = 0; i < 4; i++) {
        if (winapi_alloc_buffer(&buffers[i], test_buffer_sizes[i]) < 0) {
            printf("ERROR: Failed to allocate buffer %d\n", i);
            goto cleanup;
        }
    }

    /* Write pattern to all buffers */
    printf("Writing test pattern to all buffers...\n");
    if (winapi_buffer_test(handle, buffers, 4, WINAPI_BUFFER_OP_WRITE,
                          test_pattern, &result) < 0) {
        printf(" FAILED\n");
        goto cleanup;
    }
    printf(" OK\n");
    printf("  Total processed: %llu bytes\n", (unsigned long long)result.bytes_processed);
    printf("  Combined checksum: 0x%08x\n", result.checksum);

    /* Verify pattern in all buffers */
    printf("Verifying test pattern in all buffers...\n");
    if (winapi_buffer_test(handle, buffers, 4, WINAPI_BUFFER_OP_VERIFY,
                          test_pattern, &result) < 0) {
        printf(" FAILED\n");
        goto cleanup;
    }
    if (result.status == 0) {
        printf(" OK\n");
    } else {
        printf(" FAILED (verification error)\n");
        goto cleanup;
    }

    printf("Multi-buffer test completed successfully!\n");

    /* Cleanup */
    for (i = 0; i < 4; i++) {
        winapi_free_buffer(&buffers[i]);
    }
    return 0;

cleanup:
    for (i = 0; i < 4; i++) {
        winapi_free_buffer(&buffers[i]);
    }
    return -1;
}

/* Test latency performance */
static int test_latency_performance(winapi_handle_t handle)
{
    winapi_perf_test_params_t params;
    winapi_perf_test_result_t result;

    printf("\n=== Latency Performance Test ===\n");

    params.test_type = WINAPI_PERF_LATENCY;
    params.iterations = 1000;
    params.target_bytes = 0;

    printf("Running 1000 latency measurements...\n");
    if (winapi_perf_test(handle, &params, NULL, 0, &result) < 0) {
        printf("ERROR: Latency test failed\n");
        return -1;
    }

    printf("Results:\n");
    printf("  Iterations completed: %u\n", result.iterations_completed);
    printf("  Min latency: %llu ns (%.2f μs)\n",
           (unsigned long long)result.min_latency_ns,
           result.min_latency_ns / 1000.0);
    printf("  Max latency: %llu ns (%.2f μs)\n",
           (unsigned long long)result.max_latency_ns,
           result.max_latency_ns / 1000.0);
    printf("  Avg latency: %llu ns (%.2f μs)\n",
           (unsigned long long)result.avg_latency_ns,
           result.avg_latency_ns / 1000.0);

    return 0;
}

/* Test throughput performance */
static int test_throughput_performance(winapi_handle_t handle)
{
    winapi_buffer_t buffer;
    winapi_perf_test_params_t params;
    winapi_perf_test_result_t result;
    char size_str[32];

    printf("\n=== Throughput Performance Test ===\n");

    /* Use 4MB buffer for throughput test */
    size_t buffer_size = 4 * 1024 * 1024;
    format_bytes(buffer_size, size_str, sizeof(size_str));

    printf("Allocating %s buffer for throughput test...\n", size_str);
    if (winapi_alloc_buffer(&buffer, buffer_size) < 0) {
        printf("ERROR: Failed to allocate buffer\n");
        return -1;
    }

    params.test_type = WINAPI_PERF_THROUGHPUT;
    params.iterations = 0;
    params.target_bytes = 100 * 1024 * 1024; /* 100MB target */

    printf("Running throughput test (target: 100MB)...\n");
    if (winapi_perf_test(handle, &params, &buffer, 1, &result) < 0) {
        printf("ERROR: Throughput test failed\n");
        winapi_free_buffer(&buffer);
        return -1;
    }

    printf("Results:\n");
    printf("  Throughput: %llu MB/s\n", (unsigned long long)result.throughput_mbps);

    /* Categorize performance */
    if (result.throughput_mbps > 1000) {
        printf("  Performance: Excellent (>1GB/s)\n");
    } else if (result.throughput_mbps > 500) {
        printf("  Performance: Good (>500MB/s)\n");
    } else if (result.throughput_mbps > 100) {
        printf("  Performance: Fair (>100MB/s)\n");
    } else {
        printf("  Performance: Poor (<100MB/s)\n");
    }

    winapi_free_buffer(&buffer);
    return 0;
}

/* Test dynamic shared memory buffers */
static int test_dynamic_shared_buffers(winapi_handle_t handle)
{
    winapi_shared_buffer_t buffers[3];
    size_t buffer_sizes[] = {
        1024 * 1024,     /* 1MB */
        8 * 1024 * 1024, /* 8MB */
        32 * 1024 * 1024 /* 32MB */
    };
    int i, ret = 0;

    printf("\n=== Dynamic Shared Buffer Test ===\n");

    for (i = 0; i < 3; i++) {
        char size_str[32];
        format_bytes(buffer_sizes[i], size_str, sizeof(size_str));

        printf("Testing %s dynamic buffer...\n", size_str);

        // Allocate dynamic shared buffer
        if (winapi_alloc_shared_buffer(handle, buffer_sizes[i], &buffers[i]) < 0) {
            printf("ERROR: Failed to allocate %s shared buffer\n", size_str);
            ret = -1;
            continue;
        }

        // Fill buffer with test pattern
        printf("  Filling buffer with test pattern...\n");
        uint32_t *data = (uint32_t *)buffers[i].data;
        uint32_t pattern = 0xABCDEF00 + i;
        size_t uint32_count = buffer_sizes[i] / sizeof(uint32_t);

        for (size_t j = 0; j < uint32_count; j++) {
            data[j] = pattern;
        }

        // Send to host for processing
        printf("  Sending to host for processing...\n");
        if (winapi_process_shared_buffer(handle, &buffers[i], "process") < 0) {
            printf("ERROR: Failed to process shared buffer\n");
            winapi_free_shared_buffer(&buffers[i]);
            ret = -1;
            continue;
        }

        // Verify buffer content is still intact
        printf("  Verifying buffer integrity...\n");
        bool integrity_ok = true;
        for (size_t j = 0; j < uint32_count && j < 1000; j++) { // Check first 1000 elements
            if (data[j] != pattern) {
                integrity_ok = false;
                break;
            }
        }

        if (integrity_ok) {
            printf("  ✅ Buffer integrity verified\n");
        } else {
            printf("  ❌ Buffer integrity check failed\n");
            ret = -1;
        }

        // Clean up
        winapi_free_shared_buffer(&buffers[i]);
        printf("  ✅ Buffer cleaned up\n\n");
    }

    if (ret == 0) {
        printf("Dynamic shared buffer tests completed successfully!\n");
    } else {
        printf("Some dynamic shared buffer tests failed.\n");
    }

    return ret;
}

/* Main test function */
int main(int argc, char *argv[])
{
    winapi_handle_t handle;
    int test_mask = 0xFF; /* Run all tests by default */
    int i;

    printf("Windows API Remoting Test Client\n");
    printf("================================\n");

    /* Parse command line arguments */
    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--echo-only") == 0) {
            test_mask = 0x01;
        } else if (strcmp(argv[i], "--buffer-only") == 0) {
            test_mask = 0x02;
        } else if (strcmp(argv[i], "--perf-only") == 0) {
            test_mask = 0x04;
        } else if (strcmp(argv[i], "--shared-only") == 0) {
            test_mask = 0x08;
        } else if (strcmp(argv[i], "--help") == 0) {
            printf("Usage: %s [options]\n", argv[0]);
            printf("Options:\n");
            printf("  --echo-only    Run only echo tests\n");
            printf("  --buffer-only  Run only buffer tests\n");
            printf("  --perf-only    Run only performance tests\n");
            printf("  --shared-only  Run only dynamic shared buffer tests\n");
            printf("  --help         Show this help\n");
            return 0;
        }
    }

    /* Initialize the library */
    handle = winapi_init();
    if (!handle) {
        printf("ERROR: Failed to initialize API remoting library\n");
        printf("Make sure Windows service is running and network connectivity is available\n");
        return 1;
    }

    printf("Connected to Windows host successfully!\n");

    /* Run tests based on mask */
    int overall_result = 0;

    if (test_mask & 0x01) {
        if (test_echo(handle) < 0) {
            overall_result = 1;
        }
    }

    if (test_mask & 0x02) {
        if (test_buffer_operations(handle) < 0) {
            overall_result = 1;
        }
        if (test_multi_buffer(handle) < 0) {
            overall_result = 1;
        }
    }

    if (test_mask & 0x04) {
        if (test_latency_performance(handle) < 0) {
            overall_result = 1;
        }
        if (test_throughput_performance(handle) < 0) {
            overall_result = 1;
        }
    }

    if (test_mask & 0x08) {
        if (test_dynamic_shared_buffers(handle) < 0) {
            overall_result = 1;
        }
    }

    /* Cleanup */
    winapi_cleanup(handle);

    printf("\n=== Test Summary ===\n");
    if (overall_result == 0) {
        printf("ALL TESTS PASSED!\n");
        printf("The API remoting framework is working correctly.\n");
    } else {
        printf("SOME TESTS FAILED!\n");
        printf("Check the output above for details.\n");
    }

    return overall_result;
}
