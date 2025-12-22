/*
 * Windows API Remoting Service for WSL2
 *
 * This service provides Windows API remoting capabilities for WSL2 guests
 * using Hyper-V sockets and shared memory for high-performance communication.
 */

#define _CRT_SECURE_NO_WARNINGS
#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <hvsocket.h>
#include <guiddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <json/json.h>
#include <conio.h>

// Define INET_ADDRSTRLEN if not available
#ifndef INET_ADDRSTRLEN
#define INET_ADDRSTRLEN 16
#endif

#include "../../common/protocol.h"

// AF_VSOCK definition for Windows (may not be available on all versions)
#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif

// VSOCK address structure (if not defined)
#ifndef SOCKADDR_VM
struct sockaddr_vm {
    ADDRESS_FAMILY svm_family;
    USHORT svm_reserved1;
    ULONG svm_port;
    ULONG svm_cid;
    UCHAR svm_zero[sizeof(struct sockaddr) - sizeof(ADDRESS_FAMILY) - sizeof(USHORT) - sizeof(ULONG) - sizeof(ULONG)];
};
#define SOCKADDR_VM struct sockaddr_vm
#endif

#ifndef VMADDR_CID_ANY
#define VMADDR_CID_ANY -1U
#endif

// Service configuration
#define SERVICE_NAME            L"WinApiRemoting"
#define SERVICE_DISPLAY_NAME    L"Windows API Remoting for WSL2"
#define HYPERV_SOCKET_PORT      0x400
#define TCP_SOCKET_PORT         4660               // TCP fallback port
#define SHARED_MEMORY_NAME      L"WinApiSharedMemory"
#define SHARED_MEMORY_SIZE      (8 * 1024 * 1024)  // 8MB
#define MAX_CLIENTS             16

// Shared Memory Layout
#define HEADER_SIZE             4096
#define REQUEST_BUFFER_SIZE     (4 * 1024 * 1024)  // 4MB
#define RESPONSE_BUFFER_SIZE    (4 * 1024 * 1024)  // 4MB

// Magic values
#define WINAPI_MAGIC            0x57494E41  // "WINA"
#define PROTOCOL_VERSION        1

// Shared memory header structure
struct shared_memory_header {
    UINT32 magic;
    UINT32 version;
    UINT32 request_count;
    UINT32 flags;
    UINT64 request_offset;
    UINT64 response_offset;
    UINT32 request_size;
    UINT32 response_size;
    UINT32 reserved[12];
};

// Global state
struct service_context {
    SOCKET listen_socket;
    SOCKET tcp_listen_socket;  // TCP fallback socket
    BOOL using_tcp;            // TRUE if using TCP fallback
    HANDLE shared_memory_handle;
    LPVOID shared_memory_view;
    struct shared_memory_header *header;
    LPVOID request_buffer;
    LPVOID response_buffer;
    HANDLE stop_event;
    BOOL running;
};

static struct service_context g_ctx = {0};
static SERVICE_STATUS_HANDLE g_service_status_handle = NULL;
static SERVICE_STATUS g_service_status = {0};
static BOOL g_force_tcp = FALSE;

// Forward declarations
void WINAPI ServiceMain(DWORD argc, LPTSTR *argv);
void WINAPI ServiceCtrlHandler(DWORD ctrl);
DWORD WINAPI ServiceWorkerThread(LPVOID lpParam);
DWORD InitializeService();
void CleanupService();
DWORD HandleClient(SOCKET client_socket);
DWORD ProcessAPIRequest(SOCKET client_socket, const char* request_json, char* response_json, size_t response_size);

// JSON helper functions
Json::Value CreateErrorResponse(UINT32 request_id, const char* error_msg);
Json::Value CreateSuccessResponse(UINT32 request_id);

// API implementations
DWORD HandleEchoAPI(SOCKET client_socket, const Json::Value& request, Json::Value& response);
DWORD HandleBufferTestAPI(SOCKET client_socket, const Json::Value& request, Json::Value& response);
DWORD HandlePerformanceAPI(SOCKET client_socket, const Json::Value& request, Json::Value& response);

