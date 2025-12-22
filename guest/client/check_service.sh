#!/bin/bash

echo "🔍 Windows Service Connectivity Check (Verbose)"
echo "================================================"

python3 -c "
import socket
import time
import os
import errno

print('🔍 VSOCK Support Analysis')
print('========================')

# Check AF_VSOCK availability
print(f'AF_VSOCK constant: {getattr(socket, \"AF_VSOCK\", \"NOT FOUND\")}')
print(f'VMADDR_CID_HOST: {getattr(socket, \"VMADDR_CID_HOST\", \"NOT FOUND\")}')

# Check kernel VSOCK support
if os.path.exists('/proc/net/vsock'):
    print('✅ /proc/net/vsock exists')
    with open('/proc/net/vsock', 'r') as f:
        vsock_content = f.read().strip()
        print(f'   Content: {vsock_content or \"(empty)\"}')
else:
    print('❌ /proc/net/vsock does not exist')

# Check for VSOCK in protocol list
if os.path.exists('/proc/net/protocols'):
    with open('/proc/net/protocols', 'r') as f:
        protocols = f.read()
        if 'vsock' in protocols.lower():
            print('✅ VSOCK found in /proc/net/protocols')
        else:
            print('❌ VSOCK not found in /proc/net/protocols')

print()
print('🔧 Socket Creation Test')
print('======================')

def test_connection():
    try:
        # Test socket creation first
        print('Step 1: Creating AF_VSOCK socket...')
        sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        print('✅ AF_VSOCK socket created successfully')

        # Set timeout and show socket info
        sock.settimeout(3)
        print(f'   Socket timeout: 3 seconds')
        print(f'   Socket family: {sock.family}')
        print(f'   Socket type: {sock.type}')

        print()
        print('Step 2: Attempting connection...')
        print(f'   Target: CID=2 (Windows host), Port=0x1234 (4660)')
        print(f'   Connecting...')

        # Connect to Windows host via VSOCK (CID=2 is Windows host)
        sock.connect((2, 0x1234))  # VMADDR_CID_HOST=2, port=0x1234

        print('✅ SUCCESS: Connected to Windows service!')
        print('   Host: Windows (CID 2)')
        print('   Port: 0x1234 (4660)')
        print('   Protocol: VSOCK (optimal VM communication)')

        # Get connection info if available
        try:
            peer = sock.getpeername()
            print(f'   Peer address: {peer}')
        except:
            pass

        sock.close()
        return True

    except OSError as e:
        print()
        print('💥 CONNECTION FAILED 💥')
        print('=====================')
        if e.errno == errno.ENODEV:
            print('❌ FAILURE: No such device (ENODEV)')
            print('   → VSOCK transport not available - hv_sock module missing')
        elif e.errno == errno.ECONNREFUSED:
            print('❌ FAILURE: Connection refused (ECONNREFUSED)')
            print('   → Windows service not listening on VSOCK port 0x1234')
        elif e.errno == errno.ETIMEDOUT:
            print('❌ FAILURE: Connection timeout (ETIMEDOUT)')
            print('   → Windows service not reachable via VSOCK')
        elif e.errno == errno.EHOSTUNREACH:
            print('❌ FAILURE: Host unreachable (EHOSTUNREACH)')
            print('   → Cannot reach Windows host via VSOCK')
        elif e.errno == errno.EAFNOSUPPORT:
            print('❌ FAILURE: Address family not supported (EAFNOSUPPORT)')
            print('   → AF_VSOCK not supported on this system')
        else:
            print(f'❌ FAILURE: {e} (errno={e.errno})')

        print(f'   Error details: {e}')
        return False

    except socket.timeout:
        print()
        print('💥 CONNECTION FAILED 💥')
        print('=====================')
        print('❌ FAILURE: Socket timeout after 3 seconds')
        print('   → Connection attempt timed out')
        return False

    except Exception as e:
        print()
        print('💥 CONNECTION FAILED 💥')
        print('=====================')
        print(f'❌ FAILURE: {type(e).__name__}: {e}')
        return False

print()
result = test_connection()
print()

if not result:
    print('🔍 System Diagnostics')
    print('====================')

    # Check for hyperv modules
    print('Hyper-V kernel modules:')
    os.system('lsmod | grep -i hv || echo \"  ❌ No hv modules loaded\"')

    print()
    print('VSOCK kernel modules:')
    os.system('lsmod | grep -i vsock || echo \"  ❌ No vsock modules loaded\"')

    print()
    print(f'WSL kernel version: {os.popen(\"uname -r\").read().strip()}')

if result:
    print()
    print('🎯 SUCCESS: VSOCK connection working!')
    print('   Ready for integration tests')
else:
    print()
    print('❌ VSOCK connection failed - check Windows service and kernel modules')
"