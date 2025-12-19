# Driver Signing for WinAPI Remoting Driver

This document explains how to handle driver signing issues during development.

## The Problem

Windows requires drivers to be digitally signed. The error you're seeing:

```
The third-party INF does not contain digital signature information.
```

This occurs because the INF file references a catalog file that doesn't exist.

## Solutions

### Option 1: Unsigned Development (Recommended - Should Work Now!)

**Status**: ✅ **FIXED** - INF file has been modified for unsigned development

The `winApiRemoting.inf` file now has the `CatalogFile` line commented out:
```ini
; CatalogFile = winApiRemoting.cat  ; Uncomment this line if you create a signed catalog
```

**This should work with test signing enabled:**
```cmd
install_driver.cmd
```

**If you're still getting the signing error, make sure test signing is enabled:**
```cmd
test_signing.cmd
# Should show: [✓] Test signing is ENABLED
```

### Option 2: Create Test Certificate (If Unsigned Fails)

If unsigned installation still fails, create a test certificate:

**Method A: PowerShell (Recommended)**
```powershell
# Run PowerShell as Administrator
powershell -ExecutionPolicy Bypass -File create_cert_powershell.ps1
```

**Method B: Batch Script (Fallback)**
```cmd
# Run as Administrator
create_test_cert.cmd
```

Both scripts will:
- Create a self-signed test certificate
- Generate a signed catalog file (if tools available)
- Install the certificate to the trusted root
- Enable the `CatalogFile` line in the INF

**Note**: The PowerShell method is more reliable as it doesn't depend on deprecated `makecert.exe`

### Option 3: Use DevCon (Alternative Installation Method)

DevCon sometimes works better with unsigned drivers:

```cmd
REM Run as Administrator
install_driver_devcon.cmd
```

This uses the Windows Device Console utility instead of PnPUtil.

## Step-by-Step Troubleshooting

### 1. Verify Test Signing is Enabled
```cmd
test_signing.cmd
```

Expected output: `[✓] Test signing is ENABLED`

### 2. Try Unsigned Installation (Current Setup)
```cmd
install_driver.cmd
```

### 3. If Still Fails, Create Test Certificate
```cmd
create_test_cert.cmd
install_driver.cmd
```

### 4. Alternative: Use DevCon
```cmd
install_driver_devcon.cmd
```

## Manual Commands

### Check Current Signing Status
```cmd
bcdedit /enum {current} | findstr testsigning
```

### Enable Test Signing (if needed)
```cmd
bcdedit /set testsigning on
shutdown /r /t 0
```

### Manual Driver Installation
```cmd
REM Method 1: PnPUtil
pnputil /add-driver winApiRemoting.inf /install

REM Method 2: DevCon (if available)
devcon install winApiRemoting.inf "VMBUS\{6ac83d8f-6e16-4e5c-ab3d-fd8c5a4b7e21}"
```

### Check Installation
```cmd
REM Check service
sc query winApiRemoting

REM Check device manager
devmgmt.msc

REM Check installed drivers
pnputil /enum-drivers | findstr winApiRemoting
```

## For Production Deployment

For production use, you'll need:
1. **Code signing certificate** from a trusted CA (like DigiCert, Sectigo)
2. **Windows Hardware Compatibility Program** submission
3. **Microsoft attestation signing** for Windows 10 1607+

But for development and testing, the test certificate approach works perfectly.

## Troubleshooting

### "Access Denied" Errors
- Run as Administrator
- Check UAC settings
- Verify test signing is enabled

### "File Not Found" Errors
- Build the driver first: `build_driver_manual.cmd`
- Check driver exists: `dir x64\Debug\winApiRemoting.sys`

### "Invalid Certificate" Errors
- Install test certificate to trusted root
- Verify certificate store: `certmgr.msc`

### Driver Won't Start
- VMBus drivers start on-demand when devices connect
- Check event logs: `eventvwr.msc`
- Verify VMBus subsystem: `sc query vmbus`

---

For more details, see:
- [DRIVER_INSTALLATION.md](../../../DRIVER_INSTALLATION.md) - Complete installation guide
- [COMPILE.md](COMPILE.md) - Build instructions