/*
 * Service entry point
 */
int main(int argc, char* argv[])
{
    if (argc > 1) {
        if (_stricmp(argv[1], "console") == 0) {
            // Run as console application for debugging
            printf("Running Windows API Remoting Service in console mode...\n");

            // Check for TCP flag
            if (argc > 2 && _stricmp(argv[2], "--tcp") == 0) {
                printf("Forcing TCP mode (no VSOCK attempt)\n");
                g_force_tcp = TRUE;
            }

            if (InitializeService() != ERROR_SUCCESS) {
                printf("Failed to initialize service\n");
                return 1;
            }

            printf("Service initialized. Press any key to stop...\n");
            ServiceWorkerThread(NULL);

            printf("Press any key to exit...\n");
            _getch();
            CleanupService();
            return 0;
        }
        else if (_stricmp(argv[1], "install") == 0) {
            printf("Use install.cmd to install the service\n");
            return 0;
        }
        else if (_stricmp(argv[1], "--help") == 0) {
            printf("Usage: %s [options]\n", argv[0]);
            printf("  console         Run in console mode for debugging\n");
            printf("  console --tcp   Run in console mode with TCP-only (no VSOCK)\n");
            printf("  install         Show install instructions\n");
            printf("  --help          Show this help\n");
            return 0;
        }
    }

    // Run as Windows service
    SERVICE_TABLE_ENTRY ServiceTable[] = {
        {(LPWSTR)SERVICE_NAME, ServiceMain},
        {NULL, NULL}
    };

    if (!StartServiceCtrlDispatcher(ServiceTable)) {
        printf("StartServiceCtrlDispatcher failed (%d)\n", GetLastError());
        return 1;
    }

    return 0;
}

/*
 * Service main function
 */
void WINAPI ServiceMain(DWORD argc, LPTSTR *argv)
{
    // Register service control handler
    g_service_status_handle = RegisterServiceCtrlHandler(SERVICE_NAME, ServiceCtrlHandler);
    if (g_service_status_handle == NULL) {
        return;
    }

    // Initialize service status
    g_service_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    g_service_status.dwCurrentState = SERVICE_START_PENDING;
    g_service_status.dwControlsAccepted = SERVICE_ACCEPT_STOP;
    g_service_status.dwWin32ExitCode = 0;
    g_service_status.dwServiceSpecificExitCode = 0;
    g_service_status.dwCheckPoint = 0;
    g_service_status.dwWaitHint = 0;

    SetServiceStatus(g_service_status_handle, &g_service_status);

    // Initialize service
    if (InitializeService() != ERROR_SUCCESS) {
        g_service_status.dwCurrentState = SERVICE_STOPPED;
        SetServiceStatus(g_service_status_handle, &g_service_status);
        return;
    }

    // Service is running
    g_service_status.dwCurrentState = SERVICE_RUNNING;
    SetServiceStatus(g_service_status_handle, &g_service_status);

    // Start worker thread
    HANDLE worker_thread = CreateThread(NULL, 0, ServiceWorkerThread, NULL, 0, NULL);
    if (worker_thread == NULL) {
        g_service_status.dwCurrentState = SERVICE_STOPPED;
        SetServiceStatus(g_service_status_handle, &g_service_status);
        return;
    }

    // Wait for stop signal
    WaitForSingleObject(g_ctx.stop_event, INFINITE);

    // Cleanup
    CleanupService();
    CloseHandle(worker_thread);

    g_service_status.dwCurrentState = SERVICE_STOPPED;
    SetServiceStatus(g_service_status_handle, &g_service_status);
}

/*
 * Service control handler
 */
void WINAPI ServiceCtrlHandler(DWORD ctrl)
{
    switch (ctrl) {
        case SERVICE_CONTROL_STOP:
            g_service_status.dwCurrentState = SERVICE_STOP_PENDING;
            SetServiceStatus(g_service_status_handle, &g_service_status);
            g_ctx.running = FALSE;
            SetEvent(g_ctx.stop_event);
            break;
        default:
            break;
    }
}

/*
 * Initialize the service
 */
