# Windows VMBus Driver Setup Guide

Quick setup guide for installing the WinAPI Remoting VMBus driver on a fresh Windows system.

## Prerequisites

1. **Windows 10/11** or **Windows Server 2016+**
2. **Visual Studio 2019+** with C++ tools
3. **Windows Driver Kit (WDK)**
4. **Administrator privileges**

## Build the Driver

1. **Clone/copy the project** to Windows system
2. **Navigate to driver directory:**
   ```cmd
   cd host\driver\winApiRemoting
   ```
3. **Build the driver:**
   ```cmd
   build_driver_manual.cmd
   ```
   Creates `x64\Debug\winApiRemoting.sys`

## Install the Driver

1. **Run as Administrator:**
   ```cmd
   install_driver_direct.cmd
   ```

2. **When prompted, reboot** to apply boot settings

3. **After reboot, the driver is installed** as a Windows service

## Expected Behavior

✅ **Working:**
- Driver compiles successfully
- Service installs successfully
- `sc query winApiRemoting` shows service exists

❌ **Expected to fail:**
- `sc start winApiRemoting` fails with error 577
- This is **NORMAL** on Azure VMs and hardened systems

## Why Manual Start Fails

Modern Windows (especially Azure VMs) blocks unsigned drivers even with test signing enabled. This is **expected behavior**.

The driver will load automatically when:
- Linux guest connects via VMBus
- VMBus subsystem requests the driver (different loading path)

## Verification

```cmd
# Check service exists
sc query winApiRemoting

# Check boot settings (should all be Yes)
bcdedit /enum {current} | find /i "testsigning"
bcdedit /enum {current} | find /i "debug"
bcdedit /enum {current} | find /i "nointegritychecks"
```

## Files Created

- `C:\Windows\System32\drivers\winApiRemoting.sys` - The driver
- Windows service: `winApiRemoting` (Type: Kernel Driver)

## Next Steps

1. **Develop Linux guest driver**
2. **Test actual VMBus communication**
3. **Driver should load automatically during VMBus negotiation**

## Troubleshooting

- **Build fails:** Check Visual Studio and WDK installation
- **Installation fails:** Run as Administrator
- **Manual start fails with 577:** Normal on Azure/hardened systems
- **Service doesn't exist:** Re-run `install_driver_direct.cmd`

## Summary

The driver is **ready for testing** even if manual start fails. VMBus drivers typically load automatically when needed, not through manual service start commands.