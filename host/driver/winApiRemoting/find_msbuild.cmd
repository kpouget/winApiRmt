@echo off
echo Looking for MSBuild...

REM Check common MSBuild locations
set LOCATIONS=^
"%ProgramFiles%\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin" ^
"%ProgramFiles%\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin" ^
"%ProgramFiles%\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin" ^
"%ProgramFiles%\Microsoft Visual Studio\2019\Professional\MSBuild\Current\Bin" ^
"%ProgramFiles%\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin" ^
"%ProgramFiles%\Microsoft Visual Studio\2019\Enterprise\MSBuild\Current\Bin" ^
"%ProgramFiles(x86)%\Microsoft Visual Studio\2019\Professional\MSBuild\Current\Bin" ^
"%ProgramFiles(x86)%\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin" ^
"%ProgramFiles(x86)%\Microsoft Visual Studio\2019\Enterprise\MSBuild\Current\Bin"

for %%L in (%LOCATIONS%) do (
    if exist %%L\MSBuild.exe (
        echo Found MSBuild at: %%L\MSBuild.exe
        echo.
        echo To add to PATH temporarily, run:
        echo set PATH=%%L;%%PATH%%
        echo.
        echo Or to build directly:
        echo %%L\MSBuild.exe winApiRemoting.vcxproj /p:Configuration=Debug /p:Platform=x64
    )
)

echo.
echo If none found, try opening "Developer Command Prompt for VS" from Start Menu