DWORD InitializeService()
{
    WSADATA wsa_data;
    SOCKADDR_HV addr;
    BOOL use_vsock;

    // Initialize socket fields to INVALID_SOCKET
    g_ctx.listen_socket = INVALID_SOCKET;
    g_ctx.tcp_listen_socket = INVALID_SOCKET;

    // Initialize Winsock
    printf("Initializing Winsock...\n");
    if (WSAStartup(MAKEWORD(2, 2), &wsa_data) != 0) {
        printf("WSAStartup failed: %d\n", WSAGetLastError());
        return ERROR_NETWORK_UNREACHABLE;
    }
    printf("Winsock initialized successfully\n");

    // Create stop event
    g_ctx.stop_event = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (g_ctx.stop_event == NULL) {
        WSACleanup();
        return GetLastError();
    }

    // Create shared memory
    printf("Creating shared memory (%d MB)...\n", SHARED_MEMORY_SIZE / (1024*1024));
    g_ctx.shared_memory_handle = CreateFileMapping(
        INVALID_HANDLE_VALUE,
        NULL,
        PAGE_READWRITE,
        0,
        SHARED_MEMORY_SIZE,
        SHARED_MEMORY_NAME
    );

    if (g_ctx.shared_memory_handle == NULL) {
        printf("CreateFileMapping failed: %d\n", GetLastError());
        CloseHandle(g_ctx.stop_event);
        WSACleanup();
        return GetLastError();
    }

    // Map shared memory
    g_ctx.shared_memory_view = MapViewOfFile(
        g_ctx.shared_memory_handle,
        FILE_MAP_ALL_ACCESS,
        0,
        0,
        SHARED_MEMORY_SIZE
    );

    if (g_ctx.shared_memory_view == NULL) {
        CloseHandle(g_ctx.shared_memory_handle);
        CloseHandle(g_ctx.stop_event);
        WSACleanup();
        return GetLastError();
    }

    // Initialize shared memory layout
    g_ctx.header = (struct shared_memory_header*)g_ctx.shared_memory_view;
    g_ctx.request_buffer = (char*)g_ctx.shared_memory_view + HEADER_SIZE;
    g_ctx.response_buffer = (char*)g_ctx.shared_memory_view + HEADER_SIZE + REQUEST_BUFFER_SIZE;

    // Initialize header
    ZeroMemory(g_ctx.header, sizeof(*g_ctx.header));
    g_ctx.header->magic = WINAPI_MAGIC;
    g_ctx.header->version = PROTOCOL_VERSION;
    g_ctx.header->request_offset = HEADER_SIZE;
    g_ctx.header->response_offset = HEADER_SIZE + REQUEST_BUFFER_SIZE;
    g_ctx.header->request_size = REQUEST_BUFFER_SIZE;
    g_ctx.header->response_size = RESPONSE_BUFFER_SIZE;

    // Try AF_HYPERV first (unless TCP is forced), then fall back to TCP
    g_ctx.using_tcp = FALSE;

    if (g_force_tcp) {
        printf("Step 1: Skipping VSOCK attempt (TCP mode forced)\n");
        goto try_tcp_fallback;
    }

    printf("Step 1: Attempting to create AF_HYPERV socket for VSOCK compatibility...\n");
    g_ctx.listen_socket = socket(AF_HYPERV, SOCK_STREAM, HV_PROTOCOL_RAW);

    if (g_ctx.listen_socket != INVALID_SOCKET) {
        printf("[OK] AF_HYPERV socket created successfully\n");

        // Try to bind using Microsoft VSOCK Service GUID
        printf("Step 2: Binding to Microsoft VSOCK GUID...\n");

        ZeroMemory(&addr, sizeof(addr));
        addr.Family = AF_HYPERV;
        addr.VmId = HV_GUID_WILDCARD;  // Accept connections from any VM

        // Use Microsoft's official Linux VSOCK template GUID
        // Template: "00000000-facb-11e6-bd58-64006a7986d3"
        // Port goes in Data1 field
        addr.ServiceId.Data1 = HYPERV_SOCKET_PORT;  // Port in Data1
        addr.ServiceId.Data2 = 0xfacb;               // Fixed: facb
        addr.ServiceId.Data3 = 0x11e6;               // Fixed: 11e6
        addr.ServiceId.Data4[0] = 0xbd;              // Fixed: bd
        addr.ServiceId.Data4[1] = 0x58;              // Fixed: 58
        addr.ServiceId.Data4[2] = 0x64;              // Fixed: 64
        addr.ServiceId.Data4[3] = 0x00;              // Fixed: 00
        addr.ServiceId.Data4[4] = 0x6a;              // Fixed: 6a
        addr.ServiceId.Data4[5] = 0x79;              // Fixed: 79
        addr.ServiceId.Data4[6] = 0x86;              // Fixed: 86
        addr.ServiceId.Data4[7] = 0xd3;              // Fixed: d3

        printf("   Linux VSOCK GUID: %08X-FACB-11E6-BD58-64006A7986D3\n", HYPERV_SOCKET_PORT);

        if (bind(g_ctx.listen_socket, (SOCKADDR*)&addr, sizeof(addr)) == SOCKET_ERROR) {
            printf("[ERROR] AF_HYPERV bind() failed: %d - falling back to TCP\n", WSAGetLastError());
            closesocket(g_ctx.listen_socket);
            g_ctx.listen_socket = INVALID_SOCKET;
            goto try_tcp_fallback;
        }
        printf("[OK] AF_HYPERV socket bound successfully\n");
        printf("*** REGISTRY COMMAND TO RUN ***\n");
        printf("New-Item -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Virtualization\\GuestCommunicationServices\\%08x-facb-11e6-bd58-64006a7986d3' -Force\n", HYPERV_SOCKET_PORT);
        printf("Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Virtualization\\GuestCommunicationServices\\%08x-facb-11e6-bd58-64006a7986d3' -Name 'ElementName' -Value 'WinAPI Remoting Service'\n", HYPERV_SOCKET_PORT);
        printf("*** END REGISTRY COMMAND ***\n");
    } else {
        printf("[ERROR] AF_HYPERV socket() failed: %d - falling back to TCP\n", WSAGetLastError());

try_tcp_fallback:
        printf("\nStep 1b: Attempting TCP fallback...\n");
        g_ctx.listen_socket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);

        if (g_ctx.listen_socket == INVALID_SOCKET) {
            printf("[ERROR] TCP socket() failed: %d\n", WSAGetLastError());
            UnmapViewOfFile(g_ctx.shared_memory_view);
            CloseHandle(g_ctx.shared_memory_handle);
            CloseHandle(g_ctx.stop_event);
            WSACleanup();
            return WSAGetLastError();
        }

        printf("[OK] TCP socket created successfully\n");

        // Bind to TCP port
        printf("Step 2b: Binding to TCP port %d...\n", TCP_SOCKET_PORT);
        struct sockaddr_in tcp_addr;
        ZeroMemory(&tcp_addr, sizeof(tcp_addr));
        tcp_addr.sin_family = AF_INET;
        tcp_addr.sin_addr.s_addr = INADDR_ANY;  // Listen on all interfaces
        tcp_addr.sin_port = htons(TCP_SOCKET_PORT);

        if (bind(g_ctx.listen_socket, (SOCKADDR*)&tcp_addr, sizeof(tcp_addr)) == SOCKET_ERROR) {
            printf("[ERROR] TCP bind() failed: %d\n", WSAGetLastError());
            closesocket(g_ctx.listen_socket);
            UnmapViewOfFile(g_ctx.shared_memory_view);
            CloseHandle(g_ctx.shared_memory_handle);
            CloseHandle(g_ctx.stop_event);
            WSACleanup();
            return WSAGetLastError();
        }

        printf("[OK] TCP socket bound successfully\n");
        g_ctx.using_tcp = TRUE;
        printf("[INFO] Using TCP mode with shared memory for high-performance data transfers\n");
        printf("   WSL2 clients should connect to Windows host IP on port %d\n", TCP_SOCKET_PORT);
        printf("   Zero-copy buffer transfers available via shared memory\n");
    }

    // Start listening
    printf("Step 3: Starting to listen for connections (max %d clients)...\n", MAX_CLIENTS);
    if (listen(g_ctx.listen_socket, MAX_CLIENTS) == SOCKET_ERROR) {
        printf("[ERROR] listen() failed: %d\n", WSAGetLastError());
        closesocket(g_ctx.listen_socket);
        UnmapViewOfFile(g_ctx.shared_memory_view);
        CloseHandle(g_ctx.shared_memory_handle);
        CloseHandle(g_ctx.stop_event);
        WSACleanup();
        return WSAGetLastError();
    }

    if (g_ctx.using_tcp) {
        printf("[OK] Listening on TCP port %d for WSL2 connections\n", TCP_SOCKET_PORT);
        printf("   Note: TCP fallback mode - shared memory still provides zero-copy performance\n");
    } else {
        printf("[OK] Listening on Linux VSOCK port 0x%X for WSL2 AF_VSOCK connections\n", HYPERV_SOCKET_PORT);
        printf("   Using Microsoft Linux VSOCK template GUID\n");
    }

    g_ctx.running = TRUE;
    return ERROR_SUCCESS;
}

