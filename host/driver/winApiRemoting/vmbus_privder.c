/*
 * Windows VMBus Provider Driver for API Remoting
 *
 * This driver provides VMBus channel services for Linux guests to make
 * API calls to the Windows host.
 */

#include <ntddk.h>
#include <wdf.h>
// #include <vmbus.h>  // Temporarily commented out
#include "../../../common/protocol.h"

/* Driver tag for memory allocations */
#define WINAPI_POOL_TAG 'WAPI'

/* Temporary VMBus type definitions until we find the real headers */
typedef PVOID VMBUS_CHANNEL;
typedef enum _VMBUS_CHANNEL_PACKET_TYPE {
    VmbusChannelPacketTypeDataInBand = 1,
    VmbusChannelPacketTypeDataUsingTransferPages = 2
} VMBUS_CHANNEL_PACKET_TYPE;

/* GUID is already defined in Windows headers, no need to redefine */

/* Forward declarations for event handlers */
VOID WinapiEvtChannelOpened(_In_ VMBUS_CHANNEL Channel);
VOID WinapiEvtChannelClosed(_In_ VMBUS_CHANNEL Channel);
VOID WinapiEvtChannelPacketReceived(
    _In_ VMBUS_CHANNEL Channel,
    _In_ VMBUS_CHANNEL_PACKET_TYPE PacketType,
    _In_ PVOID Buffer,
    _In_ UINT32 BufferLength
);

/* Event handler function pointer types */
typedef VOID (*PEVT_VMBUS_CHANNEL_OPENED)(_In_ VMBUS_CHANNEL Channel);
typedef VOID (*PEVT_VMBUS_CHANNEL_CLOSED)(_In_ VMBUS_CHANNEL Channel);
typedef VOID (*PEVT_VMBUS_CHANNEL_PACKET_RECEIVED)(
    _In_ VMBUS_CHANNEL Channel,
    _In_ VMBUS_CHANNEL_PACKET_TYPE PacketType,
    _In_ PVOID Buffer,
    _In_ UINT32 BufferLength
);

typedef struct _VMBUS_CHANNEL_INTERFACE {
    USHORT Size;
    USHORT Version;
    VMBUS_CHANNEL Channel;
    PEVT_VMBUS_CHANNEL_OPENED ChannelOpened;
    PEVT_VMBUS_CHANNEL_CLOSED ChannelClosed;
    PEVT_VMBUS_CHANNEL_PACKET_RECEIVED PacketReceived;
} VMBUS_CHANNEL_INTERFACE, *PVMBUS_CHANNEL_INTERFACE;

/* Define GUID for VMBus interface */
static const GUID GUID_VMBUS_INTERFACE_STANDARD = {
    0x6ac83d8f, 0x6e16, 0x4e5c,
    {0xab, 0x3d, 0xfd, 0x8c, 0x5a, 0x4b, 0x7e, 0x21}
};

/* Stub functions for VMBus operations */
WDFDEVICE VmbusChannelGetDevice(_In_ VMBUS_CHANNEL Channel) {
    UNREFERENCED_PARAMETER(Channel);
    return NULL; // Placeholder
}

NTSTATUS VmbusChannelSendPacket(
    _In_ VMBUS_CHANNEL Channel,
    _In_ PVOID Buffer,
    _In_ UINT32 BufferLength,
    _In_ UINT64 RequestId,
    _In_ VMBUS_CHANNEL_PACKET_TYPE PacketType,
    _In_ UINT32 Flags
) {
    UNREFERENCED_PARAMETER(Channel);
    UNREFERENCED_PARAMETER(Buffer);
    UNREFERENCED_PARAMETER(BufferLength);
    UNREFERENCED_PARAMETER(RequestId);
    UNREFERENCED_PARAMETER(PacketType);
    UNREFERENCED_PARAMETER(Flags);
    return STATUS_NOT_IMPLEMENTED;
}

/* VMBus channel context */
typedef struct _VMBUS_CHANNEL_CONTEXT {
    WDFDEVICE Device;
    VMBUS_CHANNEL Channel;
    WDFWORKITEM WorkItem;
    BOOLEAN ChannelOpened;
    WINAPI_MESSAGE_T PendingMessage;
} VMBUS_CHANNEL_CONTEXT, * PVMBUS_CHANNEL_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(VMBUS_CHANNEL_CONTEXT, GetChannelContext)

/* Function declarations */
DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD WinapiEvtDeviceAdd;
EVT_WDF_DEVICE_CONTEXT_CLEANUP WinapiEvtDeviceContextCleanup;
EVT_WDF_WORKITEM WinapiEvtWorkItem;

