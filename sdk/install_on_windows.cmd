@echo off
REM Windows Development Tools Installer
REM Automates installation of Visual Studio Community and Windows Driver Kit

echo ============================================
echo  Windows Development Tools Installer
echo ============================================
echo.

REM Check if running as Administrator
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo ERROR: This script must be run as Administrator
    echo Right-click and select "Run as administrator"
    pause
    exit /b 1
)

echo [✓] Running as Administrator
echo.

REM Navigate to script directory
cd /d "%~dp0"

REM Check if installers exist
if not exist "vs_Community.exe" (
    echo ERROR: vs_Community.exe not found
    echo Please run download_windows_dev_tools.sh first to download the installers
    pause
    exit /b 1
)

if not exist "wdksetup.exe" (
    echo ERROR: wdksetup.exe not found
    echo Please run download_windows_dev_tools.sh first to download the installers
    pause
    exit /b 1
)

echo [✓] Found required installer files
echo.

echo ==========================================
echo  Step 1: Installing Visual Studio Community
echo ==========================================
echo.
echo This will install Visual Studio Community 2022 with:
echo • Desktop development with C++
echo • Windows 10 SDK (10.0.22621.0)
echo • MSVC v143 compiler toolset
echo • CMake tools
echo • Windows Driver Kit integration
echo.

echo Starting Visual Studio installation...
vs_Community.exe --add Microsoft.VisualStudio.Workload.NativeDesktop ^
                  --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 ^
                  --add Microsoft.VisualStudio.Component.Windows10SDK.22621 ^
                  --add Microsoft.VisualStudio.Component.VC.CMake.Project ^
                  --add Microsoft.VisualStudio.Component.VC.ATL ^
                  --add Microsoft.VisualStudio.Component.VC.ATLMFC ^
                  --includeRecommended ^
                  --quiet --wait

if %errorLevel% neq 0 (
    echo ERROR: Visual Studio installation failed
    pause
    exit /b 1
)

echo [✓] Visual Studio Community installed successfully
echo.

echo ==========================================
echo  Step 2: Installing Windows Driver Kit (WDK)
echo ==========================================
echo.
echo Installing Windows Driver Kit...

wdksetup.exe /quiet /norestart

if %errorLevel% neq 0 (
    echo ERROR: WDK installation failed
    pause
    exit /b 1
)

echo [✓] Windows Driver Kit installed successfully
echo.

REM Install Windows SDK if available
if exist "winsdksetup.exe" (
    echo ==========================================
    echo  Step 3: Installing Windows SDK (Latest)
    echo ==========================================
    echo.
    echo Installing Windows SDK...

    winsdksetup.exe /quiet /norestart

    if %errorLevel% neq 0 (
        echo WARNING: Windows SDK installation failed
        echo This is optional - you can continue with the existing SDK
    ) else (
        echo [✓] Windows SDK installed successfully
    )
    echo.
)

echo ============================================
echo  Installation Complete!
echo ============================================
echo.
echo [✓] Visual Studio Community 2022
echo [✓] Windows Driver Kit (WDK)
if exist "winsdksetup.exe" echo [✓] Windows SDK

echo.
echo Next Steps:
echo 1. Reboot your system to complete installation
echo 2. Open "Developer Command Prompt for VS 2022"
echo 3. Navigate to your project directory
echo 4. Run: build_driver_manual.cmd
echo.
echo Or use the cross-platform build script:
echo 1. From WSL/SSH: ./build.sh
echo 2. The script will auto-detect and use the installed tools
echo.

echo Installation log saved to: %TEMP%\vs_wdk_install.log

echo.
echo Press any key to exit...
pause >nul