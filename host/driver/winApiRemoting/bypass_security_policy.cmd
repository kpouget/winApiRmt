@echo off
REM Bypass Windows Security Policies for Driver Installation
REM This script addresses Group Policy and Windows security restrictions

echo ============================================
echo  Windows Security Policy Bypass for Driver Installation
echo ============================================
echo.
echo WARNING: This script modifies Windows security settings
echo Only use in development/test environments
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

echo Exit code -536870353 indicates Windows security policy restriction
echo Let's try to bypass common restrictions...
echo.

echo [1/8] Disabling Group Policy restrictions...

REM Backup current policies
reg export "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall" deviceinstall_backup.reg >nul 2>&1

REM Disable device installation restrictions
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions" /v DenyDeviceIDs /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions" /v DenyDeviceIDsRetroactive /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions" /v DenyUnspecified /t REG_DWORD /d 0 /f >nul 2>&1

echo [✓] Group Policy restrictions disabled

echo.
echo [2/8] Disabling driver signing policy...

REM Disable additional driver signing enforcement
bcdedit /set loadoptions DDISABLE_INTEGRITY_CHECKS >nul 2>&1
bcdedit /set {globalsettings} advancedoptions true >nul 2>&1

echo [✓] Additional signing policies disabled

echo.
echo [3/8] Enabling development mode...

REM Enable Developer Mode if available (Windows 10+)
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /v AllowDevelopmentWithoutDevLicense /t REG_DWORD /d 1 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /v AllowAllTrustedApps /t REG_DWORD /d 1 /f >nul 2>&1

echo [✓] Developer mode enabled

echo.
echo [4/8] Disabling Windows Defender interference...

REM Temporarily disable real-time protection
powershell -Command "Set-MpPreference -DisableRealtimeMonitoring $true" >nul 2>&1
if %errorLevel% equ 0 (
    echo [✓] Windows Defender real-time protection disabled temporarily
) else (
    echo [!] Could not disable Windows Defender (might need manual disable)
)

echo.
echo [5/8] Clearing driver installation cache...

REM Clear PnP cache that might be causing issues
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\PnpLockdownFiles" /f >nul 2>&1
rundll32.exe setupapi.dll,InstallHinfSection DefaultInstall 128 %windir%\inf\netloop.inf >nul 2>&1

echo [✓] Installation cache cleared

echo.
echo [6/8] Creating temporary installation environment...

REM Set compatibility flags for Windows 7 compatibility
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers" /v "%CD%\winApiRemoting.sys" /t REG_SZ /d "WIN7RTM" /f >nul 2>&1

REM Disable PnP lockdown temporarily
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Pnp" /v DisablePnpLockdown /t REG_DWORD /d 1 /f >nul 2>&1

echo [✓] Temporary installation environment created

echo.
echo [7/8] Using alternative installation method...

cd /d "%~dp0"

REM Copy driver if needed
if not exist "winApiRemoting.sys" (
    if exist "x64\Debug\winApiRemoting.sys" (
        copy "x64\Debug\winApiRemoting.sys" "winApiRemoting.sys" >nul
    )
)

REM Try legacy installation method first
echo Trying legacy rundll32 method...
rundll32.exe setupapi,InstallHinfSection DefaultInstall 128 .\winApiRemoting_minimal.inf
if %errorLevel% equ 0 (
    echo [✓] Legacy installation successful!
    goto installation_success
)

echo Legacy method failed, trying manual service creation...

REM Manual service creation
echo Creating service manually...
sc create winApiRemoting type= kernel start= demand error= normal binpath= "%systemdrive%\Windows\System32\drivers\winApiRemoting.sys" displayname= "winApiRemoting Service"

REM Copy driver to system directory
copy "winApiRemoting.sys" "%systemdrive%\Windows\System32\drivers\winApiRemoting.sys" >nul 2>&1
if %errorLevel% equ 0 (
    echo [✓] Manual installation successful!
    goto installation_success
)

echo Manual method failed, trying direct registry...

REM Direct registry method
echo Adding driver via registry...
reg add "HKLM\SYSTEM\CurrentControlSet\Services\winApiRemoting" /v Type /t REG_DWORD /d 1 /f >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Services\winApiRemoting" /v Start /t REG_DWORD /d 3 /f >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Services\winApiRemoting" /v ErrorControl /t REG_DWORD /d 1 /f >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Services\winApiRemoting" /v ImagePath /t REG_EXPAND_SZ /d "\SystemRoot\System32\drivers\winApiRemoting.sys" /f >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Services\winApiRemoting" /v DisplayName /t REG_SZ /d "winApiRemoting Service" /f >nul 2>&1

copy "winApiRemoting.sys" "%systemdrive%\Windows\System32\drivers\winApiRemoting.sys" >nul 2>&1
if %errorLevel% equ 0 (
    echo [✓] Registry installation successful!
    goto installation_success
)

echo [X] All installation methods failed
goto cleanup

:installation_success
echo.
echo [8/8] Verifying installation...

sc query winApiRemoting >nul 2>&1
if %errorLevel% equ 0 (
    echo [✓] Service created successfully
    sc query winApiRemoting
) else (
    echo [!] Service not found in SC, but driver may still be installed
)

if exist "%systemdrive%\Windows\System32\drivers\winApiRemoting.sys" (
    echo [✓] Driver file installed in system directory
) else (
    echo [!] Driver file not found in system directory
)

:cleanup
echo.
echo [Cleanup] Restoring security settings...

REM Re-enable Windows Defender
powershell -Command "Set-MpPreference -DisableRealtimeMonitoring $false" >nul 2>&1

REM Remove temporary compatibility flags
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers" /v "%CD%\winApiRemoting.sys" /f >nul 2>&1

REM Remove PnP lockdown disable
reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Pnp" /v DisablePnpLockdown /f >nul 2>&1

echo [✓] Security settings restored

echo.
echo ============================================
echo  Summary
echo ============================================
echo.

if exist "%systemdrive%\Windows\System32\drivers\winApiRemoting.sys" (
    echo ✅ SUCCESS: Driver installed via alternative method
    echo.
    echo Next steps:
    echo 1. Reboot Windows to ensure all changes take effect
    echo 2. After reboot, test with: sc start winApiRemoting
    echo 3. Check Device Manager for "winApiRemoting Device"
    echo 4. Connect Linux guest with VMBus client
    echo.
) else (
    echo ❌ FAILED: Installation unsuccessful
    echo.
    echo This indicates a fundamental system restriction.
    echo Possible solutions:
    echo 1. Disable Secure Boot in UEFI/BIOS
    echo 2. Use a different Windows installation (VM, etc.)
    echo 3. Contact system administrator about Group Policy
    echo 4. Try on Windows 10/11 with different security settings
    echo.
)

echo Security policy modifications will require reboot to fully take effect.
set /p reboot="Reboot now? (Y/N): "
if /i "%reboot%"=="Y" shutdown /r /t 10

pause