# Windows Development Setup

This guide covers setting up the Windows development environment for the WinAPI Remoting Service.

## Dependencies Checklist

Track your installation progress with this comprehensive dependency list:

### Core Dependencies (Required)
- [ ] **Windows 10/11** - Host operating system
- [ ] **PowerShell** - With Administrator privileges
- [ ] **Visual Studio Build Tools** or **Visual Studio 2019+**
  - [ ] C++ development workload
  - [ ] MSVC v143 compiler toolset
  - [ ] Windows 11 SDK (or Windows 10 SDK)
- [ ] **vcpkg Package Manager** - For C++ library management
- [ ] **jsoncpp Library** - JSON parsing (installed via vcpkg)

### Build System (Choose One)
- [ ] **Option A: Direct cl.exe build** - Uses build.cmd script
- [ ] **Option B: CMake build** - More reliable, uses CMakeLists.txt

### Optional Tools
- [ ] **Git for Windows** - For cloning vcpkg (alternative: manual download)
- [ ] **CMake** - Required for CMake build option (install via winget)

### Installation Status Tracking

| Component | Status | Version | Installation Path | Notes |
|-----------|--------|---------|-------------------|-------|
| Windows | ✅/❌ | | | |
| PowerShell | ✅/❌ | | | Admin required |
| Git | ✅/❌ | | | Optional |
| Visual Studio | ✅/❌ | | | C++ workload needed |
| vcpkg | ✅/❌ | | `C:\vcpkg` | Package manager |
| jsoncpp | ✅/❌ | | `C:\vcpkg\installed\x64-windows` | Via vcpkg |
| CMake | ✅/❌ | | `C:\Program Files\CMake` | Optional |

### Verification Commands

Use these commands to verify installations:

```cmd
# Check PowerShell version
$PSVersionTable

# Check Git
git --version

# Check Visual Studio installations
dir "C:\Program Files\Microsoft Visual Studio\" /AD
dir "C:\Program Files (x86)\Microsoft Visual Studio\" /AD

# Check vcpkg
dir C:\vcpkg\vcpkg.exe

# Check jsoncpp
dir "C:\vcpkg\installed\x64-windows\lib\jsoncpp.lib"

# Check CMake
cmake --version

# Check cl.exe (after running vcvars64.bat)
cl.exe
```

## Prerequisites

- Windows 10/11
- PowerShell (Administrator privileges required)
- Visual Studio 2019+ or Build Tools for Visual Studio with C++ workload
- Git for Windows (optional but recommended)

## Step 1: Install vcpkg Package Manager

Open PowerShell as **Administrator** and run these commands:

```cmd
# Clone vcpkg to C:\vcpkg
git clone https://github.com/Microsoft/vcpkg.git C:\vcpkg

# Navigate to vcpkg directory
cd C:\vcpkg

# Bootstrap vcpkg (this compiles vcpkg itself)
.\bootstrap-vcpkg.bat

# Integrate vcpkg with Visual Studio (makes libraries available automatically)
.\vcpkg integrate install
```

The bootstrap process should output something like:
```
Building vcpkg-tool...
Finished building vcpkg-tool.
vcpkg successfully installed
```

### If Git Isn't Available

**Option 1: Install Git**
- Download from https://git-scm.com/download/win
- Install with default options
- Restart PowerShell and try the git clone command

**Option 2: Download vcpkg manually**
- Go to https://github.com/Microsoft/vcpkg/releases
- Download the latest ZIP file
- Extract to `C:\vcpkg`
- Continue with `.\bootstrap-vcpkg.bat`

## Step 2: Install jsoncpp Dependency

```cmd
# Make sure you're still in C:\vcpkg
cd C:\vcpkg

# Install jsoncpp for 64-bit Windows
.\vcpkg install jsoncpp:x64-windows
```

This will download, compile, and install jsoncpp. You'll see output like:
```
Computing installation plan...
The following packages will be built and installed:
    jsoncpp:x64-windows
Starting package 1/1: jsoncpp:x64-windows
Building package jsoncpp:x64-windows...
Package jsoncpp:x64-windows is installed
```

## Step 3: Verify Installation

Check that everything is installed correctly:

