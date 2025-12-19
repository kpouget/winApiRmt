@echo off
REM Create Test Certificate for Driver Signing
REM Creates a self-signed certificate for development driver signing

echo ============================================
echo  Driver Test Certificate Creator
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

echo [1/4] Creating test certificate...

REM Try PowerShell method first (modern approach)
echo Trying PowerShell New-SelfSignedCertificate...
powershell -Command "try { $cert = New-SelfSignedCertificate -Subject 'CN=WinApiRemotingTestCert' -CertStoreLocation 'Cert:\LocalMachine\My' -KeyUsage DigitalSignature -KeyAlgorithm RSA -KeyLength 2048 -Provider 'Microsoft Enhanced RSA and AES Cryptographic Provider' -KeyExportPolicy Exportable -KeySpec Signature -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(1); Export-Certificate -Cert $cert -FilePath 'WinApiRemotingTest.cer' -Type CERT; Write-Output 'SUCCESS: PowerShell certificate created' } catch { Write-Output 'FAILED: PowerShell method failed'; exit 1 }" 2>nul

if %errorLevel% equ 0 (
    echo [✓] Certificate created using PowerShell
    goto cert_created
)

REM Fallback to makecert if available
echo PowerShell method failed, trying makecert...
where makecert.exe >nul 2>&1
if %errorLevel% neq 0 (
    REM Try to find makecert in common SDK locations
    set MAKECERT_PATH=""
    if exist "C:\Program Files (x86)\Windows Kits\10\bin\*\x64\makecert.exe" (
        for /d %%i in ("C:\Program Files (x86)\Windows Kits\10\bin\*") do (
            if exist "%%i\x64\makecert.exe" (
                set MAKECERT_PATH="%%i\x64\makecert.exe"
                goto found_makecert
            )
        )
    )

    :found_makecert
    if "%MAKECERT_PATH%"=="" (
        echo ERROR: Neither PowerShell nor makecert methods worked
        echo.
        echo Solutions:
        echo 1. Install Windows 10 SDK with signing tools
        echo 2. Use the unsigned driver installation method
        echo 3. Run: install_driver.cmd (should work without certificates)
        echo.
        pause
        exit /b 1
    )
    set MAKECERT=%MAKECERT_PATH%
) else (
    set MAKECERT=makecert.exe
)

echo Using makecert from: %MAKECERT%
%MAKECERT% -r -pe -ss PrivateCertStore -n "CN=WinApiRemotingTestCert" -eku 1.3.6.1.5.5.7.3.3 WinApiRemotingTest.cer
if %errorLevel% neq 0 (
    echo ERROR: makecert failed
    echo.
    echo Try the unsigned installation method instead:
    echo   install_driver.cmd
    echo.
    pause
    exit /b 1
)

:cert_created

echo [✓] Test certificate created: WinApiRemotingTest.cer
echo.

echo [2/4] Creating catalog file...
inf2cat /driver:. /os:10_X64
if %errorLevel% neq 0 (
    echo ERROR: Failed to create catalog file
    echo Make sure Windows Driver Kit is properly installed
    pause
    exit /b 1
)

echo [✓] Catalog file created: winApiRemoting.cat
echo.

echo [3/4] Signing catalog file...
signtool sign /v /s PrivateCertStore /n "WinApiRemotingTestCert" /t http://timestamp.digicert.com winApiRemoting.cat
if %errorLevel% neq 0 (
    echo ERROR: Failed to sign catalog file
    echo Make sure signtool.exe is available
    pause
    exit /b 1
)

echo [✓] Catalog file signed successfully
echo.

echo [4/4] Installing test certificate to trusted root...
certmgr -add WinApiRemotingTest.cer -s -r localMachine Root
if %errorLevel% neq 0 (
    echo WARNING: Failed to install certificate to trusted root
    echo You may need to install it manually
)

echo.
echo ============================================
echo  Certificate Creation Complete
echo ============================================
echo.

echo Created files:
if exist "WinApiRemotingTest.cer" echo [✓] WinApiRemotingTest.cer (certificate)
if exist "winApiRemoting.cat" echo [✓] winApiRemoting.cat (signed catalog)

echo.
echo The driver is now signed with a test certificate.
echo You can install it using: install_driver.cmd
echo.

echo Security Notes:
echo - This certificate is only for development/testing
echo - Remove test certificates before production deployment
echo - The certificate is installed in the local machine's trusted root
echo.

pause