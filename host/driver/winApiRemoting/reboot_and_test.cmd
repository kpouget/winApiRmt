@echo off
REM Final reboot and test sequence
echo ========================================
echo  Reboot and Test Driver
echo ========================================
echo.

net session >nul 2>&1
if errorlevel 1 (
    echo ERROR: Please run as Administrator
    exit /b 1
)

echo Ensuring all boot settings are configured...

REM Apply all necessary boot settings
bcdedit /set testsigning on
bcdedit /set debug on
bcdedit /set nointegritychecks on
bcdedit /set loadoptions DISABLE_INTEGRITY_CHECKS

echo.
echo Boot settings applied:
bcdedit /enum {current} | find /i "testsigning"
bcdedit /enum {current} | find /i "debug"
bcdedit /enum {current} | find /i "nointegritychecks"

echo.
echo Current driver service status:
sc query winApiRemoting 2>nul

echo.
echo *** REBOOT REQUIRED ***
echo.
echo These boot settings take effect only after reboot.
echo After reboot, test the driver with:
echo.
echo   sc start winApiRemoting
echo   sc query winApiRemoting
echo.

choice /c YN /m "Reboot now to activate unsigned driver support"
if errorlevel 2 goto :no_reboot

echo Rebooting in 10 seconds...
shutdown /r /t 10 /c "Reboot to enable unsigned driver loading"
pause
exit /b 0

:no_reboot
echo.
echo Please reboot manually, then test:
echo   sc start winApiRemoting
echo.