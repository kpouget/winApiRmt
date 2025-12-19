# Windows Development Tools SDK

This directory contains scripts and installers for setting up the Windows development environment needed to build the VMBus API remoting driver.

## Quick Setup

### 1. Download Required Tools (Linux/WSL)

```bash
# Run from this directory
./download_windows_dev_tools.sh
```

This downloads:
- **Visual Studio Community 2022** (`vs_Community.exe`) - ~4.5 GB
- **Windows Driver Kit (WDK)** (`wdksetup.exe`) - ~1.4 GB
- **Windows SDK** (`winsdksetup.exe`) - Optional, latest version

### 2. Install on Windows

Transfer the downloaded files to your Windows machine, then:

```cmd
REM Run as Administrator
install_on_windows.cmd
```

Or install manually:
1. Run `vs_Community.exe` - Install "Desktop development with C++" workload
2. Run `wdksetup.exe` - Install Windows Driver Kit
3. Run `winsdksetup.exe` - Install additional SDK components (optional)

## Files

| File | Description | Size |
|------|-------------|------|
| `vs_Community.exe` | Visual Studio Community 2022 installer | ~4.5 GB |
| `wdksetup.exe` | Windows Driver Kit (WDK) installer | ~1.4 GB |
| `winsdksetup.exe` | Windows SDK installer | ~1-2 GB |
| `download_windows_dev_tools.sh` | Linux download script | - |
| `install_on_windows.cmd` | Windows automated installer | - |

## Requirements

### For Download (Linux/WSL)
- `wget` or `curl`
- Internet connection
- ~8 GB free disk space

### For Installation (Windows)
- Windows 10/11
- Administrator privileges
- ~15 GB free disk space
- Internet connection (for additional components)

## Manual Installation

If the automated scripts don't work for your setup:

### Visual Studio Community 2022
1. Run `vs_Community.exe`
2. Select "Desktop development with C++" workload
3. Ensure these are selected:
   - MSVC v143 compiler toolset (x64/x86)
   - Windows 10 SDK (10.0.22621.0 or later)
   - CMake tools for Visual Studio

### Windows Driver Kit (WDK)
1. Run `wdksetup.exe`
2. Follow installation wizard
3. Install to default location

## Verification

After installation, verify your setup:

```cmd
REM Open "Developer Command Prompt for VS 2022"
where cl.exe
where link.exe
dir "C:\Program Files (x86)\Windows Kits\10\Include\*km*"
```

## Build the Driver

Once tools are installed:

```bash
# From project root
./build.sh
```

Or from Windows:

```cmd
REM From host/driver/winApiRemoting directory
build_driver_manual.cmd
```

## Troubleshooting

**Download Issues:**
- Check internet connection
- Try using VPN if downloads are blocked
- Verify URLs are still valid (Microsoft occasionally updates them)

**Installation Issues:**
- Ensure running as Administrator
- Disable antivirus temporarily during installation
- Check Windows Update is current
- Verify sufficient disk space

**Build Issues:**
- Verify all tools installed successfully
- Check paths in build scripts match your VS installation
- Ensure WDK version is compatible with your Windows SDK

## Alternative Download Sources

If the automated download fails, get installers manually:

- **Visual Studio Community**: https://visualstudio.microsoft.com/downloads/
- **Windows Driver Kit**: https://docs.microsoft.com/en-us/windows-hardware/drivers/download-the-wdk
- **Windows SDK**: https://developer.microsoft.com/en-us/windows/downloads/windows-sdk/