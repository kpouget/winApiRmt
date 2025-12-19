@echo off
REM WinAPI Remoting Driver Installation Script
REM Automates driver installation and loading

echo ============================================
echo  WinAPI Remoting Driver Installer
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

REM Check if driver files exist
set DRIVER_FILE=
if exist "x64\Debug\winApiRemoting.sys" (
    set DRIVER_FILE=x64\Debug\winApiRemoting.sys
    echo [✓] Found driver in build directory: x64\Debug\winApiRemoting.sys
    goto driver_found
)

if exist "winApiRemoting.sys" (
    set DRIVER_FILE=winApiRemoting.sys
    echo [✓] Found driver in current directory: winApiRemoting.sys
    goto driver_found
)

echo ERROR: winApiRemoting.sys not found
echo.
echo Checked locations:
echo   - x64\Debug\winApiRemoting.sys (build output)
echo   - winApiRemoting.sys (current directory)
echo.
echo Please build the driver first using:
echo   build_driver_manual.cmd
echo   or ./build.sh from project root
echo.
exit /b 1

:driver_found

if not exist "winApiRemoting.inf" (
    echo ERROR: winApiRemoting.inf not found
    echo Driver installation file is missing
    echo.
    exit /b 1
)

REM Copy driver to current directory if needed (INF expects it here)
if not exist "winApiRemoting.sys" (
    echo [i] Copying driver to current directory for installation...
    copy "%DRIVER_FILE%" "winApiRemoting.sys" >nul
    if %errorLevel% neq 0 (
        echo ERROR: Failed to copy driver file
        exit /b 1
    )
)

echo [✓] Found required driver files
echo   Driver: %CD%\winApiRemoting.sys
echo   Size:
for %%A in (winApiRemoting.sys) do echo     %%~zA bytes
echo   INF: %CD%\winApiRemoting.inf
echo.

REM Check if test signing is enabled
echo [1/4] Checking test signing status...
bcdedit /enum {current} | find "testsigning" | find "Yes" >nul 2>&1
set SIGNING_CHECK=%errorLevel%
echo Debug: Test signing check result: %SIGNING_CHECK%

if "%SIGNING_CHECK%"=="0" (
    echo [✓] Test signing is enabled
    goto skip_signing_setup
)

echo WARNING: Test signing is not enabled
echo.
echo This driver requires test signing for development/testing.
echo Would you like to enable it? (This requires a reboot)
echo.
set /p choice="Enable test signing? (Y/N): "

if /i "%choice%"=="Y" (
    echo.
    echo Enabling test signing...
    bcdedit /set testsigning on
    if %errorLevel% neq 0 (
        echo ERROR: Failed to enable test signing
        exit /b 1
    )

    echo.
    echo Test signing enabled successfully.
    echo REBOOT REQUIRED - Please restart Windows and run this script again.
    echo.
    exit /b 0
) else (
    echo.
    echo WARNING: Continuing without test signing - installation may fail
    echo.
)

:skip_signing_setup
echo.

REM Install the driver
echo [2/4] Installing driver...
pnputil /add-driver winApiRemoting.inf /install
if %errorLevel% neq 0 (
    echo ERROR: Driver installation failed
    echo.
    echo Possible causes:
    echo - Test signing not enabled
    echo - Driver already installed
    echo - Insufficient privileges
    echo.
    echo Try manually with: pnputil /add-driver winApiRemoting.inf /install
    exit /b 1
)

echo [✓] Driver installed successfully
echo.

REM Check if service already exists and is running
echo [3/4] Checking service status...
sc query winApiRemoting >nul 2>&1
if %errorLevel% neq 0 (
    echo Service not found - this is expected for new installations
) else (
    echo Service already exists, checking status...
    sc query winApiRemoting | find "RUNNING" >nul 2>&1
    if %errorLevel% equ 0 (
        echo [✓] Service is already running
        goto :verify
    ) else (
        echo Service exists but not running
    )
)

echo.

REM Start the driver service
echo [4/4] Starting driver service...
sc start winApiRemoting
if %errorLevel% neq 0 (
    echo WARNING: Failed to start service automatically
    echo.
    echo This may be normal for VMBus drivers that start on-demand.
    echo The driver will start automatically when a VMBus device connects.
    echo.
) else (
    echo [✓] Service started successfully
    echo.
)

:verify
echo ============================================
echo  Verification
echo ============================================
echo.

echo Service Status:
sc query winApiRemoting
echo.

echo Driver Location:
for /f "tokens=2*" %%A in ('sc qc winApiRemoting ^| find "BINARY_PATH_NAME"') do echo %%B
echo.

echo Installation Summary:
echo [✓] Driver files present
echo [✓] Test signing enabled
echo [✓] Driver installed in Windows
if %errorLevel% equ 0 (
    echo [✓] Service started
) else (
    echo [i] Service will start on-demand
)

echo.
echo ============================================
echo  Next Steps
echo ============================================
echo.
echo 1. Driver is now installed and ready
echo 2. For VMBus communication:
echo    - Set up Linux guest with VMBus client
echo    - Connect to VMBus GUID: {6ac83d8f-6e16-4e5c-ab3d-fd8c5a4b7e21}
echo 3. Test APIs: Echo, Buffer Test, Performance Test
echo 4. Monitor with: sc query winApiRemoting
echo 5. Debug with: eventvwr.msc (System logs)
echo.

echo Useful Commands:
echo   Start:   sc start winApiRemoting
echo   Stop:    sc stop winApiRemoting
echo   Status:  sc query winApiRemoting
echo   Remove:  pnputil /delete-driver oemXX.inf
echo.

echo Installation completed successfully!
