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
#include <signal.h>
#include <time.h>

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
#define SHARED_MEMORY_SIZE      (32 * 1024 * 1024) // 32MB
#define MAX_CLIENTS             16

// Shared Memory Layout
#define HEADER_SIZE             4096
#define REQUEST_BUFFER_SIZE     (15 * 1024 * 1024) // 15MB
#define RESPONSE_BUFFER_SIZE    (15 * 1024 * 1024) // 15MB

// SafeMemoryWrite boundary - switch to safe writes this far from buffer end
#define SAFE_WRITE_BOUNDARY     (32 * 1024)  // 32KB before buffer end
#define SAFE_WRITE_OFFSET       (RESPONSE_BUFFER_SIZE - SAFE_WRITE_BOUNDARY)

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
static BOOL g_force_tcp = TRUE;  // Default to TCP mode

// Forward declarations
void WINAPI ServiceMain(DWORD argc, LPTSTR *argv);
void WINAPI ServiceCtrlHandler(DWORD ctrl);
DWORD WINAPI ServiceWorkerThread(LPVOID lpParam);
DWORD InitializeService();
void CleanupService();
DWORD HandleClient(SOCKET client_socket);
DWORD ProcessAPIRequest(SOCKET client_socket, const char* request_json, char* response_json, size_t response_size);

// Windows exception handler for crash detection
LONG WINAPI WindowsExceptionHandler(EXCEPTION_POINTERS* ExceptionInfo);
void SignalHandler(int signal_num);

// Safe memory write with SEH
BOOL SafeMemoryWrite(UINT32* ptr, UINT32 value, UINT64 offset);

// Structure to pass buffer send info
struct BufferSendInfo {
    BOOL needs_buffer_send;
    UINT64 buffer_size;
    UINT32 test_pattern;
};

// JSON helper functions
Json::Value CreateErrorResponse(UINT32 request_id, const char* error_msg);
Json::Value CreateSuccessResponse(UINT32 request_id);

// API implementations
DWORD HandleEchoAPI(SOCKET client_socket, const Json::Value& request, Json::Value& response);
DWORD HandleBufferTestAPI(SOCKET client_socket, const Json::Value& request, Json::Value& response);
DWORD HandlePerformanceAPI(SOCKET client_socket, const Json::Value& request, Json::Value& response);

/*
 * Windows exception handler for crash detection (replaces Unix signals)
 */
LONG WINAPI WindowsExceptionHandler(EXCEPTION_POINTERS* ExceptionInfo)
{
    const char* exception_name;
    DWORD exception_code = ExceptionInfo->ExceptionRecord->ExceptionCode;

    switch (exception_code) {
        case EXCEPTION_ACCESS_VIOLATION:
            exception_name = "EXCEPTION_ACCESS_VIOLATION (Segmentation fault equivalent)";
            break;
        case EXCEPTION_ARRAY_BOUNDS_EXCEEDED:
            exception_name = "EXCEPTION_ARRAY_BOUNDS_EXCEEDED";
            break;
        case EXCEPTION_DATATYPE_MISALIGNMENT:
            exception_name = "EXCEPTION_DATATYPE_MISALIGNMENT";
            break;
        case EXCEPTION_FLT_DIVIDE_BY_ZERO:
            exception_name = "EXCEPTION_FLT_DIVIDE_BY_ZERO";
            break;
        case EXCEPTION_FLT_OVERFLOW:
            exception_name = "EXCEPTION_FLT_OVERFLOW";
            break;
        case EXCEPTION_ILLEGAL_INSTRUCTION:
            exception_name = "EXCEPTION_ILLEGAL_INSTRUCTION";
            break;
        case EXCEPTION_INT_DIVIDE_BY_ZERO:
            exception_name = "EXCEPTION_INT_DIVIDE_BY_ZERO";
            break;
        case EXCEPTION_INT_OVERFLOW:
            exception_name = "EXCEPTION_INT_OVERFLOW";
            break;
        case EXCEPTION_INVALID_DISPOSITION:
            exception_name = "EXCEPTION_INVALID_DISPOSITION";
            break;
        case EXCEPTION_STACK_OVERFLOW:
            exception_name = "EXCEPTION_STACK_OVERFLOW";
            break;
        default:
            exception_name = "Unknown Windows exception";
            break;
    }

    printf("\n\n*** WINDOWS CRASH DETECTED ***\n");
    printf("Exception Code: 0x%08X (%s)\n", exception_code, exception_name);

    time_t current_time = time(NULL);
    printf("Time: %s", ctime(&current_time));

    printf("Exception Address: %p\n", ExceptionInfo->ExceptionRecord->ExceptionAddress);

    if (exception_code == EXCEPTION_ACCESS_VIOLATION && ExceptionInfo->ExceptionRecord->NumberParameters >= 2) {
        ULONG_PTR access_type = ExceptionInfo->ExceptionRecord->ExceptionInformation[0];
        ULONG_PTR address = ExceptionInfo->ExceptionRecord->ExceptionInformation[1];
        printf("Access Violation: %s at address %p\n",
               access_type == 0 ? "Read" : (access_type == 1 ? "Write" : "Execute"),
               (void*)address);
    }

    printf("Server is terminating due to exception...\n");
    fflush(stdout);

    // Clean up if possible
    if (g_ctx.running) {
        printf("Attempting cleanup...\n");
        fflush(stdout);
        CleanupService();
    }

    // Return EXCEPTION_EXECUTE_HANDLER to terminate the process
    return EXCEPTION_EXECUTE_HANDLER;
}

