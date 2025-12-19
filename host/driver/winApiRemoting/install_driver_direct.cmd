@echo off
REM Direct driver installation bypassing pnputil
REM Run as Administrator

echo ========================================
echo  Direct Driver Installation (Bypass)
echo ========================================
echo.

REM Check if running as Administrator
net session >nul 2>&1
if errorlevel 1 (
    echo ERROR: Please run as Administrator
    exit /b 1
)

echo [V] Running as Administrator
echo.

REM Check current boot settings
echo [1/6] Checking boot configuration...
echo Current test signing status:
bcdedit /enum {current} | find /i "testsigning"

echo.
echo Current kernel debugging:
bcdedit /enum {current} | find /i "debug"

echo.
echo Enabling all necessary boot options for unsigned drivers...

REM Enable test signing
bcdedit /set testsigning on

REM Enable kernel debugging (sometimes needed for unsigned drivers)
bcdedit /debug on

REM Disable driver signature enforcement
bcdedit /set nointegritychecks on

echo [V] Boot configuration updated
echo.

REM Find driver
echo [2/6] Locating driver...
set DRIVER_FILE=
if exist "x64\Debug\winApiRemoting.sys" (
    set DRIVER_FILE=x64\Debug\winApiRemoting.sys
    echo [V] Found: %DRIVER_FILE%
) else if exist "winApiRemoting.sys" (
    set DRIVER_FILE=winApiRemoting.sys
    echo [V] Found: %DRIVER_FILE%
) else (
    echo [X] Driver not found!
    exit /b 1
)

REM Copy driver to system32\drivers
echo [3/6] Copying driver to system directory...
copy "%DRIVER_FILE%" "C:\Windows\System32\drivers\winApiRemoting.sys" /Y
if errorlevel 1 (
    echo [X] Failed to copy driver
    exit /b 1
)
echo [V] Driver copied to system32\drivers

REM Delete existing service if it exists
echo [4/6] Removing existing service...
sc delete winApiRemoting >nul 2>&1

REM Create service directly
echo [5/6] Creating service directly...
sc create winApiRemoting ^
    type= kernel ^
    start= demand ^
    error= normal ^
    binpath= "C:\Windows\System32\drivers\winApiRemoting.sys" ^
    displayname= "winApiRemoting Service"

if errorlevel 1 (
    echo [X] Failed to create service
    exit /b 1
)
echo [V] Service created successfully

REM Set service description
sc description winApiRemoting "WinAPI Remoting Driver for VMBus Communication"

REM Try to start the service
echo [6/6] Starting service...
sc start winApiRemoting

if errorlevel 1 (
    echo [!] Service start failed - checking status...
    sc query winApiRemoting
    echo.
    echo This is often normal for demand-start drivers.
    echo The driver will load when VMBus requests it.
) else (
    echo [V] Service started successfully
)

echo.
echo ========================================
echo  Installation Complete!
echo ========================================
echo.

echo Service status:
sc query winApiRemoting

echo.
echo Boot configuration:
bcdedit /enum {current} | find /i "testsigning"
bcdedit /enum {current} | find /i "debug"
bcdedit /enum {current} | find /i "nointegritychecks"

echo.
echo Files installed:
if exist "C:\Windows\System32\drivers\winApiRemoting.sys" (
    echo [V] C:\Windows\System32\drivers\winApiRemoting.sys
    dir "C:\Windows\System32\drivers\winApiRemoting.sys"
) else (
    echo [X] Driver file not found in system32\drivers
)

echo.
echo *** REBOOT RECOMMENDED ***
echo A reboot is recommended to ensure all boot settings take effect.
echo.
echo To test the driver:
echo 1. Reboot the system
echo 2. Connect a Linux VM via VMBus
echo 3. Check: sc query winApiRemoting
echo.
echo To uninstall:
echo   sc stop winApiRemoting
echo   sc delete winApiRemoting
echo   del C:\Windows\System32\drivers\winApiRemoting.sys
echo.