#!/bin/bash

echo "🧪 WSL2 Client Test Runner"
echo "========================="

echo "📋 Environment Check:"
echo "  Project: /mnt/c/Users/azureuser/winApiRmt/"
echo "  Client:  $(ls -la test_client 2>/dev/null | awk '{print $5}') bytes"
echo "  Shared:  $(ls -ld /mnt/c/temp/ 2>/dev/null || echo 'Not found')"

echo ""
echo "🔌 Connection Test:"
if ./test_client --test echo 2>&1 | grep -q "Connection refused\|No route to host\|Connection timed out"; then
    echo "  ✅ Client attempts connection correctly (service not running)"
else
    echo "  ⚠️  Unexpected connection behavior"
    echo "  Output: $(./test_client --test echo 2>&1 | head -1)"
fi

echo ""
echo "📊 Binary Info:"
echo "  Libraries: $(ldd test_client 2>/dev/null | grep json-c || echo 'json-c not visible in ldd')"
echo "  Size: $(ls -lh test_client 2>/dev/null | awk '{print $5}' || echo 'binary not found')"

echo ""
echo "🔍 AF_VSOCK Test:"
python3 -c "
import socket
try:
    sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    print('  ✅ AF_VSOCK socket creation successful')
    sock.close()
except Exception as e:
    print(f'  ❌ AF_VSOCK error: {e}')
"

echo ""
echo "🎯 Ready for Windows service connection!"
echo "   Run './check_service.sh' to test service connectivity"
echo "   Run './integration_test.sh' when service is ready"