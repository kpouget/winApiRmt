@echo off
REM Complete Environment Diagnostics
REM Let's figure out exactly what's blocking driver installation

echo ============================================
echo  Windows Driver Environment Diagnostics
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

echo [V] Running as Administrator
echo.

echo [WINDOWS VERSION]
ver
echo.
systeminfo | findstr /B /C:"OS Name" /C:"OS Version" /C:"System Type"
echo.

echo [BOOT CONFIGURATION]
bcdedit /enum {current}
echo.

echo [SECURE BOOT STATUS]
powershell -Command "try { $sb = Confirm-SecureBootUEFI; if($sb) { Write-Output 'Secure Boot: ENABLED (This blocks unsigned drivers!)' } else { Write-Output 'Secure Boot: DISABLED' } } catch { Write-Output 'Secure Boot: UNKNOWN (Legacy BIOS or access denied)' }" 2>nul
echo.

echo [GROUP POLICY RESTRICTIONS]
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions" 2>nul
if %errorLevel% equ 0 (
    echo Device install restrictions found:
    reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions" /s
) else (
    echo No Group Policy device install restrictions found
)
echo.

echo [WINDOWS DEFENDER STATUS]
powershell -Command "Get-MpPreference | Select-Object DisableRealtimeMonitoring" 2>nul
echo.

echo [DRIVER SIGNING ENFORCEMENT]
bcdedit /enum {current} | find "loadoptions"
if %errorLevel% equ 0 (
    echo Load options found (may affect driver signing)
) else (
    echo No special load options
)
echo.

echo [CURRENT USER CONTEXT]
whoami
whoami /groups | findstr /C:"S-1-5-32-544"
if %errorLevel% equ 0 (
    echo [V] User is in Administrators group
) else (
    echo [!] User may not have full admin privileges
)
echo.

echo [DRIVER STORE CONTENTS]
echo Checking for any existing winApiRemoting drivers...
pnputil /enum-drivers | findstr -i winApiRemoting
if %errorLevel% neq 0 (
    echo No existing winApiRemoting drivers found
)
echo.

echo [TEST: Simple File Operations]
echo Testing basic file operations...
echo test > test_write.txt 2>nul
if exist test_write.txt (
    echo [V] Can write files in current directory
    del test_write.txt
) else (
    echo [!] Cannot write files - permission issue
)

copy nul test_system.txt >nul 2>&1
if exist test_system.txt (
    echo [V] Basic file operations work
    del test_system.txt
) else (
    echo [!] File operations restricted
)
echo.

echo [WINDOWS FEATURES]
dism /online /get-features | findstr -i "HyperV\|VirtualMachine\|Containers"
echo.

echo [VM DETECTION]
systeminfo | findstr /C:"Virtual" /C:"VMware" /C:"VirtualBox" /C:"Hyper-V"
if %errorLevel% equ 0 (
    echo [!] Running in virtual machine - some restrictions may apply
) else (
    echo Running on physical hardware
)
echo.

echo ============================================
echo  DIAGNOSIS SUMMARY
echo ============================================
echo.

REM Check for common blockers
set BLOCKERS_FOUND=0

echo Checking for common driver installation blockers...
echo.

REM Check Secure Boot
powershell -Command "try { $sb = Confirm-SecureBootUEFI; exit [int]$sb } catch { exit 2 }" 2>nul
if %errorLevel% equ 1 (
    echo [!] BLOCKER: Secure Boot is ENABLED
    echo    - This prevents unsigned driver installation
    echo    - Disable in UEFI/BIOS settings
    set BLOCKERS_FOUND=1
)

REM Check test signing
bcdedit /enum {current} | find "testsigning" | find "Yes" >nul 2>&1
if %errorLevel% neq 0 (
    echo [!] BLOCKER: Test signing is NOT enabled
    echo    - Run: bcdedit /set testsigning on
    echo    - Reboot required
    set BLOCKERS_FOUND=1
)

REM Check Group Policy
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions\DenyUnspecified" >nul 2>&1
if %errorLevel% equ 0 (
    echo [!] BLOCKER: Group Policy blocks unsigned drivers
    echo    - Enterprise/domain restrictions active
    echo    - May require admin policy changes
    set BLOCKERS_FOUND=1
)

REM Check for domain environment
echo %USERDNSDOMAIN% | findstr /R ".*" >nul 2>&1
if %errorLevel% equ 0 (
    echo [!] POTENTIAL BLOCKER: Domain environment detected
    echo    - Enterprise policies may be enforced
    echo    - Contact domain administrator
    set BLOCKERS_FOUND=1
)

echo.
if %BLOCKERS_FOUND% equ 0 (
    echo [?] No obvious blockers found
    echo This suggests a deeper Windows configuration issue
) else (
    echo Found %BLOCKERS_FOUND% potential blocker(s) above
)

echo.
echo ============================================
echo  ALTERNATIVE APPROACHES TO TRY
echo ============================================
echo.

echo 1. COMPLETELY DISABLE DRIVER SIGNATURE ENFORCEMENT:
echo    - Restart Windows
echo    - During boot, press F8 repeatedly
echo    - Select "Disable Driver Signature Enforcement"
echo    - Try driver installation in that session
echo.

echo 2. SAFE MODE WITH TEST SIGNING:
echo    - bcdedit /set {globalsettings} advancedoptions true
echo    - Restart, select Advanced Options
echo    - Boot to Safe Mode
echo    - Try installation there
echo.

echo 3. DIFFERENT WINDOWS ENVIRONMENT:
echo    - Try Windows 10/11 Virtual Machine
echo    - Use Windows 10 with minimal security
echo    - Try Windows Server edition
echo.

echo 4. MANUAL DRIVER LOADING (Expert):
echo    - Use OSR Driver Loader utility
echo    - Try WinObj to manually load driver
echo    - Use DebugView to see what's happening
echo.

echo Current environment analysis complete.
echo Review the findings above to determine next steps.
echo.

pause