```cmd
# List installed packages
.\vcpkg list

# Check specific files exist
dir "C:\vcpkg\installed\x64-windows\include\json\json.h"
dir "C:\vcpkg\installed\x64-windows\lib\jsoncpp.lib"
```

You should see:
- `json.h` in the include directory
- `jsoncpp.lib` in the lib directory

## Step 4: Build the Windows Service

Now you can build the WinAPI Remoting Service:

```cmd
cd C:\path\to\winApiRmt\host\service
build.cmd
```

The warning about jsoncpp should be gone, and the build should succeed with output like:
```
Building Windows API Remoting Service...
=======================================
Checking dependencies...
Cleaning previous build...
Compiling service...
SUCCESS: Service compiled successfully
Binary: ...\WinApiRemotingService.exe
```

## Step 5: Install the Service

```cmd
# Still in host\service directory, run as Administrator
install.cmd
```

## Troubleshooting

### Common Issues

**"git is not recognized"**
- Install Git for Windows from https://git-scm.com/download/win
- Restart PowerShell after installation

**"Visual Studio C++ tools not found"**
- Install Visual Studio with C++ development workload
- Or install Build Tools for Visual Studio 2019+

**"Access denied" during bootstrap**
- Make sure PowerShell is running as Administrator
- Check antivirus software isn't blocking vcpkg

**Build fails with missing headers**
- Verify vcpkg integration: `.\vcpkg integrate install`
- Check that jsoncpp is installed: `.\vcpkg list | findstr json`

### Alternative CMake Build

If the direct cl.exe build doesn't work, you can use CMake with vcpkg:

#### Install CMake
```cmd
# Install CMake via winget
winget install Kitware.CMake

# If CMake is not in PATH after installation, add it temporarily:
$env:PATH += ";C:\Program Files\CMake\bin"

# Or restart PowerShell as Administrator for persistent PATH changes
```

#### Build with CMake
```cmd
# In host\service directory
mkdir build
cd build

cmake .. -DCMAKE_TOOLCHAIN_FILE=C:\vcpkg\scripts\buildsystems\vcpkg.cmake
cmake --build . --config Release

# Executable will be in: build\Release\WinApiRemotingService.exe
```

#### CMake Troubleshooting
**"cmake is not recognized"** - This is common after winget installs:
1. **Restart PowerShell** (recommended) - Close and reopen as Administrator
2. **Add to PATH temporarily**: `$env:PATH += ";C:\Program Files\CMake\bin"`
3. **Use full path**: `"C:\Program Files\CMake\bin\cmake.exe"`

### Error Message Reference

Common error messages and their solutions:

| Error Message | Cause | Solution |
|---------------|--------|----------|
| `WARNING: jsoncpp not found in C:\vcpkg\installed\x64-windows\` | jsoncpp not installed | `.\vcpkg install jsoncpp:x64-windows` |
| `'cl.exe' is not recognized as an internal or external command` | Visual Studio environment not set up | Install Visual Studio Build Tools or use CMake |
| `cmake is not recognized as the name of a cmdlet` | CMake not in PATH | Restart PowerShell or add CMake to PATH |
| `git is not recognized` | Git not installed | Install Git for Windows |
| `Visual Studio C++ tools not found` | Missing C++ workload | Install Visual Studio with C++ development workload |
| `Access denied` during vcpkg bootstrap | Not running as Administrator | Run PowerShell as Administrator |
| `jsoncpp.lib not found` during linking | vcpkg integration issue | Run `.\vcpkg integrate install` |

## Environment Variables (Optional)

For easier development, you can set these environment variables:

```cmd
# Add vcpkg to PATH (optional)
setx PATH "%PATH%;C:\vcpkg"

# Set vcpkg root (for CMake projects)
setx VCPKG_ROOT "C:\vcpkg"
```

## Next Steps

After successful setup:

1. **Build the service**: `build.cmd`
2. **Install the service**: `install.cmd` (as Administrator)
3. **Start the service**: `net start WinApiRemoting`
4. **Test from WSL2**: Run the client test suite

## Useful vcpkg Commands

```cmd
# List all installed packages
.\vcpkg list

# Search for packages
.\vcpkg search [package-name]

# Install additional packages
.\vcpkg install [package]:x64-windows

# Update all packages
.\vcpkg upgrade --no-dry-run

# Remove a package
.\vcpkg remove [package]:x64-windows
```