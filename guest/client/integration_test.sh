#!/bin/bash

echo "🔗 WinAPI Remoting Integration Test Suite"
echo "=========================================="

# Check if test_client exists
if [ ! -f "./test_client" ]; then
    echo "❌ test_client not found. Run 'make all' first."
    exit 1
fi

# Test basic connectivity first
echo "🔌 Testing Basic Connectivity..."
if ./check_service.sh | grep -q "SUCCESS"; then
    echo "✅ Windows service is reachable"
else
    echo "❌ Cannot connect to Windows service"
    echo "   Run './check_service.sh' for troubleshooting steps"
    exit 1
fi

echo ""
echo "🧪 Running API Tests..."
echo "========================"

# Test Echo API
echo "📤 Testing Echo API..."
./test_client --test echo
echo_result=$?

echo ""

# Test Buffer Operations
echo "📊 Testing Buffer Operations..."
./test_client --test buffer
buffer_result=$?

echo ""

# Test Performance
echo "⚡ Testing Performance..."
./test_client --test performance
perf_result=$?

echo ""

# Full test suite
echo "🎯 Running Complete Test Suite..."
./test_client --test all
full_result=$?

echo ""
echo "📋 Test Results Summary"
echo "======================="

if [ $echo_result -eq 0 ]; then
    echo "✅ Echo API: PASSED"
else
    echo "❌ Echo API: FAILED"
fi

if [ $buffer_result -eq 0 ]; then
    echo "✅ Buffer Test: PASSED"
else
    echo "❌ Buffer Test: FAILED"
fi

if [ $perf_result -eq 0 ]; then
    echo "✅ Performance Test: PASSED"
else
    echo "❌ Performance Test: FAILED"
fi

if [ $full_result -eq 0 ]; then
    echo "✅ Full Suite: PASSED"
else
    echo "❌ Full Suite: FAILED"
fi

echo ""

# Overall result
if [ $echo_result -eq 0 ] && [ $buffer_result -eq 0 ] && [ $perf_result -eq 0 ] && [ $full_result -eq 0 ]; then
    echo "🎉 ALL TESTS PASSED!"
    echo "   WinAPI Remoting is working correctly between WSL2 and Windows"
    exit 0
else
    echo "⚠️  Some tests failed"
    echo "   Check Windows service logs and network configuration"
    exit 1
fi