/* API handler function declarations */
NTSTATUS WinapiHandleEchoRequest(PWINAPI_MESSAGE_T Request, PWINAPI_MESSAGE_T Response);
NTSTATUS WinapiHandleBufferTestRequest(PWINAPI_MESSAGE_T Request, PWINAPI_MESSAGE_T Response);
NTSTATUS WinapiHandlePerfTestRequest(PWINAPI_MESSAGE_T Request, PWINAPI_MESSAGE_T Response);

/* Driver entry point */
NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT DriverObject,
    _In_ PUNICODE_STRING RegistryPath
)
{
    NTSTATUS status;
    WDF_DRIVER_CONFIG config;

    KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_INFO_LEVEL,
        "WinAPI Remoting Driver: DriverEntry\n"));

    /* Initialize the driver configuration */
    WDF_DRIVER_CONFIG_INIT(&config, WinapiEvtDeviceAdd);

    /* Create the driver object */
    status = WdfDriverCreate(
        DriverObject,
        RegistryPath,
        WDF_NO_OBJECT_ATTRIBUTES,
        &config,
        WDF_NO_HANDLE
    );

    if (!NT_SUCCESS(status)) {
        KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL,
            "WinAPI: WdfDriverCreate failed: 0x%x\n", status));
    }

    return status;
}

/* Device add callback */
NTSTATUS
WinapiEvtDeviceAdd(
    _In_ WDFDRIVER Driver,
    _Inout_ PWDFDEVICE_INIT DeviceInit
)
{
    NTSTATUS status;
    WDFDEVICE device;
    PVMBUS_CHANNEL_CONTEXT channelContext;
    WDF_OBJECT_ATTRIBUTES attributes;
    WDF_WORKITEM_CONFIG workItemConfig;
    VMBUS_CHANNEL_INTERFACE channelInterface;

    UNREFERENCED_PARAMETER(Driver);

    KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_INFO_LEVEL,
        "WinAPI: Device add\n"));

    /* Setup device context */
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, VMBUS_CHANNEL_CONTEXT);
    attributes.EvtCleanupCallback = WinapiEvtDeviceContextCleanup;

    /* Create the device */
    status = WdfDeviceCreate(&DeviceInit, &attributes, &device);
    if (!NT_SUCCESS(status)) {
        KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL,
            "WinAPI: WdfDeviceCreate failed: 0x%x\n", status));
        return status;
    }

    channelContext = GetChannelContext(device);
    channelContext->Device = device;
    channelContext->ChannelOpened = FALSE;

    /* Create work item for processing requests */
    WDF_WORKITEM_CONFIG_INIT(&workItemConfig, WinapiEvtWorkItem);
    WDF_OBJECT_ATTRIBUTES_INIT(&attributes);
    attributes.ParentObject = device;

    status = WdfWorkItemCreate(&workItemConfig, &attributes, &channelContext->WorkItem);
    if (!NT_SUCCESS(status)) {
        KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL,
            "WinAPI: WdfWorkItemCreate failed: 0x%x\n", status));
        return status;
    }

    /* Get VMBus channel interface */
    status = WdfFdoQueryForInterface(
        device,
        &GUID_VMBUS_INTERFACE_STANDARD,
        (PINTERFACE)&channelInterface,
        sizeof(VMBUS_CHANNEL_INTERFACE),
        1,
        NULL
    );

    if (!NT_SUCCESS(status)) {
        KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL,
            "WinAPI: Failed to get VMBus interface: 0x%x\n", status));
        return status;
    }

    /* Set up channel callbacks */
    channelInterface.ChannelOpened = (PEVT_VMBUS_CHANNEL_OPENED)WinapiEvtChannelOpened;
    channelInterface.ChannelClosed = (PEVT_VMBUS_CHANNEL_CLOSED)WinapiEvtChannelClosed;
    channelInterface.PacketReceived = (PEVT_VMBUS_CHANNEL_PACKET_RECEIVED)WinapiEvtChannelPacketReceived;

    channelContext->Channel = channelInterface.Channel;

    KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_INFO_LEVEL,
        "WinAPI: Device created successfully\n"));

    return status;
}

/* Device cleanup callback */
VOID
WinapiEvtDeviceContextCleanup(
    _In_ WDFOBJECT Device
)
{
    PVMBUS_CHANNEL_CONTEXT channelContext = GetChannelContext((WDFDEVICE)Device);

    KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_INFO_LEVEL,
        "WinAPI: Device cleanup\n"));

    if (channelContext->ChannelOpened) {
        /* Channel will be closed by VMBus subsystem */
        channelContext->ChannelOpened = FALSE;
    }
}

