# WinAPI Remoting Driver - Compilation Guide

This document explains how to compile the Windows VMBus API remoting driver from different environments.

## Quick Start (Recommended)

### From Any Environment (Linux/WSL/SSH/Windows)

The easiest way to compile is using the cross-platform build script from the project root:

```bash
./build.sh
```

This script:
- Auto-detects your environment (WSL, SSH, or direct Windows access)
- Sets up Visual Studio build tools automatically
- Handles all environment configuration internally
- Works from Linux, WSL, SSH connections, or Windows

**Requirements**: Windows with Visual Studio 2019/2022 and WDK installed (see Environment Requirements below)

### From Developer Command Prompt (Alternative)

If you're already in a **Developer Command Prompt for VS**, you can run the Windows batch file directly:

```cmd
build_driver_manual.cmd
```

## Manual Compilation from Different Environments

**Note**: The manual methods below are alternatives to the recommended `./build.sh` script above. Use these if you need custom build configurations or if the automated script doesn't work for your specific setup.

### 1. From SSH Connection

When connecting via SSH, you won't have the Visual Studio environment set up by default.

#### Option A: Setup and Build in One Command
```bash
# Create a batch file that sets up everything
cat > build_ssh.cmd << 'EOF'
@echo off
echo Setting up Visual Studio environment for SSH build...

REM Set up Visual Studio environment
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvarsall.bat" x64 2>nul
if errorlevel 1 call "C:\Program Files (x86)\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64 2>nul
if errorlevel 1 call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64 2>nul

if errorlevel 1 (
    echo ERROR: Could not find Visual Studio installation
    echo Please install Visual Studio 2019 or 2022 with C++ tools
    pause
    exit /b 1
)

echo Visual Studio environment configured successfully
echo.

REM Run the build
call build_driver_manual.cmd
EOF

# Make it executable and run
chmod +x build_ssh.cmd
./build_ssh.cmd
```

#### Option B: Manual SSH Steps
```bash
# Step 1: Set up VS environment
cmd /c '"C:\Program Files (x86)\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64 && build_driver_manual.cmd'
```

### 2. From PowerShell

#### Option A: Direct PowerShell Command
```powershell
# Set up environment and build in one line
& cmd /c '"C:\Program Files (x86)\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64 && build_driver_manual.cmd'
```

#### Option B: PowerShell Script
```powershell
# Create PowerShell build script
@'
# PowerShell wrapper for driver build
Write-Host "Setting up Visual Studio environment..." -ForegroundColor Green

$vsVersions = @(
    "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvarsall.bat",
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat",
    "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat"
)

$vsFound = $false
foreach ($vsPath in $vsVersions) {
    if (Test-Path $vsPath) {
        Write-Host "Found Visual Studio at: $vsPath" -ForegroundColor Yellow
        & cmd /c "`"$vsPath`" x64 && build_driver_manual.cmd"
        $vsFound = $true
        break
    }
}

if (-not $vsFound) {
    Write-Host "ERROR: Visual Studio not found!" -ForegroundColor Red
    Write-Host "Please install Visual Studio 2019 or 2022 with C++ development tools"
    exit 1
}
'@ | Out-File -FilePath "Build-Driver.ps1" -Encoding utf8

# Run the PowerShell script
.\Build-Driver.ps1
```

#### Option C: Simple PowerShell One-liner
```powershell
# Quick build from PowerShell
Start-Process cmd -ArgumentList '/c "C:\Program Files (x86)\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64 && build_driver_manual.cmd && pause' -Wait
```

### 3. From Regular Command Prompt

```cmd
REM Set up environment manually
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64