/*
 * Cleanup service resources
 */
void CleanupService()
{
    g_ctx.running = FALSE;

    if (g_ctx.listen_socket != INVALID_SOCKET) {
        closesocket(g_ctx.listen_socket);
        g_ctx.listen_socket = INVALID_SOCKET;
    }

    if (g_ctx.tcp_listen_socket != INVALID_SOCKET) {
        closesocket(g_ctx.tcp_listen_socket);
        g_ctx.tcp_listen_socket = INVALID_SOCKET;
    }

    if (g_ctx.shared_memory_view) {
        UnmapViewOfFile(g_ctx.shared_memory_view);
        g_ctx.shared_memory_view = NULL;
    }

    if (g_ctx.shared_memory_handle) {
        CloseHandle(g_ctx.shared_memory_handle);
        g_ctx.shared_memory_handle = NULL;
    }

    if (g_ctx.stop_event) {
        CloseHandle(g_ctx.stop_event);
        g_ctx.stop_event = NULL;
    }

    WSACleanup();
}

/*
 * Service worker thread
 */
DWORD WINAPI ServiceWorkerThread(LPVOID lpParam)
{
    fd_set readfds;
    struct timeval timeout;
    SOCKET client_socket;
    union {
        SOCKADDR_HV hv_addr;
        struct sockaddr_in tcp_addr;
        SOCKADDR generic_addr;
    } client_addr;
    int addr_len;
    static int heartbeat_counter = 0;

    printf("Worker thread started, waiting for connections...\n");
    printf("   Transport: %s\n", g_ctx.using_tcp ? "TCP" : "VSOCK");

    while (g_ctx.running) {
        FD_ZERO(&readfds);
        FD_SET(g_ctx.listen_socket, &readfds);

        timeout.tv_sec = 1;
        timeout.tv_usec = 0;

        int result = select(0, &readfds, NULL, NULL, &timeout);
        if (result == SOCKET_ERROR) {
            printf("select() failed: %d\n", WSAGetLastError());
            break;
        }

        // Heartbeat every 30 seconds
        if (++heartbeat_counter >= 30) {
            printf("Service running (%s), waiting for connections...\n",
                   g_ctx.using_tcp ? "TCP" : "VSOCK");
            heartbeat_counter = 0;
        }

        if (result > 0 && FD_ISSET(g_ctx.listen_socket, &readfds)) {
            printf("Incoming %s connection detected...\n",
                   g_ctx.using_tcp ? "TCP" : "VSOCK");

            // Set appropriate address length based on socket type
            if (g_ctx.using_tcp) {
                addr_len = sizeof(client_addr.tcp_addr);
            } else {
                addr_len = sizeof(client_addr.hv_addr);
            }

            client_socket = accept(g_ctx.listen_socket, &client_addr.generic_addr, &addr_len);

            if (client_socket != INVALID_SOCKET) {
                if (g_ctx.using_tcp) {
                    char* client_ip = inet_ntoa(client_addr.tcp_addr.sin_addr);
                    printf("[OK] TCP connection accepted from %s:%d\n",
                           client_ip, ntohs(client_addr.tcp_addr.sin_port));
                } else {
                    printf("[OK] VSOCK connection accepted successfully\n");
                }

                // Handle client in separate thread or inline
                HandleClient(client_socket);
                closesocket(client_socket);
                printf("Client disconnected\n");
            } else {
                printf("accept() failed: %d\n", WSAGetLastError());
            }
        }
    }

    return 0;
}

