#ifndef WINAPI_REMOTING_PROTOCOL_H
#define WINAPI_REMOTING_PROTOCOL_H

#include <stdint.h>

/* Protocol version */
#define WINAPI_PROTOCOL_VERSION 1

/* VMBus channel GUID for our service */
#define WINAPI_VMBUS_GUID "6ac83d8f-6e16-4e5c-ab3d-fd8c5a4b7e21"

/* Message types */
typedef enum {
    WINAPI_MSG_REQUEST = 1,
    WINAPI_MSG_RESPONSE = 2,
    WINAPI_MSG_ERROR = 3
} winapi_message_type_t;

/* API function IDs */
typedef enum {
    WINAPI_API_ECHO = 1,
    WINAPI_API_BUFFER_TEST = 2,
    WINAPI_API_PERF_TEST = 3
} winapi_api_id_t;

/* Error codes */
typedef enum {
    WINAPI_OK = 0,
    WINAPI_ERROR_INVALID_API = -1,
    WINAPI_ERROR_INVALID_PARAMS = -2,
    WINAPI_ERROR_MEMORY_MAP_FAILED = -3,
    WINAPI_ERROR_BUFFER_TOO_LARGE = -4,
    WINAPI_ERROR_UNKNOWN = -99
} winapi_error_t;

/* Maximum buffer count per request */
#define WINAPI_MAX_BUFFERS 8
#define WINAPI_MAX_INLINE_DATA 3072
#define WINAPI_MAX_BUFFER_SIZE (64 * 1024 * 1024) /* 64MB max per buffer */

/* Shared buffer descriptor */
typedef struct {
    uint64_t guest_pa;      /* Guest Physical Address */
    uint32_t size;          /* Buffer size in bytes */
    uint32_t flags;         /* Buffer flags (read/write/etc) */
} winapi_buffer_desc_t;

/* Message header (fixed size: 64 bytes) */
typedef struct {
    uint32_t magic;         /* 0xCAFEBABE */
    uint32_t version;       /* Protocol version */
    uint32_t message_type;  /* Request/Response/Error */
    uint32_t api_id;        /* API function ID */
    uint64_t request_id;    /* Unique request identifier */
    uint32_t buffer_count;  /* Number of shared buffers */
    uint32_t inline_size;   /* Size of inline data */
    int32_t  error_code;    /* Error code (for responses) */
    uint32_t flags;         /* Message flags */
    uint64_t timestamp;     /* Timestamp for performance measurement */
    uint32_t reserved[6];   /* Padding to 64 bytes */
} winapi_message_header_t;

/* Complete message structure */
typedef struct {
    winapi_message_header_t header;
    winapi_buffer_desc_t buffers[WINAPI_MAX_BUFFERS];
    uint8_t inline_data[WINAPI_MAX_INLINE_DATA];
} winapi_message_t;

/* Buffer flags */
#define WINAPI_BUFFER_READ      0x01
#define WINAPI_BUFFER_WRITE     0x02
#define WINAPI_BUFFER_READWRITE 0x03

/* Message flags */
#define WINAPI_MSG_FLAG_SYNC    0x01  /* Synchronous call */
#define WINAPI_MSG_FLAG_ASYNC   0x02  /* Asynchronous call */

/* Magic number for validation */
#define WINAPI_MESSAGE_MAGIC 0xCAFEBABE

/* API-specific structures */

/* Echo API */
typedef struct {
    uint32_t input_len;
    char input_data[WINAPI_MAX_INLINE_DATA - sizeof(uint32_t)];
} winapi_echo_request_t;

typedef struct {
    uint32_t output_len;
    char output_data[WINAPI_MAX_INLINE_DATA - sizeof(uint32_t)];
} winapi_echo_response_t;

/* Buffer test API */
typedef struct {
    uint32_t test_pattern;  /* Pattern to fill/verify buffer */
    uint32_t operation;     /* READ, WRITE, or VERIFY */
} winapi_buffer_test_request_t;

typedef struct {
    uint64_t bytes_processed;
    uint32_t checksum;
    uint32_t status;
} winapi_buffer_test_response_t;

/* Buffer test operations */
#define WINAPI_BUFFER_OP_READ   1
#define WINAPI_BUFFER_OP_WRITE  2
#define WINAPI_BUFFER_OP_VERIFY 3

/* Performance test API */
typedef struct {
    uint32_t test_type;     /* Latency or throughput test */
    uint32_t iterations;    /* Number of test iterations */
    uint64_t target_bytes;  /* Target data size for throughput test */
} winapi_perf_test_request_t;

typedef struct {
    uint64_t min_latency_ns;
    uint64_t max_latency_ns;
    uint64_t avg_latency_ns;
    uint64_t throughput_mbps;
    uint32_t iterations_completed;
} winapi_perf_test_response_t;

/* Performance test types */
#define WINAPI_PERF_LATENCY     1
#define WINAPI_PERF_THROUGHPUT  2

/* Helper macros */
#define WINAPI_ALIGN_UP(x, align) (((x) + (align) - 1) & ~((align) - 1))
#define WINAPI_PAGE_SIZE 4096
#define WINAPI_ALIGN_PAGE(x) WINAPI_ALIGN_UP(x, WINAPI_PAGE_SIZE)

#endif /* WINAPI_REMOTING_PROTOCOL_H */