/*
 * Signal handler for crash detection (for compatibility signals)
 */
void SignalHandler(int signal_num)
{
    const char* signal_name;
    switch (signal_num) {
        case SIGABRT:
            signal_name = "SIGABRT (Abort signal)";
            break;
        case SIGILL:
            signal_name = "SIGILL (Illegal instruction)";
            break;
        case SIGFPE:
            signal_name = "SIGFPE (Floating point exception)";
            break;
        case SIGTERM:
            signal_name = "SIGTERM (Termination request)";
            break;
        case SIGINT:
            signal_name = "SIGINT (Interrupt)";
            break;
        default:
            signal_name = "Unknown signal";
            break;
    }

    printf("\n\n*** CRASH DETECTED ***\n");
    printf("Signal: %d (%s)\n", signal_num, signal_name);

    time_t current_time = time(NULL);
    printf("Time: %s", ctime(&current_time));
    printf("Server is terminating due to signal...\n");
    fflush(stdout);

    // Clean up if possible
    if (g_ctx.running) {
        printf("Attempting cleanup...\n");
        fflush(stdout);
        CleanupService();
    }

    // Re-raise the signal with default handler to generate crash dump if available
    signal(signal_num, SIG_DFL);
    raise(signal_num);
}

/*
 * Safe memory write with SEH
 */
BOOL SafeMemoryWrite(UINT32* ptr, UINT32 value, UINT64 offset)
{
    __try {
        *ptr = value;
        return TRUE;
    }
    __except(EXCEPTION_EXECUTE_HANDLER) {
        printf("[ERROR] SafeMemoryWrite: Access violation at offset %I64u, address %p\n", offset, ptr);
        printf("[ERROR] SafeMemoryWrite: Exception code: 0x%08X\n", GetExceptionCode());
        return FALSE;
    }
}

/*
 * Service entry point
 */