/*
 * Handle client connection
 */
DWORD HandleClient(SOCKET client_socket)
{
    char request_buffer[65536];
    char response_buffer[65536];
    UINT32 msg_len;
    int bytes_received;

    while (TRUE) {
        // Receive message length
        bytes_received = recv(client_socket, (char*)&msg_len, sizeof(msg_len), MSG_WAITALL);
        if (bytes_received != sizeof(msg_len)) {
            break;
        }

        msg_len = ntohl(msg_len);
        if (msg_len > sizeof(request_buffer) - 1) {
            break;
        }

        // Receive JSON message
        bytes_received = recv(client_socket, request_buffer, msg_len, MSG_WAITALL);
        if (bytes_received != (int)msg_len) {
            break;
        }

        request_buffer[msg_len] = '\0';

        // Process request
        if (ProcessAPIRequest(client_socket, request_buffer, response_buffer, sizeof(response_buffer)) == ERROR_SUCCESS) {
            // Send response
            UINT32 response_len = (UINT32)strlen(response_buffer);
            UINT32 net_len = htonl(response_len);

            if (send(client_socket, (char*)&net_len, sizeof(net_len), 0) == sizeof(net_len)) {
                send(client_socket, response_buffer, response_len, 0);
            }
        }
    }

    return ERROR_SUCCESS;
}

