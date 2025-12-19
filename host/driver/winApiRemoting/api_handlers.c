/*
 * API Request Handlers for Windows VMBus Provider
 */

#include <ntddk.h>
#include <wdf.h>
#include "../../../common/protocol.h"

 /* Driver tag for memory allocations */
#define WINAPI_POOL_TAG 'WAPI'

/* Helper function to map guest physical address to host virtual address */
PVOID
WinapiMapGuestMemory(
    _In_ UINT64 GuestPhysicalAddress,
    _In_ UINT32 Size,
    _Out_ PMDL* Mdl
)
{
    PHYSICAL_ADDRESS physAddr;
    PVOID virtualAddr;

    physAddr.QuadPart = GuestPhysicalAddress;

    /* Create MDL for the guest physical memory */
    *Mdl = IoAllocateMdl(NULL, Size, FALSE, FALSE, NULL);
    if (*Mdl == NULL) {
        return NULL;
    }

    /* Map the physical pages */
    MmBuildMdlForNonPagedPool(*Mdl);

    /* Map to system virtual address space */
    virtualAddr = MmMapLockedPagesSpecifyCache(
        *Mdl,
        KernelMode,
        MmNonCached,
        NULL,
        FALSE,
        NormalPagePriority
    );

    if (virtualAddr == NULL) {
        IoFreeMdl(*Mdl);
        *Mdl = NULL;
    }

    return virtualAddr;
}

/* Helper function to unmap guest memory */
VOID
WinapiUnmapGuestMemory(
    _In_ PVOID VirtualAddress,
    _In_ PMDL Mdl
)
{
    if (VirtualAddress && Mdl) {
        MmUnmapLockedPages(VirtualAddress, Mdl);
        IoFreeMdl(Mdl);
    }
}

/* Simple checksum calculation for buffer verification */
UINT32
WinapiCalculateChecksum(
    _In_ PVOID Buffer,
    _In_ UINT32 Size
)
{
    PUCHAR bytes = (PUCHAR)Buffer;
    UINT32 checksum = 0;
    UINT32 i;

    for (i = 0; i < Size; i++) {
        checksum += bytes[i];
    }

    return checksum;
}

/* Echo API handler */
NTSTATUS
WinapiHandleEchoRequest(
    _In_ PWINAPI_MESSAGE_T Request,
    _Out_ PWINAPI_MESSAGE_T Response
)
{
    PWINAPI_ECHO_REQUEST_T echoReq;
    PWINAPI_ECHO_RESPONSE_T echoResp;
    UINT32 copyLen;

    KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_TRACE_LEVEL,
        "WinAPI: Handling echo request\n"));

    if (Request->header.inline_size < sizeof(WINAPI_ECHO_REQUEST_T)) {
        KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL,
            "WinAPI: Echo request too small\n"));
        Response->header.error_code = WINAPI_ERROR_INVALID_PARAMS;
        return STATUS_INVALID_PARAMETER;
    }

    echoReq = (PWINAPI_ECHO_REQUEST_T)Request->inline_data;
    echoResp = (PWINAPI_ECHO_RESPONSE_T)Response->inline_data;

    /* Validate input length */
    if (echoReq->input_len > sizeof(echoReq->input_data)) {
        KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL,
            "WinAPI: Echo input too large: %d\n", echoReq->input_len));
        Response->header.error_code = WINAPI_ERROR_INVALID_PARAMS;
        return STATUS_INVALID_PARAMETER;
    }

    /* Copy input to output with "Echo: " prefix */
    copyLen = min(echoReq->input_len, sizeof(echoResp->output_data) - 6);
    RtlCopyMemory(echoResp->output_data, "Echo: ", 6);
    RtlCopyMemory(echoResp->output_data + 6, echoReq->input_data, copyLen);
    echoResp->output_len = 6 + copyLen;

    Response->header.inline_size = sizeof(WINAPI_ECHO_RESPONSE_T);
    Response->header.error_code = WINAPI_OK;

    KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_TRACE_LEVEL,
        "WinAPI: Echo completed, output length: %d\n", echoResp->output_len));

    return STATUS_SUCCESS;
}

