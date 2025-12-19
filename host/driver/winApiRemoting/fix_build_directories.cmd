@echo off
REM Fix Build Directories and Permissions
REM Creates necessary directories and fixes permissions

echo ============================================
echo  Build Directory Setup and Permissions Fix
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

REM Navigate to driver directory
cd /d "%~dp0"

echo [1/4] Creating build directories...
if not exist "x64" mkdir "x64"
if not exist "x64\Debug" mkdir "x64\Debug"
if not exist "x64\Release" mkdir "x64\Release"
if not exist "x86" mkdir "x86"
if not exist "x86\Debug" mkdir "x86\Debug"
if not exist "x86\Release" mkdir "x86\Release"

echo [V] Build directories created:
dir x64 /s /b 2>nul
echo.

echo [2/4] Setting directory permissions...
REM Give full control to current user and administrators
icacls "x64" /grant "%USERNAME%:F" /T >nul 2>&1
icacls "x64" /grant "Administrators:F" /T >nul 2>&1

echo [V] Permissions set
echo.

echo [3/4] Cleaning any locked files...
REM Remove any existing object files that might be locked
del "x64\Debug\*.obj" /Q >nul 2>&1
del "x64\Debug\*.pdb" /Q >nul 2>&1
del "x64\Debug\*.sys" /Q >nul 2>&1

REM Remove read-only attributes if any
attrib -R "x64\*.*" /S >nul 2>&1

echo [V] Cleanup completed
echo.

echo [4/4] Verifying setup...
echo Current directory: %CD%
echo Build directories:
if exist "x64\Debug" (
    echo [V] x64\Debug exists
) else (
    echo [X] x64\Debug missing
)

echo.
echo Directory permissions:
icacls "x64\Debug" 2>nul

echo.
echo ============================================
echo  Build Environment Ready
echo ============================================
echo.

echo You can now run: build_driver_manual.cmd
echo.

pause