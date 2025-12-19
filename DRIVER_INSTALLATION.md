# WinAPI Remoting Driver - Installation & Loading Guide

This guide explains how to install, load, and manage the WinAPI Remoting VMBus driver on Windows.

## Prerequisites

- Windows 10/11 (build 16299 or later)
- Driver built successfully (`winApiRemoting.sys` exists)
- Administrator privileges
- Hyper-V or VMBus environment (for VMBus communication)

## Quick Installation

### 1. Enable Test Signing (Required for Development)

```cmd
REM Run as Administrator
bcdedit /set testsigning on
bcdedit /set nointegritychecks on
shutdown /r /t 0
```

**Important**: Reboot after enabling test signing.

### 2. Install the Driver

```cmd
REM Navigate to driver directory
cd host\driver\winApiRemoting

REM Install driver using PnP Utility
pnputil /add-driver winApiRemoting.inf /install
```

### 3. Start the Driver Service

```cmd
REM Start the service
sc start winApiRemoting

REM Or use net command
net start winApiRemoting
```

### 4. Verify Installation

```cmd
REM Check driver is loaded
sc query winApiRemoting

REM Check in Device Manager
devmgmt.msc
```

## Detailed Installation Steps

### Step 1: Prepare Environment

#### Enable Test Signing
Development drivers need test signing enabled:

```cmd
REM Check current boot configuration
bcdedit /enum {current}

REM Enable test signing
bcdedit /set testsigning on

REM Optional: Disable driver signature enforcement
bcdedit /set nointegritychecks on

REM Reboot to apply changes
shutdown /r /t 0
```

#### Verify Files
Ensure you have the required files:

```cmd
REM Driver is built in x64\Debug directory
dir x64\Debug\winApiRemoting.sys
dir winApiRemoting.inf
```

Expected files:
- `x64\Debug\winApiRemoting.sys` (the driver binary, ~11KB)
- `winApiRemoting.inf` (installation instructions)

**Note**: The `install_driver.cmd` script automatically copies the driver from the build directory to the current directory for installation.

### Step 2: Install Driver Package

#### Method A: Using PnPUtil (Recommended)
```cmd
REM Install driver package
pnputil /add-driver winApiRemoting.inf /install

REM List installed drivers (optional)
pnputil /enum-drivers

REM Find your driver in the list
pnputil /enum-drivers | findstr winApiRemoting
```

#### Method B: Using Device Manager
1. Open Device Manager (`devmgmt.msc`)
2. Right-click any device → "Add legacy hardware"
3. Choose "Install hardware manually"
4. Select "Have Disk" → Browse to `.inf` file
5. Follow installation wizard

#### Method C: Using DISM (Alternative)
```cmd
REM Add driver to driver store
dism /online /add-driver /driver:winApiRemoting.inf
```

### Step 3: Load and Start Driver

#### Start the Driver Service
```cmd
REM Start the service
sc start winApiRemoting

REM Check service status
sc query winApiRemoting

REM Expected output:
REM STATE: 4 RUNNING
```

#### Alternative Service Commands
```cmd
REM Using net command
net start winApiRemoting
net stop winApiRemoting

REM Using PowerShell
Start-Service winApiRemoting
Stop-Service winApiRemoting
Get-Service winApiRemoting
```

### Step 4: Verify Installation

#### Check Service Status
```cmd
REM Service status
sc query winApiRemoting

REM Service configuration
sc qc winApiRemoting

REM Driver file location
sc qc winApiRemoting | findstr BINARY_PATH_NAME
```

#### Check Device Manager
1. Open Device Manager (`devmgmt.msc`)
2. Look under "System devices"
3. Find "winApiRemoting Device"
4. Status should be "This device is working properly"

#### Check System Logs
```cmd
REM View system event logs
eventvwr.msc

REM Or use PowerShell
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='winApiRemoting'}

REM Check kernel debug output (if WinDbg attached)
REM Look for "WinAPI Remoting Driver: DriverEntry" messages
```

#### Verify Driver Loading
```cmd
REM List loaded drivers
driverquery /v | findstr winApiRemoting

REM Check driver details
sc qc winApiRemoting
```

## VMBus Integration

This driver communicates via VMBus with Linux guests.