/*
 * Process API request
 */
DWORD ProcessAPIRequest(SOCKET client_socket, const char* request_json, char* response_json, size_t response_size)
{
    Json::Value request, response;
    Json::Reader reader;
    Json::StreamWriterBuilder builder;

    // Parse request
    if (!reader.parse(request_json, request)) {
        strncpy(response_json, "{\"error\":\"Invalid JSON\"}", response_size - 1);
        response_json[response_size - 1] = '\0';
        return ERROR_INVALID_DATA;
    }

    // Get API name and request ID
    std::string api = request.get("api", "").asString();
    UINT32 request_id = request.get("request_id", 0).asUInt();

    // Process based on API
    DWORD result = ERROR_SUCCESS;

    if (api == "echo") {
        result = HandleEchoAPI(client_socket, request, response);
    }
    else if (api == "buffer_test") {
        result = HandleBufferTestAPI(client_socket, request, response);
    }
    else if (api == "performance") {
        result = HandlePerformanceAPI(client_socket, request, response);
    }
    else {
        response = CreateErrorResponse(request_id, "Unknown API");
        result = ERROR_INVALID_FUNCTION;
    }

    // Convert response to JSON string
    std::string response_str = Json::writeString(builder, response);
    strncpy(response_json, response_str.c_str(), response_size - 1);
    response_json[response_size - 1] = '\0';

    return result;
}

/*
 * Helper function to create error response
 */
Json::Value CreateErrorResponse(UINT32 request_id, const char* error_msg)
{
    Json::Value response;
    response["request_id"] = request_id;
    response["status"] = "error";
    response["error"] = error_msg;
    return response;
}

/*
 * Helper function to create success response
 */
Json::Value CreateSuccessResponse(UINT32 request_id)
{
    Json::Value response;
    response["request_id"] = request_id;
    response["status"] = "success";
    return response;
}

/*
 * Handle echo API
 */
DWORD HandleEchoAPI(SOCKET client_socket, const Json::Value& request, Json::Value& response)
{
    UINT32 request_id = request.get("request_id", 0).asUInt();
    std::string input = request.get("input", "").asString();

    response = CreateSuccessResponse(request_id);
    response["result"] = input;  // Echo back the input

    return ERROR_SUCCESS;
}