int main(int argc, char* argv[])
{
    // Install Windows exception handler for crashes (access violations, etc.)
    SetUnhandledExceptionFilter(WindowsExceptionHandler);
    printf("[INFO] Windows exception handler installed for crash detection\n");

    // Install signal handlers for compatibility signals that work on Windows
    signal(SIGABRT, SignalHandler);  // Abort signal
    signal(SIGFPE, SignalHandler);   // Floating point exception
    signal(SIGILL, SignalHandler);   // Illegal instruction
    signal(SIGINT, SignalHandler);   // Interrupt (Ctrl+C)
    signal(SIGTERM, SignalHandler);  // Termination request
    // Note: SIGSEGV doesn't work reliably on Windows - using SEH instead

    printf("[INFO] Signal handlers installed for termination signals\n");
    fflush(stdout);

    if (argc > 1) {
        if (_stricmp(argv[1], "console") == 0) {
            // Run as console application for debugging
            printf("Running Windows API Remoting Service in console mode...\n");

            // Check for VSOCK flag (TCP is now default)
            if (argc > 2 && _stricmp(argv[2], "--vsock") == 0) {
                printf("Enabling VSOCK mode (will attempt VSOCK first)\n");
                g_force_tcp = FALSE;
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
            printf("  console         Run in console mode (TCP default)\n");
            printf("  console --vsock Run in console mode with VSOCK preferred\n");
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

    // Create shared memory using file-backed mapping for WSL2 compatibility
    printf("Creating shared memory (%d MB)...\n", SHARED_MEMORY_SIZE / (1024*1024));

    // Open the shared memory file (must be created first)
    HANDLE file_handle = CreateFile(
        L"C:\\temp\\winapi_shared_memory",
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL,
        OPEN_EXISTING,           // File must already exist
        FILE_ATTRIBUTE_NORMAL,
        NULL
    );

    if (file_handle == INVALID_HANDLE_VALUE) {
        printf("Failed to open shared memory file C:\\temp\\winapi_shared_memory: %d\n", GetLastError());
        printf("Please create the file first using: enable-tcp-shared-memory.ps1\n");
        printf("Or manually: fsutil file createnew C:\\temp\\winapi_shared_memory %d\n", SHARED_MEMORY_SIZE);
        CloseHandle(g_ctx.stop_event);
        WSACleanup();
        return GetLastError();
    }

    printf("Opened shared memory file: C:\\temp\\winapi_shared_memory\n");
    printf("File-backed shared memory enabled for TCP + zero-copy mode\n");

    // Create file-backed mapping
    g_ctx.shared_memory_handle = CreateFileMapping(
        file_handle,             // Use actual file instead of memory-only
        NULL,
        PAGE_READWRITE,
        0,
        SHARED_MEMORY_SIZE,
        NULL                     // No name needed for file-backed mapping
    );

    // Close file handle (mapping keeps it alive)
    CloseHandle(file_handle);

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
        printf("Step 1: Using TCP mode (default)\n");
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
        DWORD error_code = WSAGetLastError();
        printf("[FATAL ERROR] Failed to start listening on socket: %d\n", error_code);
        printf("              Cannot accept client connections - service terminating\n");

        // Clean up all resources before exiting
        printf("              Cleaning up resources...\n");
        closesocket(g_ctx.listen_socket);
        g_ctx.listen_socket = INVALID_SOCKET;

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
        printf("              Resource cleanup completed - exiting\n");
        return error_code;
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
	  //printf("Service running (%s), waiting for connections...\n",
	  //g_ctx.using_tcp ? "TCP" : "VSOCK");

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
    int request_count = 0;

    while (TRUE) {
        // Receive message length
        bytes_received = recv(client_socket, (char*)&msg_len, sizeof(msg_len), MSG_WAITALL);
        if (bytes_received != sizeof(msg_len)) {
            if (bytes_received == 0) {
                printf("[INFO] Client disconnected gracefully\n");
            } else {
                printf("[ERROR] Failed to receive message length: %d\n", WSAGetLastError());
            }
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
        request_count++;

        // Process request
        DWORD result;
        try {
            result = ProcessAPIRequest(client_socket, request_buffer, response_buffer, sizeof(response_buffer));
        } catch (...) {
            printf("[ERROR] Exception during request processing\n");
            break;
        }

        if (result == ERROR_SUCCESS) {
            // Send response
            UINT32 response_len = (UINT32)strlen(response_buffer);
            UINT32 net_len = htonl(response_len);

            int sent = send(client_socket, (char*)&net_len, sizeof(net_len), 0);
            if (sent != sizeof(net_len)) {
                break;
            }

            sent = send(client_socket, response_buffer, response_len, 0);
            if (sent != (int)response_len) {
                break;
            }

            // Check if we need to send buffer data for READ operations
            Json::Value parsed_response;
            Json::Reader response_reader;

            try {
                if (response_reader.parse(response_buffer, parsed_response)) {
                    Json::Value result_section = parsed_response.get("result", Json::Value());

                    // Only check for buffer data if result is an object (buffer test responses)
                    // Echo responses have result as a string, so skip buffer check
                    if (!result_section.isNull() && result_section.isObject() &&
                        result_section.isMember("needs_buffer_send") && result_section.get("needs_buffer_send", false).asBool()) {
                    uint64_t buffer_size = result_section.get("buffer_size", 0).asUInt64();
                    uint32_t test_pattern = result_section.get("test_pattern", 0).asUInt();

                    // Generate and send buffer data
                    uint32_t* pattern_buffer = new uint32_t[buffer_size / sizeof(uint32_t)];
                    uint64_t uint32_count = buffer_size / sizeof(uint32_t);

                    for (uint64_t i = 0; i < uint32_count; i++) {
                        pattern_buffer[i] = test_pattern;
                    }

                    // Send buffer data in chunks
                    char* send_ptr = (char*)pattern_buffer;
                    size_t total_sent = 0;
                    while (total_sent < buffer_size) {
                        size_t chunk_size = min(buffer_size - total_sent, 65536ULL); // 64KB chunks
                        int chunk_sent = send(client_socket, send_ptr + total_sent, (int)chunk_size, 0);
                        if (chunk_sent <= 0) {
                            delete[] pattern_buffer;
                            return ERROR_SUCCESS;
                        }
                        total_sent += chunk_sent;
                    }
                        delete[] pattern_buffer;
                    }
                }
            } catch (const std::exception& e) {
                // Ignore JSON parsing exceptions for buffer data check
            } catch (...) {
                // Ignore unknown exceptions for buffer data check
            }
        } else {
            // Send error response
            UINT32 response_len = (UINT32)strlen(response_buffer);
            UINT32 net_len = htonl(response_len);
            send(client_socket, (char*)&net_len, sizeof(net_len), 0);
            send(client_socket, response_buffer, response_len, 0);
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
        printf("[ERROR] JSON parsing failed: %s\n", reader.getFormattedErrorMessages().c_str());
        strncpy(response_json, "{\"error\":\"Invalid JSON\",\"details\":\"JSON parsing failed\"}", response_size - 1);
        response_json[response_size - 1] = '\0';
        return ERROR_INVALID_DATA;
    }

    // Get API name and request ID
    std::string api = request.get("api", "").asString();
    UINT32 request_id = request.get("request_id", 0).asUInt();

    if (api.empty()) {
        printf("[ERROR] Missing API name in request\n");
        response = CreateErrorResponse(request_id, "Missing API name");
        std::string response_str = Json::writeString(builder, response);
        strncpy(response_json, response_str.c_str(), response_size - 1);
        response_json[response_size - 1] = '\0';
        return ERROR_INVALID_PARAMETER;
    }

    // Process based on API
    DWORD result = ERROR_SUCCESS;

    if (api == "echo") {
        result = HandleEchoAPI(client_socket, request, response);
    }
    else if (api == "buffer_test") {
        try {
            result = HandleBufferTestAPI(client_socket, request, response);
        } catch (const std::exception& e) {
            printf("[ERROR] Exception in HandleBufferTestAPI: %s\n", e.what());
            response = CreateErrorResponse(request_id, "Server exception occurred");
            result = ERROR_INVALID_FUNCTION;
        } catch (...) {
            printf("[ERROR] Unknown exception in HandleBufferTestAPI\n");
            response = CreateErrorResponse(request_id, "Unknown server exception");
            result = ERROR_INVALID_FUNCTION;
        }
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

    UINT32 test_pattern;
    try {
        // Handle both signed and unsigned values from JSON
        if (request["test_pattern"].isInt()) {
            test_pattern = (UINT32)request.get("test_pattern", 0).asInt();
        } else {
            test_pattern = request.get("test_pattern", 0).asUInt();
        }
    } catch (...) {
        response = CreateErrorResponse(request_id, "JSON parsing error - test_pattern");
        return ERROR_INVALID_DATA;
    }

    UINT64 payload_size = request.get("payload_size", 0).asUInt64();

    BOOL socket_transfer;
    try {
        socket_transfer = request.get("socket_transfer", false).asBool() ? TRUE : FALSE;
    } catch (...) {
        response = CreateErrorResponse(request_id, "JSON parsing error");
        return ERROR_INVALID_DATA;
    }

    // Validate parameters
    if (payload_size == 0) {
        response = CreateErrorResponse(request_id, "Invalid payload size");
        return ERROR_INVALID_PARAMETER;
    }

    if (socket_transfer && payload_size > 64 * 1024 * 1024) {  // 64MB limit for socket transfer
        response = CreateErrorResponse(request_id, "Payload too large for socket transfer");
        return ERROR_INVALID_PARAMETER;
    }

    response = CreateSuccessResponse(request_id);

    Json::Value result;
    result["bytes_processed"] = (Json::UInt64)payload_size;
    result["checksum"] = test_pattern;  // Simple implementation
    result["status"] = 0;  // Success

    // Handle different operations
    switch (operation) {
        case WINAPI_BUFFER_OP_READ:
            if (socket_transfer) {
                // Store info for buffer sending after JSON response
                result["needs_buffer_send"] = true;
                result["buffer_size"] = (Json::UInt64)payload_size;
                result["test_pattern"] = test_pattern;
            } else if (payload_size <= RESPONSE_BUFFER_SIZE) {
                if (!g_ctx.response_buffer) {
                    response = CreateErrorResponse(request_id, "Shared memory response buffer not available");
                    return ERROR_INVALID_HANDLE;
                }

                // Fill response buffer with test pattern (shared memory)
                UINT32* buf = (UINT32*)g_ctx.response_buffer;
                UINT64 uint32_count = payload_size / sizeof(UINT32);

                for (UINT64 i = 0; i < uint32_count; i++) {
                    UINT64 byte_offset = i * sizeof(UINT32);
                    if (byte_offset + sizeof(UINT32) > RESPONSE_BUFFER_SIZE) {
                        break; // Stop before exceeding buffer
                    }

                    if (byte_offset > SAFE_WRITE_OFFSET) {  // Use safe write near boundary
                        if (!SafeMemoryWrite(&buf[i], test_pattern, byte_offset)) {
                            break;
                        }
                    } else {
                        buf[i] = test_pattern;
                    }
                }
            } else {
                response = CreateErrorResponse(request_id, "Payload too large for shared memory response");
                return ERROR_INVALID_PARAMETER;
            }
            break;

        case WINAPI_BUFFER_OP_WRITE:
        case WINAPI_BUFFER_OP_VERIFY:
            if (socket_transfer) {
                // Receive buffer data over socket
                if (payload_size > 64 * 1024 * 1024) {
                    response = CreateErrorResponse(request_id, "Payload too large");
                    return ERROR_INVALID_PARAMETER;
                }

                char* temp_buffer = nullptr;
                try {
                    temp_buffer = new char[payload_size];
                } catch (...) {
                    response = CreateErrorResponse(request_id, "Memory allocation failed");
                    return ERROR_NOT_ENOUGH_MEMORY;
                }

                int total_received = 0;
                while (total_received < (int)payload_size) {
                    int bytes_remaining = (int)(payload_size - total_received);
                    int bytes_to_receive = min(bytes_remaining, 65536);  // 64KB chunks

                    int received = recv(client_socket, temp_buffer + total_received, bytes_to_receive, 0);
                    if (received <= 0) {
                        delete[] temp_buffer;
                        response = CreateErrorResponse(request_id, "Socket receive failed");
                        return ERROR_NETWORK_UNREACHABLE;
                    }
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
            } else if (payload_size <= REQUEST_BUFFER_SIZE) {
                // Verify data in request buffer (shared memory)
                if (!g_ctx.request_buffer) {
                    response = CreateErrorResponse(request_id, "Shared memory not available");
                    return ERROR_INVALID_HANDLE;
                }

                UINT32* buf = (UINT32*)g_ctx.request_buffer;
                UINT32 checksum = 0;
                for (UINT64 i = 0; i < payload_size / sizeof(UINT32); i++) {
                    checksum ^= buf[i];
                }
                result["checksum"] = checksum;
            } else {
                response = CreateErrorResponse(request_id, "Payload too large for shared memory");
                return ERROR_INVALID_PARAMETER;
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
