#!/bin/bash

echo "🔍 WSL2 WinAPI Remoting Debug Information"
echo "========================================"

echo "📋 System Information:"
echo "  OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'=' -f2 | tr -d '\"')"
echo "  Kernel: $(uname -r)"
echo "  WSL Version: $(cat /proc/version | grep -o 'Microsoft.*' || echo 'Not WSL')"

echo ""
echo "🔌 Network & Socket Information:"
echo "  AF_VSOCK support: $(grep -i vsock /proc/net/protocols >/dev/null && echo 'Available' || echo 'Missing')"
echo "  Hyper-V modules: $(lsmod | grep -E '(hyperv|hv_)' | wc -l) loaded"

echo ""
echo "📁 Project Structure:"
echo "  Project path: $(pwd)"
echo "  test_client: $(ls -la test_client 2>/dev/null | awk '{print $5" bytes, "$1}' || echo 'Not found')"
echo "  libwinapi.a: $(ls -la libwinapi.a 2>/dev/null | awk '{print $5" bytes"}' || echo 'Not found')"
echo "  libwinapi.so: $(ls -la libwinapi.so 2>/dev/null | awk '{print $5" bytes"}' || echo 'Not found')"

echo ""
echo "📦 Dependencies:"
echo "  gcc: $(gcc --version 2>/dev/null | head -1 || echo 'Not found')"
echo "  json-c: $(pkg-config --modversion json-c 2>/dev/null || echo 'Not detected via pkg-config')"
echo "  json-c lib: $(ldconfig -p | grep json-c | head -1 | awk '{print $NF}' || echo 'Not found in ldconfig')"

echo ""
echo "🗂️  Shared Memory Setup:"
echo "  /mnt/c/temp: $(ls -ld /mnt/c/temp/ 2>/dev/null || echo 'Not found')"
echo "  Permissions: $(ls -ld /mnt/c/temp/ 2>/dev/null | awk '{print $1}' || echo 'N/A')"
echo "  Contents: $(ls -la /mnt/c/temp/ 2>/dev/null | wc -l) items"

echo ""
echo "🔧 Binary Analysis:"
if [ -f "./test_client" ]; then
    echo "  File type: $(file test_client)"
    echo "  Dependencies:"
    ldd test_client 2>/dev/null | head -10 | sed 's/^/    /'
    echo "  Symbols: $(nm test_client 2>/dev/null | grep -c ' T ' || echo 'stripped')"
else
    echo "  ❌ test_client binary not found"
fi

echo ""
echo "🔍 AF_VSOCK Test:"
python3 -c "
import socket
import os
try:
    sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    print('  ✅ AF_VSOCK socket creation: SUCCESS')
    print(f'    Socket FD: {sock.fileno()}')
    sock.close()
except Exception as e:
    print(f'  ❌ AF_VSOCK error: {e}')

# Check if we can see the socket constants
try:
    import socket
    print(f'  AF_VSOCK value: {socket.AF_VSOCK}')
    print(f'  SOCK_STREAM value: {socket.SOCK_STREAM}')
except AttributeError as e:
    print(f'  ❌ Socket constants error: {e}')
"

echo ""
echo "📋 Build Verification:"
if [ -f "Makefile" ]; then
    echo "  LDFLAGS: $(grep '^LDFLAGS' Makefile)"
    echo "  CFLAGS: $(grep '^CFLAGS' Makefile)"
else
    echo "  ❌ Makefile not found"
fi

echo ""
echo "🎯 Next Steps:"
echo "  1. Run './test_runner.sh' to verify client setup"
echo "  2. Run './check_service.sh' to test Windows service connectivity"
echo "  3. Run './integration_test.sh' for full testing when service is ready"