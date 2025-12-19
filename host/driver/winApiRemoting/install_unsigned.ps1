# PowerShell script for unsigned driver installation
# Run as Administrator: powershell -ExecutionPolicy Bypass -File install_unsigned.ps1

Write-Host "============================================" -ForegroundColor Green
Write-Host " Unsigned Driver Installation (PowerShell)" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator" -ForegroundColor Red
    Write-Host "Right-click PowerShell and select 'Run as administrator'" -ForegroundColor Red
    exit 1
}

Write-Host "[V] Running as Administrator" -ForegroundColor Green
Write-Host ""

# Check test signing
Write-Host "[1/5] Checking test signing..." -ForegroundColor Yellow
$bootConfig = bcdedit /enum '{current}' | Out-String
if ($bootConfig -match "testsigning\s+Yes") {
    Write-Host "[V] Test signing is enabled" -ForegroundColor Green
} else {
    Write-Host "[!] Test signing not enabled - enabling now..." -ForegroundColor Yellow
    bcdedit /set testsigning on | Out-Null
    bcdedit /set nointegritychecks on | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[V] Test signing enabled (reboot required)" -ForegroundColor Green
    } else {
        Write-Host "X Failed to enable test signing" -ForegroundColor Red
        Write-Host "You may need to disable Secure Boot in UEFI settings" -ForegroundColor Yellow
    }
}

Write-Host ""

# Check and copy driver files
Write-Host "[2/5] Checking driver files..." -ForegroundColor Yellow

if (-not (Test-Path "winApiRemoting.sys")) {
    if (Test-Path "x64\Debug\winApiRemoting.sys") {
        Copy-Item "x64\Debug\winApiRemoting.sys" "winApiRemoting.sys"
        Write-Host "[V] Driver copied from build directory" -ForegroundColor Green
    } else {
        Write-Host "[X] Driver file not found" -ForegroundColor Red
        Write-Host "Build the driver first using: build_driver_manual.cmd" -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host "[X] Driver file present" -ForegroundColor Green
}

Write-Host ""

# Clean previous installations
Write-Host "[3/5] Cleaning previous installations..." -ForegroundColor Yellow

# Stop and remove service
try {
    Stop-Service winApiRemoting -ErrorAction SilentlyContinue | Out-Null
    sc.exe delete winApiRemoting | Out-Null
    Write-Host "[V] Previous service removed" -ForegroundColor Green
} catch {
    Write-Host "[i] No previous service to remove" -ForegroundColor Gray
}

# Remove driver packages
$driverPackages = pnputil /enum-drivers | Select-String "Published Name|Original Name"
for ($i = 0; $i -lt $driverPackages.Count; $i += 2) {
    if ($driverPackages[$i+1] -match "winApiRemoting") {
        $packageName = ($driverPackages[$i] -split "\s+")[2]
        Write-Host "Removing driver package: $packageName" -ForegroundColor Gray
        pnputil /delete-driver $packageName /force /uninstall 2>$null | Out-Null
    }
}

Write-Host ""

# Try installations
Write-Host "[4/5] Attempting driver installation..." -ForegroundColor Yellow

$methods = @(
    @{ Name = "Standard INF"; File = "winApiRemoting.inf"; Args = @("/add-driver", "winApiRemoting.inf", "/install") },
    @{ Name = "Minimal INF"; File = "winApiRemoting_minimal.inf"; Args = @("/add-driver", "winApiRemoting_minimal.inf", "/install") },
    @{ Name = "Force Standard"; File = "winApiRemoting.inf"; Args = @("/add-driver", "winApiRemoting.inf", "/install", "/force") },
    @{ Name = "Force Minimal"; File = "winApiRemoting_minimal.inf"; Args = @("/add-driver", "winApiRemoting_minimal.inf", "/install", "/force") }
)

$success = $false
foreach ($method in $methods) {
    Write-Host "Trying: $($method.Name)..." -ForegroundColor Gray

    if (Test-Path $method.File) {
        try {
            $result = Start-Process "pnputil" -ArgumentList $method.Args -Wait -PassThru -NoNewWindow -RedirectStandardError "error.txt" -RedirectStandardOutput "output.txt"

            if ($result.ExitCode -eq 0) {
                Write-Host "[V] SUCCESS: $($method.Name) installation worked!" -ForegroundColor Green
                $success = $true
                break
            } else {
                Write-Host "[X] $($method.Name) failed (exit code: $($result.ExitCode))" -ForegroundColor Red
                # Show error details
                if (Test-Path "error.txt") {
                    $errorText = Get-Content "error.txt" -Raw -ErrorAction SilentlyContinue
                    if ($errorText -and $errorText.Trim()) {
                        Write-Host "Error details: $errorText" -ForegroundColor Red
                    }
                    Remove-Item "error.txt" -Force -ErrorAction SilentlyContinue
                }
            }
        } catch {
            Write-Host "[X] $($method.Name) failed with exception: $($_.Exception.Message)" -ForegroundColor Red
        }

        # Clean up output files
        Remove-Item "output.txt" -Force -ErrorAction SilentlyContinue
        Remove-Item "error.txt" -Force -ErrorAction SilentlyContinue

    } else {
        Write-Host "[X] $($method.File) not found" -ForegroundColor Red
    }
}

Write-Host ""

if ($success) {
    Write-Host "[5/5] Verifying installation..." -ForegroundColor Yellow

    # Check driver packages
    $installed = pnputil /enum-drivers | Select-String "winApiRemoting"
    if ($installed) {
        Write-Host "[V] Driver package installed:" -ForegroundColor Green
        $installed | ForEach-Object { Write-Host "    $($_)" -ForegroundColor Gray }
    }

    # Check service
    $service = Get-Service winApiRemoting -ErrorAction SilentlyContinue
    if ($service) {
        Write-Host "[V] Service created: $($service.Status)" -ForegroundColor Green
    } else {
        Write-Host "[i] Service not found (normal for VMBus drivers)" -ForegroundColor Yellow
        Write-Host "    VMBus drivers start automatically when devices connect" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host " Installation Successful!" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor White
    Write-Host "1. Reboot to ensure test signing takes full effect" -ForegroundColor Gray
    Write-Host "2. Connect a Linux guest with VMBus client" -ForegroundColor Gray
    Write-Host "3. Test the API communication" -ForegroundColor Gray

} else {
    Write-Host "============================================" -ForegroundColor Red
    Write-Host " All Installation Methods Failed" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "This indicates a system policy issue:" -ForegroundColor Yellow
    Write-Host "1. Reboot Windows (test signing requires reboot)" -ForegroundColor Gray
    Write-Host "2. Disable Secure Boot in UEFI/BIOS" -ForegroundColor Gray
    Write-Host "3. Check Group Policy restrictions" -ForegroundColor Gray
    Write-Host "4. Try on a different machine or VM" -ForegroundColor Gray
}

Write-Host ""