REM Then build
build_driver_manual.cmd
```

## Environment Requirements

### Prerequisites
- **Visual Studio 2019 or 2022** with C++ development tools
- **Windows Driver Kit (WDK)**
- **Windows SDK** 10.0.22621.0 or later

### Verify Installation
Check that these paths exist on your system:
```cmd
dir "C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0\km"
dir "C:\Program Files (x86)\Windows Kits\10\lib\10.0.22621.0\km\x64"
dir "C:\Program Files (x86)\Windows Kits\10\lib\wdf\kmdf\x64\1.33"
```

## Build Script Details

The `build_driver_manual.cmd` script performs these steps:

1. **Environment Setup**: Configures x64 Visual Studio environment
2. **Cleanup**: Removes old object files
3. **Compilation**: Compiles source files with kernel-mode flags
4. **Linking**: Links the driver with required WDF and kernel libraries
5. **Verification**: Confirms `winApiRemoting.sys` was created

### Expected Output
```
=====================================
 WinAPI Remoting Driver Build Script
=====================================

[1/3] Cleaning old object files...
Done.

Setting up x64 build environment...
Checking compiler version...
OK: x64 compiler detected

[2/3] Compiling source files for x64...
[Compilation output...]
Compilation successful.

[3/3] Linking driver...
[Linking output...]

=====================================
 BUILD SUCCESSFUL!
=====================================

Driver created: x64\Debug\winApiRemoting.sys

File details:
12/19/2025  10:34 AM            11,264 winApiRemoting.sys

Driver is ready for installation!

Note: The driver is built in the x64\Debug subdirectory.
The install_driver.cmd script will automatically copy it to the
current directory for installation.
```

## Troubleshooting

**First**: If you're having build issues, try using the recommended `./build.sh` script from the project root, which handles most environment setup issues automatically.

### Common Issues

#### 1. "Visual Studio not found"
**Solution**: Update the paths in the scripts to match your VS installation:
```cmd
# Check where VS is installed
dir "C:\Program Files*\Microsoft Visual Studio"
```

#### 2. "WDK not found"
**Solution**: Install Windows Driver Kit from Microsoft
```
https://docs.microsoft.com/en-us/windows-hardware/drivers/download-the-wdk
```

#### 3. "Permission denied" in SSH
**Solution**: Ensure you're running as Administrator or have developer permissions

#### 4. "Module machine type conflicts"
**Solution**: The build script handles this, but if it persists, manually clean:
```cmd
del x64\Debug\*.obj
```

### Debug Build Issues

If the build fails, check:
1. **Visual Studio environment**: `echo %VCINSTALLDIR%` should show a path
2. **Compiler architecture**: `cl.exe` should show "for x64"
3. **Library paths**: Verify WDK paths exist

## Alternative Build Methods

### Using MSBuild (Advanced)
```cmd
# After setting up VS environment
msbuild winApiRemoting.vcxproj /p:Configuration=Debug /p:Platform=x64 /t:Build
```

### Direct Compilation (Expert)
```cmd
# Manual compilation for experts
cl.exe /c /kernel /GS- /Oi- /W3 /I"path\to\headers" api_handlers.c vmbus_privder.c
link.exe /DRIVER /SUBSYSTEM:NATIVE /ENTRY:DriverEntry /OUT:driver.sys *.obj libs...
```

## Next Steps After Build

Once `winApiRemoting.sys` is built:

### Quick Installation
```cmd
REM Run as Administrator from driver directory
install_driver.cmd
```

### Manual Installation
1. **Enable test signing**: `bcdedit /set testsigning on` (requires reboot)
2. **Install driver**: `pnputil /add-driver winApiRemoting.inf /install`
3. **Start service**: `sc start winApiRemoting`
4. **Verify**: `sc query winApiRemoting`

### Testing & Management
- **Test functionality**: Use test applications or Linux guest VMBus client
- **Monitor driver**: `sc query winApiRemoting` or Device Manager
- **View logs**: Event Viewer → Windows Logs → System
- **Uninstall**: `uninstall_driver.cmd`
- **Debug**: Use WinDbg or Visual Studio kernel debugging

### Detailed Instructions
For complete installation, troubleshooting, and management instructions, see:
**[DRIVER_INSTALLATION.md](../../../DRIVER_INSTALLATION.md)**

---

*For questions or issues, refer to the main project README or check the build logs.*