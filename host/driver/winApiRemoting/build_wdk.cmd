@echo off
REM Build using WDK tools directly - more reliable for drivers

echo Building WinAPI Remoting Driver using WDK...

REM Set up WDK environment
if exist "%WDK_DIR%" (
    call "%WDK_DIR%\bin\SetupVSEnv.cmd"
) else if exist "C:\Program Files (x86)\Windows Kits\10\bin\SetupVSEnv.cmd" (
    call "C:\Program Files (x86)\Windows Kits\10\bin\SetupVSEnv.cmd"
) else (
    echo Setting up basic environment...
)

REM Use cl.exe directly to compile
echo Compiling source files...

cl.exe /c /nologo /W3 /Zi /Od ^
    /D"_WIN64" /D"WINNT=1" /D"_AMD64_" /D"AMD64" ^
    /Qspectre- /kernel ^
    /I"../../../common" ^
    /I"%WindowsSdkDir%Include\%WindowsSDKVersion%km" ^
    /I"%WindowsSdkDir%Include\%WindowsSDKVersion%shared" ^
    vmbus_privder.c api_handlers.c

if errorlevel 1 (
    echo Compilation failed!
    goto :error
)

echo Linking driver...

link.exe /nologo /DRIVER /SUBSYSTEM:NATIVE /ENTRY:DriverEntry /MACHINE:X64 ^
    /LIBPATH:"%WindowsSdkDir%Lib\%WindowsSDKVersion%km\x64" ^
    /OUT:winApiRemoting.sys ^
    vmbus_privder.obj api_handlers.obj ^
    ntoskrnl.lib hal.lib wmilib.lib

if errorlevel 1 (
    echo Linking failed!
    goto :error
)

echo.
echo ✓ Build successful! Output: winApiRemoting.sys
goto :end

:error
echo Build failed!
exit /b 1

:end