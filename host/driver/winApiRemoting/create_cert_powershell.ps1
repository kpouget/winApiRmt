# PowerShell Script to Create Test Certificate for Driver Signing
# Run as Administrator: powershell -ExecutionPolicy Bypass -File create_cert_powershell.ps1

Write-Host "============================================" -ForegroundColor Green
Write-Host " Driver Test Certificate Creator (PowerShell)" -ForegroundColor Green
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

try {
    Write-Host "[1/4] Creating self-signed certificate..." -ForegroundColor Yellow

    $cert = New-SelfSignedCertificate `
        -Subject "CN=WinApiRemotingTestCert" `
        -CertStoreLocation "Cert:\LocalMachine\My" `
        -KeyUsage DigitalSignature `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -Provider "Microsoft Enhanced RSA and AES Cryptographic Provider" `
        -KeyExportPolicy Exportable `
        -KeySpec Signature `
        -HashAlgorithm SHA256 `
        -NotAfter (Get-Date).AddYears(1)

    Write-Host "[V] Certificate created in LocalMachine\My store" -ForegroundColor Green
    Write-Host "    Thumbprint: $($cert.Thumbprint)" -ForegroundColor Gray
    Write-Host ""

    Write-Host "[2/4] Exporting certificate to file..." -ForegroundColor Yellow
    Export-Certificate -Cert $cert -FilePath "WinApiRemotingTest.cer" -Type CERT | Out-Null
    Write-Host "[V] Certificate exported: WinApiRemotingTest.cer" -ForegroundColor Green
    Write-Host ""

    Write-Host "[3/4] Installing certificate to Trusted Root..." -ForegroundColor Yellow
    $rootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
    $rootStore.Open("ReadWrite")
    $rootStore.Add($cert)
    $rootStore.Close()
    Write-Host "[V] Certificate installed to Trusted Root store" -ForegroundColor Green
    Write-Host ""

    Write-Host "[4/4] Creating and signing catalog file..." -ForegroundColor Yellow

    # Find inf2cat
    $inf2catPaths = @(
        "C:\Program Files (x86)\Windows Kits\10\bin\*\x64\inf2cat.exe",
        "C:\Program Files (x86)\Windows Kits\10\bin\*\x86\inf2cat.exe"
    )

    $inf2cat = $null
    foreach ($pattern in $inf2catPaths) {
        $found = Get-ChildItem $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            $inf2cat = $found.FullName
            break
        }
    }

    if (-not $inf2cat) {
        Write-Host "[!] inf2cat not found - skipping catalog creation" -ForegroundColor Yellow
        Write-Host "    Driver will install without catalog file" -ForegroundColor Gray
    } else {
        Write-Host "    Using inf2cat: $inf2cat" -ForegroundColor Gray

        # Enable CatalogFile in INF files BEFORE running inf2cat
        Write-Host "    Enabling CatalogFile entries in INF files..." -ForegroundColor Gray

        # Fix main INF
        if (Test-Path "winApiRemoting.inf") {
            $infContent = Get-Content "winApiRemoting.inf"
            $infContent = $infContent -replace "; CatalogFile = winApiRemoting.cat.*", "CatalogFile = winApiRemoting.cat"
            Set-Content "winApiRemoting.inf" $infContent
        }

        # Fix minimal INF
        if (Test-Path "winApiRemoting_minimal.inf") {
            $infContent = Get-Content "winApiRemoting_minimal.inf"
            $infContent = $infContent -replace "; CatalogFile = winApiRemoting.cat.*", "CatalogFile = winApiRemoting.cat"
            Set-Content "winApiRemoting_minimal.inf" $infContent
        }

        # Create catalog
        & $inf2cat /driver:. /os:10_X64 2>$null

        if ($LASTEXITCODE -eq 0 -and (Test-Path "winApiRemoting.cat")) {
            Write-Host "[V] Catalog file created: winApiRemoting.cat" -ForegroundColor Green

            # Find signtool
            $signtoolPaths = @(
                "C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe",
                "C:\Program Files (x86)\Windows Kits\10\bin\*\x86\signtool.exe"
            )

            $signtool = $null
            foreach ($pattern in $signtoolPaths) {
                $found = Get-ChildItem $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($found) {
                    $signtool = $found.FullName
                    break
                }
            }

            if ($signtool) {
                Write-Host "    Signing catalog file..." -ForegroundColor Gray
                & $signtool sign /v /s "My" /sha1 $cert.Thumbprint /fd SHA256 "winApiRemoting.cat" 2>$null

                if ($LASTEXITCODE -eq 0) {
                    Write-Host "[V] Catalog file signed successfully" -ForegroundColor Green
                } else {
                    Write-Host "[!] Failed to sign catalog file" -ForegroundColor Yellow
                }
            } else {
                Write-Host "[!] signtool not found - catalog not signed" -ForegroundColor Yellow
            }
        } else {
            Write-Host "[!] Failed to create catalog file" -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host " Certificate Creation Complete!" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""

    Write-Host "Created files:" -ForegroundColor White
    if (Test-Path "WinApiRemotingTest.cer") {
        Write-Host "[V] WinApiRemotingTest.cer (certificate)" -ForegroundColor Green
    }
    if (Test-Path "winApiRemoting.cat") {
        Write-Host "[V] winApiRemoting.cat (signed catalog)" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor White
    Write-Host "1. Install the driver: install_driver.cmd" -ForegroundColor Gray
    Write-Host "2. Check status: sc query winApiRemoting" -ForegroundColor Gray
    Write-Host ""

    Write-Host "Certificate Details:" -ForegroundColor White
    Write-Host "Subject: $($cert.Subject)" -ForegroundColor Gray
    Write-Host "Issuer: $($cert.Issuer)" -ForegroundColor Gray
    Write-Host "Valid Until: $($cert.NotAfter)" -ForegroundColor Gray
    Write-Host "Thumbprint: $($cert.Thumbprint)" -ForegroundColor Gray

} catch {
    Write-Host ""
    Write-Host "ERROR: Certificate creation failed" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Alternative: Try unsigned driver installation:" -ForegroundColor Yellow
    Write-Host "    install_driver.cmd" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

Write-Host ""