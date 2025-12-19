@echo off
REM Install driver without signing (test mode only)
REM Run as Administrator

echo ========================================
echo  Unsigned Driver Installation
echo ========================================
echo.

REM Check if running as Administrator
net session >nul 2>&1
if errorlevel 1 (
    echo ERROR: Please run as Administrator
    echo Right-click and select "Run as administrator"
    pause
    exit /b 1
)

echo [V] Running as Administrator
echo.

REM Check test signing status
echo [1/5] Checking test signing status...
bcdedit /enum {current} | find /i "testsigning" | find /i "Yes" >nul
if errorlevel 1 (
    echo [!] Test signing is DISABLED
    echo.
    echo Current status:
    bcdedit /enum {current} | find /i "testsigning"
    echo.
    echo ENABLING test signing now...
    bcdedit /set testsigning on
    if errorlevel 1 (
        echo [X] Failed to enable test signing
        echo     Make sure you're running as Administrator
        exit /b 1
    )
    echo [V] Test signing enabled
    echo.
    echo *** REBOOT REQUIRED ***
    echo You must restart Windows for test signing to take effect.
    echo After reboot, run this script again.
    echo.
    choice /c YN /m "Reboot now"
    if errorlevel 2 goto :no_reboot
    shutdown /r /t 10 /c "Rebooting to enable driver test signing"
    echo System will reboot in 10 seconds...
    pause
    exit /b 0
    :no_reboot
    echo Please reboot manually and run this script again.
    exit /b 0
) else (
    echo [V] Test signing is enabled
)
echo.

REM Find the driver file
echo [2/5] Locating driver file...
set DRIVER_FILE=
if exist "x64\Debug\winApiRemoting.sys" (
    set DRIVER_FILE=x64\Debug\winApiRemoting.sys
    echo [V] Found driver: %DRIVER_FILE%
) else if exist "winApiRemoting.sys" (
    set DRIVER_FILE=winApiRemoting.sys
    echo [V] Found driver: %DRIVER_FILE%
) else (
    echo [X] Driver file not found!
    echo     Expected locations:
    echo     - x64\Debug\winApiRemoting.sys
    echo     - winApiRemoting.sys
    exit /b 1
)
echo.

REM Copy driver to current directory if needed
if not "%DRIVER_FILE%"=="winApiRemoting.sys" (
    echo     Copying driver to current directory...
    copy "%DRIVER_FILE%" "winApiRemoting.sys" >nul
    if errorlevel 1 (
        echo [X] Failed to copy driver file
        exit /b 1
    )
    echo [V] Driver copied
    echo.
)

REM Check INF file
echo [3/5] Checking INF file...
if not exist "winApiRemoting_minimal.inf" (
    echo [X] winApiRemoting_minimal.inf not found!
    echo     This file is required for unsigned installation.
    dir *.inf
    exit /b 1
)
echo [V] Found INF: winApiRemoting_minimal.inf

REM Prepare driver files
echo [4/5] Preparing driver files...
if not "%DRIVER_FILE%"=="winApiRemoting.sys" (
    echo     Copying driver to current directory...
    copy "%DRIVER_FILE%" "winApiRemoting.sys" >nul
    if errorlevel 1 (
        echo [X] Failed to copy driver file
        exit /b 1
    )
    echo [V] Driver copied to current directory
)

REM Install the driver
echo [5/5] Installing driver package...
echo     Removing any existing driver package...
pnputil /delete-driver winApiRemoting_minimal.inf /uninstall >nul 2>&1

echo     Installing new driver package...
echo     Command: pnputil /add-driver winApiRemoting_minimal.inf /install
echo.

pnputil /add-driver winApiRemoting_minimal.inf /install

set INSTALL_EXIT_CODE=%errorlevel%
echo.
echo     pnputil exit code: %INSTALL_EXIT_CODE%

if %INSTALL_EXIT_CODE% equ 0 (
    echo [V] Driver installation SUCCESS!

    REM Try to start the service
    echo.
    echo Attempting to start service...
    sc start winApiRemoting

    echo.
    echo Service status:
    sc query winApiRemoting

    echo.
    echo [V] Driver installation completed successfully!

) else (
    echo [X] Driver installation FAILED!
    echo.
    echo Common causes:
    echo 1. Test signing not enabled or reboot required
    echo 2. INF file has syntax errors
    echo 3. Driver file is corrupted or missing
    echo.
    exit /b %INSTALL_EXIT_CODE%
)

echo.
echo ========================================
echo  Installation Complete!
echo ========================================
echo.
echo Driver Status:
sc query winApiRemoting
echo.
echo Next steps:
echo 1. Connect a Linux VM with VMBus support
echo 2. Check driver logs: eventvwr ^(Windows Logs ^> System^)
echo 3. Test API communication from Linux guest
echo.
echo To uninstall:
echo   pnputil /delete-driver winApiRemoting_minimal.inf /uninstall
echo.