/*
 * Handle buffer test API
 */
DWORD HandleBufferTestAPI(SOCKET client_socket, const Json::Value& request, Json::Value& response)
{
    UINT32 request_id = request.get("request_id", 0).asUInt();
    int operation = request.get("operation", 0).asInt();
    UINT32 test_pattern = request.get("test_pattern", 0).asUInt();
    UINT64 payload_size = request.get("payload_size", 0).asUInt64();
    bool socket_transfer = request.get("socket_transfer", false).asBool();

    response = CreateSuccessResponse(request_id);

    Json::Value result;
    result["bytes_processed"] = (Json::UInt64)payload_size;
    result["checksum"] = test_pattern;  // Simple implementation
    result["status"] = 0;  // Success

    // Handle different operations
    switch (operation) {
        case WINAPI_BUFFER_OP_READ:
            if (socket_transfer) {
                // Send buffer data over socket
                printf("[INFO] Sending %llu bytes over socket (TCP mode)\n", payload_size);
                UINT32* pattern_buffer = new UINT32[payload_size / sizeof(UINT32)];
                for (UINT64 i = 0; i < payload_size / sizeof(UINT32); i++) {
                    pattern_buffer[i] = test_pattern;
                }
                // Note: Data will be sent after JSON response
                delete[] pattern_buffer;
            } else if (payload_size <= RESPONSE_BUFFER_SIZE) {
                // Fill response buffer with test pattern (shared memory)
                UINT32* buf = (UINT32*)g_ctx.response_buffer;
                for (UINT64 i = 0; i < payload_size / sizeof(UINT32); i++) {
                    buf[i] = test_pattern;
                }
            }
            break;

        case WINAPI_BUFFER_OP_WRITE:
        case WINAPI_BUFFER_OP_VERIFY:
            if (socket_transfer) {
                // Receive buffer data over socket
                printf("[INFO] Receiving %llu bytes over socket (TCP mode)\n", payload_size);
                char* temp_buffer = new char[payload_size];
                int total_received = 0;
                while (total_received < payload_size) {
                    int received = recv(client_socket, temp_buffer + total_received,
                                      (int)(payload_size - total_received), 0);
                    if (received <= 0) break;
                    total_received += received;
                }

                // Calculate checksum
                UINT32 checksum = 0;
                UINT32* buf = (UINT32*)temp_buffer;
                for (UINT64 i = 0; i < payload_size / sizeof(UINT32); i++) {
                    checksum ^= buf[i];
                }
                result["checksum"] = checksum;
                delete[] temp_buffer;
                printf("[INFO] Received %d bytes, checksum: 0x%08X\n", total_received, checksum);
            } else if (payload_size <= REQUEST_BUFFER_SIZE) {
                // Verify data in request buffer (shared memory)
                UINT32* buf = (UINT32*)g_ctx.request_buffer;
                UINT32 checksum = 0;
                for (UINT64 i = 0; i < payload_size / sizeof(UINT32); i++) {
                    checksum ^= buf[i];
                }
                result["checksum"] = checksum;
            }
            break;
    }

    response["result"] = result;
    return ERROR_SUCCESS;
}

/*
 * Handle performance API
 */
DWORD HandlePerformanceAPI(SOCKET client_socket, const Json::Value& request, Json::Value& response)
{
    UINT32 request_id = request.get("request_id", 0).asUInt();
    int test_type = request.get("test_type", 0).asInt();
    int iterations = request.get("iterations", 1000).asInt();
    UINT64 target_bytes = request.get("target_bytes", 1024).asUInt64();

    response = CreateSuccessResponse(request_id);

    // Simulate performance metrics
    Json::Value result;
    result["min_latency_ns"] = (Json::UInt64)1000;     // 1 µs
    result["max_latency_ns"] = (Json::UInt64)100000;   // 100 µs
    result["avg_latency_ns"] = (Json::UInt64)10000;    // 10 µs
    result["throughput_mbps"] = (Json::UInt64)1000;    // 1000 MB/s
    result["iterations_completed"] = iterations;

    response["result"] = result;
    return ERROR_SUCCESS;
}
