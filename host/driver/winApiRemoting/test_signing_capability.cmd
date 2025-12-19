@echo off
REM Test if Windows can install ANY unsigned content
echo Testing Windows unsigned installation capability...
echo.

pnputil /add-driver test_minimal.inf
echo Test minimal INF result: %errorLevel%
echo.

if %errorLevel% equ 0 (
    echo [V] SUCCESS: Windows can install unsigned content
    echo The issue may be with our specific driver
) else (
    echo [X] FAILED: Windows completely blocks unsigned content
    echo This is a system-level restriction
    echo.
    echo Error code: %errorLevel%
    echo.
    echo Solutions:
    echo 1. Disable Secure Boot in UEFI/BIOS
    echo 2. Use F8 boot menu "Disable Driver Signature Enforcement"
    echo 3. Try different Windows environment (VM, different edition)
    echo 4. Contact IT admin if on enterprise/domain system
)
echo.