### Check VMBus Connection
```cmd
REM List VMBus devices
wmic path Win32_PnPEntity where "DeviceID like 'VMBUS\\%'" get DeviceID, Name

REM Look for our GUID: {6ac83d8f-6e16-4e5c-ab3d-fd8c5a4b7e21}
```

### Linux Guest Setup
On the Linux guest, you'll need a corresponding VMBus client to communicate with this driver.

## Management Commands

### Driver Control
```cmd
REM Stop driver
sc stop winApiRemoting
net stop winApiRemoting

REM Start driver
sc start winApiRemoting
net start winApiRemoting

REM Restart driver
sc stop winApiRemoting && sc start winApiRemoting

REM Check driver status
sc query winApiRemoting
```

### Installation Management
```cmd
REM List installed drivers
pnputil /enum-drivers

REM Remove driver (use OEM number from enum-drivers)
pnputil /delete-driver oem123.inf

REM Force remove
pnputil /delete-driver oem123.inf /force
```

### Service Configuration
```cmd
REM Change startup type
sc config winApiRemoting start= auto    (automatic)
sc config winApiRemoting start= demand  (manual - default)
sc config winApiRemoting start= disabled

REM View current configuration
sc qc winApiRemoting
```

## Troubleshooting

### Common Issues

#### 1. "Driver not digitally signed"
**Solution**: Ensure test signing is enabled
```cmd
bcdedit /enum {current} | findstr testsigning
REM Should show: testsigning Yes
```

#### 2. "Service failed to start"
**Solution**: Check event logs and driver file
```cmd
REM Check service status
sc query winApiRemoting

REM Check event logs
eventvwr.msc
REM Navigate to: Windows Logs > System
REM Look for winApiRemoting errors

REM Verify driver file exists
dir %SystemRoot%\System32\drivers\winApiRemoting.sys
```

#### 3. "Device not found in Device Manager"
**Solution**: The driver is VMBus-based and may not appear until a Linux guest connects
```cmd
REM Force device detection
pnputil /scan-devices

REM Check if VMBus subsystem is running
sc query vmbus
```

#### 4. "Access denied"
**Solution**: Run commands as Administrator
```cmd
REM Open elevated command prompt
REM Right-click Command Prompt → "Run as administrator"
```

### Debug Mode

#### Enable Debug Output
Add these registry keys to enable verbose logging:

```cmd
REM Enable debug output (requires reboot)
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Debug Print Filter" /v DEFAULT /t REG_DWORD /d 0xf

REM Or use PowerShell
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Debug Print Filter" -Name DEFAULT -Value 0xf -PropertyType DWord -Force
```

#### Use WinDbg (Advanced)
1. Install Windows SDK with Debugging Tools
2. Attach kernel debugger: `windbg -k net:port=50000,key=1.2.3.4`
3. Look for `KdPrintEx` messages from the driver

#### Check Driver Logs
```cmd
REM View driver-specific events
wevtutil qe System /q:"*[System[Provider[@Name='winApiRemoting']]]" /f:text

REM Live monitoring
wevtutil qe System /q:"*[System[Provider[@Name='winApiRemoting']]]" /f:text /rd:true
```

## Uninstallation

### Remove Driver
```cmd
REM Stop service first
sc stop winApiRemoting

REM Find OEM driver number
pnputil /enum-drivers | findstr -i winApiRemoting

REM Delete driver (replace oemXX.inf with actual number)
pnputil /delete-driver oemXX.inf /force

REM Remove service (if needed)
sc delete winApiRemoting
```

### Disable Test Signing (Optional)
```cmd
REM Disable test signing
bcdedit /set testsigning off
bcdedit /set nointegritychecks off

REM Reboot
shutdown /r /t 0
```

## Security Notes

- Test signing bypasses driver signature verification - only use in development
- Remove test signing in production environments
- The driver runs in kernel mode with full system privileges
- Ensure proper validation of VMBus communication in production

## Integration Testing

Once loaded, test the driver with:

1. **Linux guest communication** - Set up VMBus client on Linux VM
2. **API calls** - Test the Echo, Buffer Test, and Performance Test APIs
3. **Error handling** - Verify proper error responses
4. **Performance** - Measure latency and throughput

---

For build instructions, see [COMPILE.md](host/driver/winApiRemoting/COMPILE.md)
For development setup, see [sdk/README.md](sdk/README.md)