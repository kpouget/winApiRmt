@echo off
REM Check current boot settings for driver loading
echo ========================================
echo  Boot Settings Check
echo ========================================
echo.

echo Current boot configuration:
bcdedit /enum {current}
echo.

echo Key settings for unsigned drivers:
echo.

echo Test Signing:
bcdedit /enum {current} | find /i "testsigning" || echo   NOT SET

echo.
echo Debug Mode:
bcdedit /enum {current} | find /i "debug" || echo   NOT SET

echo.
echo Integrity Checks:
bcdedit /enum {current} | find /i "nointegritychecks" || echo   NOT SET

echo.
echo Driver Signature Enforcement:
bcdedit /enum {current} | find /i "nointegritychecks"
if errorlevel 1 (
    echo   ENABLED ^(blocking unsigned drivers^)
) else (
    echo   DISABLED ^(allowing unsigned drivers^)
)

echo.
echo ========================================

echo If any settings show "NOT SET", run:
echo   bcdedit /set testsigning on
echo   bcdedit /set debug on
echo   bcdedit /set nointegritychecks on
echo   shutdown /r /t 0

echo.
echo If settings are correct but driver still fails:
echo 1. Reboot is required for settings to take effect
echo 2. Some Windows versions need additional bypass methods