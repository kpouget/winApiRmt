@echo off
REM Force Test Signing Enable and Driver Installation
REM Aggressively enables test signing and tries multiple installation methods

echo ============================================
echo  Force Test Signing and Driver Installation
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

echo [1/6] Checking current boot configuration...
bcdedit /enum {current}

echo.
echo [2/6] Aggressively enabling test signing...

REM Remove any conflicting boot options first
echo Cleaning boot configuration...
bcdedit /deletevalue {current} testsigning >nul 2>&1
bcdedit /deletevalue {current} nointegritychecks >nul 2>&1

echo Enabling test signing...
bcdedit /set {current} testsigning on
if %errorLevel% neq 0 (
    echo ERROR: Failed to enable test signing
    echo This might require disabling Secure Boot in UEFI settings
    pause
    exit /b 1
)

echo Disabling integrity checks...
bcdedit /set {current} nointegritychecks on
if %errorLevel% neq 0 (
    echo WARNING: Failed to disable integrity checks
)

echo Disabling driver signature enforcement temporarily...
bcdedit /set {current} loadoptions DISABLE_INTEGRITY_CHECKS
if %errorLevel% neq 0 (
    echo WARNING: Failed to set load options
)

echo.
echo [3/6] Verifying test signing status...
bcdedit /enum {current} | find "testsigning"
bcdedit /enum {current} | find "nointegritychecks"

echo.
echo [4/6] Copying driver file...
if not exist "winApiRemoting.sys" (
    if exist "x64\Debug\winApiRemoting.sys" (
        copy "x64\Debug\winApiRemoting.sys" "winApiRemoting.sys" >nul
        echo [✓] Driver copied
    ) else (
        echo ERROR: Driver not found
        pause
        exit /b 1
    )
)

echo.
echo [5/6] Cleaning any previous installations...
echo Removing existing driver packages...

for /f "tokens=2" %%A in ('pnputil /enum-drivers ^| findstr /C:"Published Name"') do (
    pnputil /enum-drivers | findstr /A1 "%%A" | findstr /C:"Original Name" | findstr "winApiRemoting" >nul 2>&1
    if not errorlevel 1 (
        echo Removing %%A...
        pnputil /delete-driver %%A /force /uninstall >nul 2>&1
    )
)

echo Stopping any existing service...
sc stop winApiRemoting >nul 2>&1
sc delete winApiRemoting >nul 2>&1

echo.
echo [6/6] Attempting installations...

echo.
echo [Method 1] Standard INF...
pnputil /add-driver winApiRemoting.inf /install
if %errorLevel% equ 0 (
    echo [✓] Standard installation successful!
    goto success
)

echo [Method 1] FAILED - Trying minimal INF...

echo.
echo [Method 2] Minimal INF (no WDF, no lockdown)...
pnputil /add-driver winApiRemoting_minimal.inf /install
if %errorLevel% equ 0 (
    echo [✓] Minimal INF installation successful!
    goto success
)

echo [Method 2] FAILED - Trying force installation...

echo.
echo [Method 3] Force installation...
pnputil /add-driver winApiRemoting_minimal.inf /install /force
if %errorLevel% equ 0 (
    echo [✓] Force installation successful!
    goto success
)

echo [Method 3] FAILED - Trying legacy method...

echo.
echo [Method 4] Legacy rundll32 method...
rundll32.exe setupapi,InstallHinfSection DefaultInstall 128 .\winApiRemoting_minimal.inf
if %errorLevel% equ 0 (
    echo [✓] Legacy installation successful!
    goto success
)

echo.
echo ============================================
echo  All Methods Failed
echo ============================================
echo.
echo This suggests a deeper Windows policy issue.
echo.
echo Next steps to try:
echo 1. Reboot Windows (test signing changes require reboot)
echo 2. Disable Secure Boot in UEFI/BIOS settings
echo 3. Check Group Policy: gpedit.msc
echo    - Computer Config > Administrative Templates > System > Device Installation
echo    - Disable "Prevent installation of devices not described by other policy"
echo 4. Try on a different Windows machine or VM
echo.
echo Current boot settings will require reboot to take effect.
set /p reboot="Reboot now? (Y/N): "
if /i "%reboot%"=="Y" shutdown /r /t 10
goto end

:success
echo.
echo ============================================
echo  Installation Successful!
echo ============================================
echo.

echo Checking service...
sc query winApiRemoting
if %errorLevel% neq 0 (
    echo Service not found (this is normal for VMBus drivers)
    echo VMBus drivers typically start on-demand when devices connect
)

echo.
echo Driver successfully installed!
echo Test signing is now enabled - reboot to ensure all settings take effect.
echo.

:end
pause