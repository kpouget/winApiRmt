@echo off
REM Alternative Driver Installation Using DevCon
REM Uses DevCon utility which sometimes works better with unsigned drivers

echo ============================================
echo  Driver Installation via DevCon
echo ============================================
echo.

REM Check if running as Administrator
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo ERROR: This script must be run as Administrator
    echo Right-click and select "Run as administrator"
    echo.
    pause
    exit /b 1
)

echo [✓] Running as Administrator
echo.

REM Navigate to driver directory
cd /d "%~dp0"

REM Check if DevCon exists
where devcon.exe >nul 2>&1
if %errorLevel% neq 0 (
    echo DevCon not found in PATH. Trying common locations...

    set DEVCON_PATH=""
    if exist "C:\Program Files (x86)\Windows Kits\10\Tools\x64\devcon.exe" (
        set DEVCON_PATH="C:\Program Files (x86)\Windows Kits\10\Tools\x64\devcon.exe"
    ) else if exist "C:\Program Files (x86)\Windows Kits\10\Tools\x86\devcon.exe" (
        set DEVCON_PATH="C:\Program Files (x86)\Windows Kits\10\Tools\x86\devcon.exe"
    ) else (
        echo ERROR: DevCon not found
        echo.
        echo DevCon is part of the Windows Driver Kit (WDK)
        echo Download from: https://docs.microsoft.com/en-us/windows-hardware/drivers/devtest/devcon
        echo.
        echo Alternative: Use regular installation with:
        echo   install_driver.cmd
        echo.
        pause
        exit /b 1
    )

    echo [✓] Found DevCon at: %DEVCON_PATH%
    set DEVCON=%DEVCON_PATH%
) else (
    echo [✓] Found DevCon in PATH
    set DEVCON=devcon.exe
)

echo.

REM Check driver files
if not exist "winApiRemoting.sys" (
    if exist "x64\Debug\winApiRemoting.sys" (
        echo [i] Copying driver from build directory...
        copy "x64\Debug\winApiRemoting.sys" "winApiRemoting.sys" >nul
    ) else (
        echo ERROR: Driver file not found
        echo Build the driver first using: build_driver_manual.cmd
        pause
        exit /b 1
    )
)

if not exist "winApiRemoting.inf" (
    echo ERROR: INF file not found
    pause
    exit /b 1
)

echo [✓] Driver files present
echo.

echo [1/3] Installing driver using DevCon...
%DEVCON% install winApiRemoting.inf "VMBUS\{6ac83d8f-6e16-4e5c-ab3d-fd8c5a4b7e21}"

if %errorLevel% equ 0 (
    echo [✓] Driver installed successfully via DevCon
) else (
    echo [!] DevCon installation returned error code: %errorLevel%
    echo This may be normal - checking if driver was actually installed...
)

echo.

echo [2/3] Checking driver installation...
%DEVCON% status "*winApiRemoting*"
if %errorLevel% equ 0 (
    echo [✓] Driver appears to be installed
) else (
    echo [!] Driver status check failed
)

echo.

echo [3/3] Attempting to start service...
sc query winApiRemoting >nul 2>&1
if %errorLevel% equ 0 (
    echo [i] Service exists, checking status...
    sc query winApiRemoting

    sc query winApiRemoting | find "RUNNING" >nul 2>&1
    if %errorLevel% neq 0 (
        echo [i] Starting service...
        sc start winApiRemoting
    )
) else (
    echo [!] Service not found - this may be normal for VMBus drivers
    echo VMBus drivers often start automatically when a device connects
)

echo.
echo ============================================
echo  Installation Summary
echo ============================================
echo.

echo Driver Installation via DevCon:
%DEVCON% status "*winApiRemoting*"

echo.
echo Service Status:
sc query winApiRemoting 2>nul || echo Service not found (may be normal for VMBus drivers)

echo.
echo If the driver still doesn't work, try:
echo 1. Regular installation: install_driver.cmd
echo 2. Create test certificate: create_test_cert.cmd
echo 3. Check Device Manager for "winApiRemoting Device"
echo.

pause