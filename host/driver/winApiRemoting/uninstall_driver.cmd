@echo off
REM WinAPI Remoting Driver Uninstallation Script
REM Removes the driver from Windows

echo ============================================
echo  WinAPI Remoting Driver Uninstaller
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

echo [1/3] Stopping driver service...
sc query winApiRemoting >nul 2>&1
if %errorLevel% equ 0 (
    echo Service found, attempting to stop...
    sc stop winApiRemoting
    if %errorLevel% equ 0 (
        echo [✓] Service stopped successfully
        timeout /t 2 /nobreak >nul
    ) else (
        echo [i] Service may already be stopped
    )
) else (
    echo [i] Service not found or already removed
)

echo.

echo [2/3] Finding installed driver...
echo Searching for winApiRemoting driver in installed drivers...

REM Find the OEM driver
for /f "tokens=1,2" %%A in ('pnputil /enum-drivers ^| findstr /C:"Published Name" /C:"Original Name"') do (
    if "%%B"=="winApiRemoting.inf" (
        set OEMDRIVER=%%A
        goto :found
    )
    if "%%A"=="Original" if "%%B"=="winApiRemoting.inf" (
        set OEMDRIVER=!OEMDRIVER!
        goto :found
    )
    if "%%A"=="Published" (
        set OEMDRIVER=%%B
    )
)

:found
if defined OEMDRIVER (
    echo [✓] Found driver: %OEMDRIVER%
    echo.

    echo [3/3] Removing driver package...
    pnputil /delete-driver %OEMDRIVER% /force
    if %errorLevel% equ 0 (
        echo [✓] Driver removed successfully
    ) else (
        echo WARNING: Driver removal may have failed
        echo Try manually: pnputil /delete-driver %OEMDRIVER% /force
    )
) else (
    echo [i] Driver not found in installed drivers list
    echo This may mean it was already removed or never installed
)

echo.

echo ============================================
echo  Cleanup Verification
echo ============================================
echo.

echo Checking service status:
sc query winApiRemoting >nul 2>&1
if %errorLevel% equ 0 (
    echo [!] Service still exists - you may need to delete it manually:
    echo     sc delete winApiRemoting
    sc query winApiRemoting
) else (
    echo [✓] Service successfully removed
)

echo.
echo Checking for driver files:
if exist "%SystemRoot%\System32\drivers\winApiRemoting.sys" (
    echo [!] Driver file still exists: %SystemRoot%\System32\drivers\winApiRemoting.sys
    echo     You may need to delete it manually after reboot
) else (
    echo [✓] Driver file removed from system32\drivers
)

echo.
echo Cleaning up local files:
if exist "winApiRemoting.sys" (
    if exist "x64\Debug\winApiRemoting.sys" (
        echo [i] Removing copied driver file from current directory...
        del "winApiRemoting.sys" 2>nul
        if %errorLevel% equ 0 (
            echo [✓] Cleaned up winApiRemoting.sys from current directory
        )
    )
)

echo.
echo ============================================
echo  Uninstallation Summary
echo ============================================
echo.
echo [✓] Service stopped
if defined OEMDRIVER (
    echo [✓] Driver package removed: %OEMDRIVER%
) else (
    echo [i] Driver package not found
)
echo [✓] System cleanup completed

echo.
echo Optional: To disable test signing (if no longer needed):
echo   bcdedit /set testsigning off
echo   bcdedit /set nointegritychecks off
echo   shutdown /r /t 0
echo.

echo Uninstallation completed!
echo.
echo If you need to reinstall the driver later:
echo   build_driver_manual.cmd
echo   install_driver.cmd
echo.

pause