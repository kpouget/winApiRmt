@echo off
REM Test Signing Mode Checker and Manager
REM Shows current signing status and provides options to manage it

echo ============================================
echo  Windows Test Signing Mode Manager
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

echo ============================================
echo  Current Boot Configuration
echo ============================================
echo.

echo Checking current boot configuration...
echo.

REM Show current boot entry
echo [Boot Configuration]
bcdedit /enum {current}

echo.
echo ============================================
echo  Test Signing Status Analysis
echo ============================================
echo.

REM Check test signing
echo [Test Signing Status]
bcdedit /enum {current} | find "testsigning" >nul 2>&1
if %errorLevel% equ 0 (
    bcdedit /enum {current} | find "testsigning" | find "Yes" >nul 2>&1
    if %errorLevel% equ 0 (
        echo [✓] Test signing is ENABLED
        set TESTSIGNING_STATUS=ENABLED
    ) else (
        echo [❌] Test signing is DISABLED
        set TESTSIGNING_STATUS=DISABLED
    )
) else (
    echo [❌] Test signing is DISABLED (not configured)
    set TESTSIGNING_STATUS=DISABLED
)

REM Check integrity checks
echo.
echo [Integrity Checks Status]
bcdedit /enum {current} | find "nointegritychecks" >nul 2>&1
if %errorLevel% equ 0 (
    bcdedit /enum {current} | find "nointegritychecks" | find "Yes" >nul 2>&1
    if %errorLevel% equ 0 (
        echo [✓] Integrity checks are DISABLED (development mode)
        set INTEGRITY_STATUS=DISABLED
    ) else (
        echo [❌] Integrity checks are ENABLED (production mode)
        set INTEGRITY_STATUS=ENABLED
    )
) else (
    echo [❌] Integrity checks are ENABLED (default)
    set INTEGRITY_STATUS=ENABLED
)

REM Check UEFI Secure Boot (if available)
echo.
echo [Secure Boot Status]
powershell -Command "try { $sb = Confirm-SecureBootUEFI; if($sb) { Write-Output '[!] Secure Boot is ENABLED' } else { Write-Output '[✓] Secure Boot is DISABLED' } } catch { Write-Output '[i] Secure Boot status unknown (legacy BIOS or access denied)' }" 2>nul

echo.
echo ============================================
echo  Summary
echo ============================================
echo.

if "%TESTSIGNING_STATUS%"=="ENABLED" (
    echo ✅ READY FOR DRIVER DEVELOPMENT
    echo    Test signing is enabled
    echo    You can install unsigned drivers for development
    echo.
) else (
    echo ❌ NOT READY FOR DRIVER DEVELOPMENT
    echo    Test signing is disabled
    echo    Unsigned drivers will be rejected
    echo.
)

echo Current Configuration:
echo   Test Signing:     %TESTSIGNING_STATUS%
echo   Integrity Checks: %INTEGRITY_STATUS%
echo.

echo ============================================
echo  Management Options
echo ============================================
echo.

if "%TESTSIGNING_STATUS%"=="ENABLED" (
    echo [1] Disable test signing (production mode)
    echo [2] Keep current settings
    echo [3] Show boot configuration only
    echo [4] Exit
    echo.
    set /p choice="Select option (1-4): "

    if "%choice%"=="1" (
        echo.
        echo Disabling test signing...
        bcdedit /set testsigning off
        bcdedit /set nointegritychecks off
        echo.
        echo [✓] Test signing disabled
        echo [!] REBOOT REQUIRED to apply changes
        echo.
        set /p reboot="Reboot now? (Y/N): "
        if /i "%reboot%"=="Y" shutdown /r /t 10
    )
) else (
    echo [1] Enable test signing (development mode)
    echo [2] Keep current settings
    echo [3] Show boot configuration only
    echo [4] Exit
    echo.
    set /p choice="Select option (1-4): "

    if "%choice%"=="1" (
        echo.
        echo Enabling test signing for development...
        bcdedit /set testsigning on
        bcdedit /set nointegritychecks on
        echo.
        if %errorLevel% equ 0 (
            echo [✓] Test signing enabled successfully
            echo [!] REBOOT REQUIRED to apply changes
            echo.
            echo After reboot:
            echo - You can install unsigned drivers
            echo - Windows will show "Test Mode" watermark
            echo - Driver installation should work with install_driver.cmd
            echo.
            set /p reboot="Reboot now? (Y/N): "
            if /i "%reboot%"=="Y" shutdown /r /t 10
        ) else (
            echo [❌] Failed to enable test signing
        )
    )
)

if "%choice%"=="3" (
    echo.
    echo ============================================
    echo  Detailed Boot Configuration
    echo ============================================
    echo.
    bcdedit /enum all
)

echo.
echo ============================================
echo  Additional Information
echo ============================================
echo.

echo Useful Commands:
echo   Check status:        bcdedit /enum {current}
echo   Enable test signing: bcdedit /set testsigning on
echo   Disable test signing: bcdedit /set testsigning off
echo   Disable integrity:   bcdedit /set nointegritychecks on
echo   Enable integrity:    bcdedit /set nointegritychecks off
echo.

echo Security Notes:
echo - Test signing bypasses driver signature verification
echo - Only use in development environments
echo - Disable in production systems
echo - Windows will show "Test Mode" watermark when enabled
echo.

echo Driver Development:
echo - With test signing: install_driver.cmd will work
echo - Without test signing: drivers must be properly signed
echo - VMBus drivers require kernel-mode privileges
echo.

pause