@echo off
REM Debug Driver Installation Issues
REM Comprehensive diagnostics and alternative installation methods

echo ============================================
echo  Driver Installation Diagnostics
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

echo ============================================
echo  System Diagnostics
echo ============================================
echo.

echo [Test Signing Status]
bcdedit /enum {current} | find "testsigning"
if %errorLevel% neq 0 (
    echo Test signing: NOT CONFIGURED (disabled)
) else (
    bcdedit /enum {current} | find "testsigning" | find "Yes" >nul 2>&1
    if %errorLevel% equ 0 (
        echo Test signing: ENABLED
    ) else (
        echo Test signing: DISABLED
    )
)

echo.
echo [Integrity Checks]
bcdedit /enum {current} | find "nointegritychecks"
if %errorLevel% neq 0 (
    echo Integrity checks: ENABLED (default)
) else (
    bcdedit /enum {current} | find "nointegritychecks" | find "Yes" >nul 2>&1
    if %errorLevel% equ 0 (
        echo Integrity checks: DISABLED (good for development)
    ) else (
        echo Integrity checks: ENABLED
    )
)

echo.
echo [Driver Files Check]
if exist "x64\Debug\winApiRemoting.sys" (
    echo [✓] x64\Debug\winApiRemoting.sys exists
    for %%A in ("x64\Debug\winApiRemoting.sys") do echo     Size: %%~zA bytes
) else (
    echo [❌] x64\Debug\winApiRemoting.sys not found
)

if exist "winApiRemoting.sys" (
    echo [✓] winApiRemoting.sys exists (copied)
    for %%A in ("winApiRemoting.sys") do echo     Size: %%~zA bytes
) else (
    echo [i] winApiRemoting.sys not found in current directory
)

if exist "winApiRemoting.inf" (
    echo [✓] winApiRemoting.inf exists
) else (
    echo [❌] winApiRemoting.inf not found
)

echo.
echo [Previous Installation Check]
pnputil /enum-drivers | findstr -i winApiRemoting >nul 2>&1
if %errorLevel% equ 0 (
    echo [!] Previous driver installation found:
    pnputil /enum-drivers | findstr -i -A5 -B5 winApiRemoting
) else (
    echo [i] No previous driver installation found
)

echo.
echo [Service Check]
sc query winApiRemoting >nul 2>&1
if %errorLevel% equ 0 (
    echo [!] Service already exists:
    sc query winApiRemoting
) else (
    echo [i] Service does not exist
)

echo.
echo ============================================
echo  Installation Attempts
echo ============================================
echo.

REM Copy driver if needed
if not exist "winApiRemoting.sys" (
    if exist "x64\Debug\winApiRemoting.sys" (
        echo [1] Copying driver file...
        copy "x64\Debug\winApiRemoting.sys" "winApiRemoting.sys" >nul
        if %errorLevel% equ 0 (
            echo [✓] Driver copied successfully
        ) else (
            echo [❌] Failed to copy driver
        )
    )
)

echo.
echo [2] Attempting standard installation...
pnputil /add-driver winApiRemoting.inf /install
set INSTALL_RESULT=%errorLevel%
echo Installation exit code: %INSTALL_RESULT%

if %INSTALL_RESULT% neq 0 (
    echo.
    echo [3] Standard installation failed, trying alternative methods...
    echo.

    echo [3a] Removing PnpLockdown and trying again...
    REM Create temporary INF without PnpLockdown
    copy winApiRemoting.inf winApiRemoting_backup.inf >nul

    REM Remove PnpLockdown line
    powershell -Command "(Get-Content 'winApiRemoting.inf') | Where-Object { $_ -notlike '*PnpLockdown*' } | Set-Content 'winApiRemoting_nolockdown.inf'"

    if exist "winApiRemoting_nolockdown.inf" (
        echo [i] Trying installation without PnpLockdown...
        pnputil /add-driver winApiRemoting_nolockdown.inf /install
        set NOLOCKDOWN_RESULT=%errorLevel%
        echo No-lockdown installation exit code: %NOLOCKDOWN_RESULT%

        if %NOLOCKDOWN_RESULT% equ 0 (
            echo [✓] Installation successful without PnpLockdown!
            copy winApiRemoting_nolockdown.inf winApiRemoting.inf >nul
            del winApiRemoting_nolockdown.inf >nul 2>&1
            goto installation_success
        )
    )

    echo.
    echo [3b] Trying force installation...
    pnputil /add-driver winApiRemoting.inf /install /force
    set FORCE_RESULT=%errorLevel%
    echo Force installation exit code: %FORCE_RESULT%

    if %FORCE_RESULT% equ 0 (
        echo [✓] Force installation successful!
        goto installation_success
    )

    echo.
    echo [3c] Cleaning up and retrying...
    echo Removing any existing driver packages...

    for /f "tokens=1,2" %%A in ('pnputil /enum-drivers ^| findstr /C:"Published Name" /C:"Original Name"') do (
        if "%%B"=="winApiRemoting.inf" (
            echo Removing %%A...
            pnputil /delete-driver %%A /force >nul 2>&1
        )
    )

    echo Trying installation after cleanup...
    pnputil /add-driver winApiRemoting.inf /install
    set CLEANUP_RESULT=%errorLevel%
    echo Cleanup + install exit code: %CLEANUP_RESULT%

    if %CLEANUP_RESULT% equ 0 (
        echo [✓] Installation successful after cleanup!
        goto installation_success
    )
) else (
    echo [✓] Standard installation successful!
    goto installation_success
)

echo.
echo ============================================
echo  All Installation Methods Failed
echo ============================================
echo.
echo Possible solutions:
echo 1. Reboot and try again (test signing changes require reboot)
echo 2. Disable Secure Boot in UEFI settings
echo 3. Try: create_cert_powershell.ps1
echo 4. Check Windows Event Viewer for detailed errors
echo.
goto end

:installation_success
echo.
echo ============================================
echo  Installation Successful!
echo ============================================
echo.

echo [4] Starting service...
sc start winApiRemoting >nul 2>&1
if %errorLevel% equ 0 (
    echo [✓] Service started successfully
) else (
    echo [i] Service start returned: %errorLevel%
    echo This is normal for VMBus drivers (they start on-demand)
)

echo.
echo [5] Verification...
sc query winApiRemoting
echo.

pnputil /enum-drivers | findstr -i winApiRemoting

:end
echo.
echo Press any key to exit...
pause >nul