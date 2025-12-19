@echo off
REM Manual Driver Build Script
REM This script compiles and links the WinAPI remoting driver manually

echo =====================================
echo  WinAPI Remoting Driver Build Script
echo =====================================
echo.

REM Navigate to project root
cd /d "%~dp0"

REM Create build directories
echo [0/3] Creating build directories...
if not exist "x64" mkdir "x64"
if not exist "x64\Debug" mkdir "x64\Debug"
if not exist "x64\Release" mkdir "x64\Release"
echo Build directories ready.
echo.

REM Clean old object files
echo [1/4] Cleaning old object files...
if exist "x64\Debug\*.obj" del "x64\Debug\*.obj"
echo Done.
echo.

REM Set up x64 environment
echo Setting up x64 build environment...
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvarsall.bat" x64 2>nul
if errorlevel 1 call "C:\Program Files (x86)\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64 2>nul
if errorlevel 1 call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64 2>nul

REM Verify x64 environment
echo Checking compiler version...
cl.exe 2>nul | find "for x64" >nul
if errorlevel 1 (
    echo WARNING: Compiler might not be set for x64
    echo Attempting to continue...
) else (
    echo OK: x64 compiler detected
)

REM Compile source files
echo [2/4] Compiling source files for x64...
cl.exe /c /kernel /GS- /Oi- /W3 ^
/I"C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0\km" ^
/I"C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0\shared" ^
/I"C:\Program Files (x86)\Windows Kits\10\Include\wdf\kmdf\1.33" ^
/I"../../../common" ^
/D_WIN64 /D_AMD64_ /DAMD64 /DWINNT=1 /favor:AMD64 ^
/Fo"x64\Debug\\" ^
api_handlers.c vmbus_privder.c

if errorlevel 1 (
    echo.
    echo *** COMPILATION FAILED ***
    echo Check the errors above and fix them.
    exit /b 1
)

echo Compilation successful.
echo.

REM Link the driver
echo [3/4] Linking driver...
cd x64\Debug

link.exe /DRIVER /SUBSYSTEM:NATIVE /ENTRY:DriverEntry /MACHINE:X64 ^
/LIBPATH:"C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\km\x64" ^
/LIBPATH:"C:\Program Files (x86)\Windows Kits\10\lib\wdf\kmdf\x64\1.33" ^
/OUT:winApiRemoting.sys ^
api_handlers.obj vmbus_privder.obj ^
ntoskrnl.lib hal.lib wmilib.lib WdfLdr.lib WdfDriverEntry.lib BufferOverflowK.lib

if errorlevel 1 (
    echo.
    echo *** LINKING FAILED ***
    echo Check the errors above and fix them.
    cd ..\..
    exit /b 1
)

cd ..\..

REM Verify build output
echo [4/4] Verifying build output...
if exist "x64\Debug\winApiRemoting.sys" (
    echo [V] winApiRemoting.sys created successfully
) else (
    echo [X] ERROR: winApiRemoting.sys not found!
    exit /b 1
)

echo.
echo =====================================
echo  BUILD SUCCESSFUL!
echo =====================================
echo.
echo Driver created: x64\Debug\winApiRemoting.sys
echo.

REM Show file information
if exist "x64\Debug\winApiRemoting.sys" (
    echo File details:
    dir "x64\Debug\winApiRemoting.sys"
    echo.
    echo Driver is ready for installation!
) else (
    echo ERROR: winApiRemoting.sys was not created!
)

echo.
echo Build completed.