/* Buffer test API handler */
NTSTATUS
WinapiHandleBufferTestRequest(
    _In_ PWINAPI_MESSAGE_T Request,
    _Out_ PWINAPI_MESSAGE_T Response
)
{
    PWINAPI_BUFFER_TEST_REQUEST_T bufReq;
    PWINAPI_BUFFER_TEST_RESPONSE_T bufResp;
    UINT32 i;
    UINT64 totalBytes = 0;
    NTSTATUS status = STATUS_SUCCESS;

    KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_TRACE_LEVEL,
        "WinAPI: Handling buffer test request\n"));

    if (Request->header.inline_size < sizeof(WINAPI_BUFFER_TEST_REQUEST_T)) {
        KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL,
            "WinAPI: Buffer test request too small\n"));
        Response->header.error_code = WINAPI_ERROR_INVALID_PARAMS;
        return STATUS_INVALID_PARAMETER;
    }

    if (Request->header.buffer_count == 0) {
        KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL,
            "WinAPI: No buffers provided\n"));
        Response->header.error_code = WINAPI_ERROR_INVALID_PARAMS;
        return STATUS_INVALID_PARAMETER;
    }

    bufReq = (PWINAPI_BUFFER_TEST_REQUEST_T)Request->inline_data;
    bufResp = (PWINAPI_BUFFER_TEST_RESPONSE_T)Response->inline_data;

    /* Initialize response */
    bufResp->bytes_processed = 0;
    bufResp->checksum = 0;
    bufResp->status = WINAPI_OK;

    /* Process each buffer */
    for (i = 0; i < Request->header.buffer_count; i++) {
        PWINAPI_BUFFER_DESC_T bufDesc = &Request->buffers[i];
        PVOID mappedAddr;
        PMDL mdl;
        UINT32 bufferChecksum;

        if (bufDesc->size > WINAPI_MAX_BUFFER_SIZE) {
            KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL,
                "WinAPI: Buffer too large: %d bytes\n", bufDesc->size));
            bufResp->status = WINAPI_ERROR_BUFFER_TOO_LARGE;
            status = STATUS_INVALID_PARAMETER;
            break;
        }

        /* Map guest buffer to host virtual address */
        mappedAddr = WinapiMapGuestMemory(bufDesc->guest_pa, bufDesc->size, &mdl);
        if (mappedAddr == NULL) {
            KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL,
                "WinAPI: Failed to map buffer %d (GPA: 0x%llx, size: %d)\n",
                i, bufDesc->guest_pa, bufDesc->size));
            bufResp->status = WINAPI_ERROR_MEMORY_MAP_FAILED;
            status = STATUS_UNSUCCESSFUL;
            break;
        }

        /* Perform requested operation */
        switch (bufReq->operation) {
        case WINAPI_BUFFER_OP_READ:
            /* Just read and checksum the buffer */
            bufferChecksum = WinapiCalculateChecksum(mappedAddr, bufDesc->size);
            bufResp->checksum ^= bufferChecksum;
            break;

        case WINAPI_BUFFER_OP_WRITE:
            /* Fill buffer with test pattern */
            RtlFillMemory(mappedAddr, bufDesc->size, (UCHAR)(bufReq->test_pattern & 0xFF));
            bufferChecksum = WinapiCalculateChecksum(mappedAddr, bufDesc->size);
            bufResp->checksum ^= bufferChecksum;
            break;

        case WINAPI_BUFFER_OP_VERIFY:
            /* Verify buffer contains expected pattern */
        {
            PUCHAR bytes = (PUCHAR)mappedAddr;
            UINT32 j;
            UCHAR expectedByte = (UCHAR)(bufReq->test_pattern & 0xFF);
            BOOLEAN verifyOk = TRUE;

            for (j = 0; j < bufDesc->size; j++) {
                if (bytes[j] != expectedByte) {
                    verifyOk = FALSE;
                    break;
                }
            }

            if (!verifyOk) {
                bufResp->status = WINAPI_ERROR_UNKNOWN; /* Verification failed */
            }

            bufferChecksum = WinapiCalculateChecksum(mappedAddr, bufDesc->size);
            bufResp->checksum ^= bufferChecksum;
        }
        break;

        default:
            KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL,
                "WinAPI: Unknown buffer operation: %d\n", bufReq->operation));
            bufResp->status = WINAPI_ERROR_INVALID_PARAMS;
            WinapiUnmapGuestMemory(mappedAddr, mdl);
            status = STATUS_INVALID_PARAMETER;
            goto cleanup;
        }

        totalBytes += bufDesc->size;
        WinapiUnmapGuestMemory(mappedAddr, mdl);

        KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_TRACE_LEVEL,
            "WinAPI: Processed buffer %d: %d bytes\n", i, bufDesc->size));
    }

cleanup:
    bufResp->bytes_processed = totalBytes;
    Response->header.inline_size = sizeof(WINAPI_BUFFER_TEST_RESPONSE_T);
    Response->header.error_code = (NT_SUCCESS(status)) ? WINAPI_OK : bufResp->status;

    KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_TRACE_LEVEL,
        "WinAPI: Buffer test completed, processed %lld bytes\n", totalBytes));

    return status;
}

