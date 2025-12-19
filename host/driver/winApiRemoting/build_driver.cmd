@echo off
REM Windows Driver Build Script

echo Building WinAPI Remoting Driver...

REM Try to find and set up MSBuild paths
set "MSBUILD_PATH="
if exist "%ProgramFiles%\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe" (
    set "MSBUILD_PATH=%ProgramFiles%\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe"
) else if exist "%ProgramFiles%\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe" (
    set "MSBUILD_PATH=%ProgramFiles%\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe"
) else if exist "%ProgramFiles%\Microsoft Visual Studio\2019\Professional\MSBuild\Current\Bin\MSBuild.exe" (
    set "MSBUILD_PATH=%ProgramFiles%\Microsoft Visual Studio\2019\Professional\MSBuild\Current\Bin\MSBuild.exe"
) else if exist "%ProgramFiles%\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin\MSBuild.exe" (
    set "MSBUILD_PATH=%ProgramFiles%\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin\MSBuild.exe"
) else if exist "%ProgramFiles(x86)%\Microsoft Visual Studio\2019\Professional\MSBuild\Current\Bin\MSBuild.exe" (
    set "MSBUILD_PATH=%ProgramFiles(x86)%\Microsoft Visual Studio\2019\Professional\MSBuild\Current\Bin\MSBuild.exe"
) else if exist "%ProgramFiles(x86)%\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin\MSBuild.exe" (
    set "MSBUILD_PATH=%ProgramFiles(x86)%\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin\MSBuild.exe"
) else (
    echo ERROR: MSBuild not found! Please install Visual Studio 2019 or 2022.
    goto :error
)

echo Found MSBuild at: %MSBUILD_PATH%

REM Set up VS environment
call "%ProgramFiles(x86)%\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvarsall.bat" x64 2>nul
if errorlevel 1 call "%ProgramFiles(x86)%\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64 2>nul

REM Build the driver using MSBuild with explicit settings
"%MSBUILD_PATH%" winApiRemoting.vcxproj ^
    /p:Configuration=Debug ^
    /p:Platform=x64 ^
    /p:SpectreMitigation=false ^
    /p:UseSpectreMitigatedLibraries=false ^
    /flp:logfile=build.log;verbosity=detailed || goto :error

echo Build completed successfully!
echo Output: x64\Debug\winApiRemoting.sys
goto :end

:error
echo Build failed! Check build.log for details.
exit /b 1

:end