/* VMBus channel opened callback */
VOID
WinapiEvtChannelOpened(
    _In_ VMBUS_CHANNEL Channel
)
{
    PVMBUS_CHANNEL_CONTEXT channelContext;
    WDFDEVICE device;

    /* Get device from channel context */
    device = VmbusChannelGetDevice(Channel);
    channelContext = GetChannelContext(device);

    KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_INFO_LEVEL,
        "WinAPI: Channel opened\n"));

    channelContext->ChannelOpened = TRUE;
}

/* VMBus channel closed callback */
VOID
WinapiEvtChannelClosed(
    _In_ VMBUS_CHANNEL Channel
)
{
    PVMBUS_CHANNEL_CONTEXT channelContext;
    WDFDEVICE device;

    device = VmbusChannelGetDevice(Channel);
    channelContext = GetChannelContext(device);

    KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_INFO_LEVEL,
        "WinAPI: Channel closed\n"));

    channelContext->ChannelOpened = FALSE;
}

/* VMBus packet received callback */
VOID
WinapiEvtChannelPacketReceived(
    _In_ VMBUS_CHANNEL Channel,
    _In_ VMBUS_CHANNEL_PACKET_TYPE PacketType,
    _In_ PVOID Buffer,
    _In_ UINT32 BufferLength
)
{
    PVMBUS_CHANNEL_CONTEXT channelContext;
    WDFDEVICE device;
    PWINAPI_MESSAGE_T message;

    UNREFERENCED_PARAMETER(PacketType);

    device = VmbusChannelGetDevice(Channel);
    channelContext = GetChannelContext(device);

    KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_TRACE_LEVEL,
        "WinAPI: Packet received, size: %d\n", BufferLength));

    if (BufferLength < sizeof(WINAPI_MESSAGE_HEADER_T)) {
        KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL,
            "WinAPI: Packet too small: %d bytes\n", BufferLength));
        return;
    }

    message = (PWINAPI_MESSAGE_T)Buffer;

    /* Validate message */
    if (message->header.magic != WINAPI_MESSAGE_MAGIC) {
        KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL,
            "WinAPI: Invalid message magic: 0x%x\n", message->header.magic));
        return;
    }

    if (message->header.version != WINAPI_PROTOCOL_VERSION) {
        KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL,
            "WinAPI: Unsupported protocol version: %d\n", message->header.version));
        return;
    }

    /* Copy message to context and queue work item */
    RtlCopyMemory(&channelContext->PendingMessage, message, sizeof(WINAPI_MESSAGE_T));
    WdfWorkItemEnqueue(channelContext->WorkItem);
}

/* Work item callback for processing API requests */
VOID
WinapiEvtWorkItem(
    _In_ WDFWORKITEM WorkItem
)
{
    WDFDEVICE device = (WDFDEVICE)WdfWorkItemGetParentObject(WorkItem);
    PVMBUS_CHANNEL_CONTEXT channelContext = GetChannelContext(device);
    PWINAPI_MESSAGE_T request = &channelContext->PendingMessage;
    WINAPI_MESSAGE_T response;
    NTSTATUS status;

    KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_TRACE_LEVEL,
        "WinAPI: Processing API request %d\n", request->header.api_id));

    /* Initialize response */
    RtlZeroMemory(&response, sizeof(response));
    response.header.magic = WINAPI_MESSAGE_MAGIC;
    response.header.version = WINAPI_PROTOCOL_VERSION;
    response.header.message_type = WINAPI_MSG_RESPONSE;
    response.header.api_id = request->header.api_id;
    response.header.request_id = request->header.request_id;
    response.header.timestamp = KeQueryPerformanceCounter(NULL).QuadPart;

    /* Dispatch to appropriate handler */
    switch (request->header.api_id) {
    case WINAPI_API_ECHO:
        status = WinapiHandleEchoRequest(request, &response);
        break;

    case WINAPI_API_BUFFER_TEST:
        status = WinapiHandleBufferTestRequest(request, &response);
        break;

    case WINAPI_API_PERF_TEST:
        status = WinapiHandlePerfTestRequest(request, &response);
        break;

    default:
        KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL,
            "WinAPI: Unknown API ID: %d\n", request->header.api_id));
        status = STATUS_NOT_SUPPORTED;
        response.header.error_code = WINAPI_ERROR_INVALID_API;
        break;
    }

    if (!NT_SUCCESS(status)) {
        response.header.message_type = WINAPI_MSG_ERROR;
        if (response.header.error_code == 0) {
            response.header.error_code = WINAPI_ERROR_UNKNOWN;
        }
    }

    /* Send response back to guest */
    status = VmbusChannelSendPacket(
        channelContext->Channel,
        &response,
        sizeof(response),
        request->header.request_id,
        VmbusChannelPacketTypeDataInBand,
        0
    );

    if (!NT_SUCCESS(status)) {
        KdPrintEx((DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL,
            "WinAPI: Failed to send response: 0x%x\n", status));
    }
}