/* Performance test API handler */
NTSTATUS
WinapiHandlePerfTestRequest(
    _In_ PWINAPI_MESSAGE_T Request,
    _Out_ PWINAPI_MESSAGE_T Response
)
{
    PWINAPI_PERF_TEST_REQUEST_T perfReq;
    PWINAPI_PERF_TEST_RESPONSE_T perfResp;
    LARGE_INTEGER frequency, startTime, endTime;
    UINT64 elapsedTicks, elapsedNs;
    UINT32 i;

    KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_TRACE_LEVEL,
        "WinAPI: Handling performance test request\n"));

    if (Request->header.inline_size < sizeof(WINAPI_PERF_TEST_REQUEST_T)) {
        KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL,
            "WinAPI: Perf test request too small\n"));
        Response->header.error_code = WINAPI_ERROR_INVALID_PARAMS;
        return STATUS_INVALID_PARAMETER;
    }

    perfReq = (PWINAPI_PERF_TEST_REQUEST_T)Request->inline_data;
    perfResp = (PWINAPI_PERF_TEST_RESPONSE_T)Response->inline_data;

    KeQueryPerformanceCounter(&frequency);

    /* Initialize response */
    perfResp->min_latency_ns = 0xFFFFFFFFFFFFFFFFULL;
    perfResp->max_latency_ns = 0;
    perfResp->avg_latency_ns = 0;
    perfResp->throughput_mbps = 0;
    perfResp->iterations_completed = 0;

    switch (perfReq->test_type) {
    case WINAPI_PERF_LATENCY:
    {
        UINT64 totalLatency = 0;

        /* Measure latency for simple operations */
        for (i = 0; i < perfReq->iterations; i++) {
            startTime = KeQueryPerformanceCounter(NULL);

            /* Simulate work - memory copy */
            UCHAR tempBuffer[1024];
            RtlCopyMemory(tempBuffer, Request, min(sizeof(tempBuffer), sizeof(*Request)));

            endTime = KeQueryPerformanceCounter(NULL);

            elapsedTicks = endTime.QuadPart - startTime.QuadPart;
            elapsedNs = (elapsedTicks * 1000000000ULL) / frequency.QuadPart;

            if (elapsedNs < perfResp->min_latency_ns) {
                perfResp->min_latency_ns = elapsedNs;
            }
            if (elapsedNs > perfResp->max_latency_ns) {
                perfResp->max_latency_ns = elapsedNs;
            }

            totalLatency += elapsedNs;
        }

        perfResp->avg_latency_ns = totalLatency / perfReq->iterations;
        perfResp->iterations_completed = perfReq->iterations;
    }
    break;

    case WINAPI_PERF_THROUGHPUT:
        if (Request->header.buffer_count > 0 && perfReq->target_bytes > 0) {
            UINT64 totalBytesProcessed = 0;

            startTime = KeQueryPerformanceCounter(NULL);

            /* Process buffers multiple times to reach target bytes */
            while (totalBytesProcessed < perfReq->target_bytes) {
                for (i = 0; i < Request->header.buffer_count; i++) {
                    PWINAPI_BUFFER_DESC_T bufDesc = &Request->buffers[i];
                    PVOID mappedAddr;
                    PMDL mdl;

                    mappedAddr = WinapiMapGuestMemory(bufDesc->guest_pa, bufDesc->size, &mdl);
                    if (mappedAddr) {
                        /* Simulate work - calculate checksum */
                        WinapiCalculateChecksum(mappedAddr, bufDesc->size);
                        totalBytesProcessed += bufDesc->size;
                        WinapiUnmapGuestMemory(mappedAddr, mdl);
                    }

                    if (totalBytesProcessed >= perfReq->target_bytes) {
                        break;
                    }
                }
            }

            endTime = KeQueryPerformanceCounter(NULL);
            elapsedTicks = endTime.QuadPart - startTime.QuadPart;
            elapsedNs = (elapsedTicks * 1000000000ULL) / frequency.QuadPart;

            if (elapsedNs > 0) {
                /* Calculate throughput in MB/s */
                perfResp->throughput_mbps = (totalBytesProcessed * 1000ULL) / (elapsedNs / 1000000ULL);
            }
        }
        break;

    default:
        KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL,
            "WinAPI: Unknown performance test type: %d\n", perfReq->test_type));
        Response->header.error_code = WINAPI_ERROR_INVALID_PARAMS;
        return STATUS_INVALID_PARAMETER;
    }

    Response->header.inline_size = sizeof(WINAPI_PERF_TEST_RESPONSE_T);
    Response->header.error_code = WINAPI_OK;

    KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_TRACE_LEVEL,
        "WinAPI: Performance test completed\n"));

    return STATUS_SUCCESS;
}