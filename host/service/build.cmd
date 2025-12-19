@echo off
REM Build script for Windows API Remoting Service
REM Requires Visual Studio or Build Tools for Visual Studio

echo Building Windows API Remoting Service...
echo =======================================

REM Find Visual Studio installation
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
    echo ERROR: Visual Studio installer not found
    echo Please install Visual Studio 2019 or later with C++ development tools
    exit /b 1
)

REM Find VS installation path
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do (
    set "VSINSTALLDIR=%%i"
)

if "%VSINSTALLDIR%"=="" (
    echo ERROR: Visual Studio C++ tools not found
    echo Please install Visual Studio with C++ development workload
    exit /b 1
)

REM Setup build environment
call "%VSINSTALLDIR%\VC\Auxiliary\Build\vcvars64.bat"

REM Check for required libraries
echo Checking dependencies...

REM Check for jsoncpp (you may need to install this separately)
if not exist "C:\vcpkg\installed\x64-windows\include\json\json.h" (
    echo WARNING: jsoncpp not found in C:\vcpkg\installed\x64-windows\
    echo.
    echo To install jsoncpp:
    echo   1. Install vcpkg from https://github.com/Microsoft/vcpkg
    echo   2. Run: vcpkg install jsoncpp:x64-windows
    echo   3. Run: vcpkg integrate install
    echo.
)

REM Clean previous build
echo Cleaning previous build...
if exist "WinApiRemotingService.exe" del "WinApiRemotingService.exe"
if exist "*.obj" del "*.obj"
if exist "*.pdb" del "*.pdb"

REM Compile the service
echo Compiling service...
cl.exe /std:c++17 /EHsc /MD ^
    /I"C:\vcpkg\installed\x64-windows\include" ^
    /DWIN32_LEAN_AND_MEAN ^
    /DUNICODE /D_UNICODE ^
    main.cpp ^
    /link ^
    /LIBPATH:"C:\vcpkg\installed\x64-windows\lib" ^
    ws2_32.lib ^
    jsoncpp.lib ^
    advapi32.lib ^
    /OUT:WinApiRemotingService.exe

if errorlevel 1 (
    echo.
    echo ERROR: Compilation failed
    echo.
    echo If you see missing header errors, make sure you have:
    echo   1. Visual Studio C++ tools installed
    echo   2. vcpkg with jsoncpp installed
    echo   3. Windows SDK installed
    echo.
    exit /b 1
)

echo.
echo SUCCESS: Service compiled successfully
echo Binary: %CD%\WinApiRemotingService.exe
echo Size:
for %%F in (WinApiRemotingService.exe) do echo %%~zF bytes

echo.
echo Next steps:
echo   1. Run as Administrator: install.cmd
echo   2. Test: WinApiRemotingService.exe console
echo   3. Start service: net start WinApiRemoting

echo.
echo Build completed successfully!