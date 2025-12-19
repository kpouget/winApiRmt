# Clean up duplicate certificates and sign catalog
# Run as Administrator

Write-Host "============================================" -ForegroundColor Green
Write-Host " Certificate Cleanup and Signing" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator" -ForegroundColor Red
    exit 1
}

try {
    # Find signtool first
    Write-Host "[1/5] Finding signtool..." -ForegroundColor Yellow
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

    if (-not $signtool) {
        Write-Host "[!] signtool not found!" -ForegroundColor Red
        exit 1
    }
    Write-Host "[V] signtool: $signtool" -ForegroundColor Green
    Write-Host ""

    # Clean up duplicate certificates
    Write-Host "[2/5] Cleaning up duplicate certificates..." -ForegroundColor Yellow
    $allTestCerts = Get-ChildItem "Cert:\LocalMachine\My" | Where-Object {$_.Subject -like "*WinApiRemotingTestCert*"}

    Write-Host "    Found $($allTestCerts.Count) WinApiRemotingTestCert certificates" -ForegroundColor Gray

    if ($allTestCerts.Count -gt 1) {
        Write-Host "    Removing duplicates, keeping the newest..." -ForegroundColor Gray

        # Sort by creation date, keep the newest one
        $sortedCerts = $allTestCerts | Sort-Object NotBefore -Descending
        $keepCert = $sortedCerts[0]

        Write-Host "    Keeping: $($keepCert.Thumbprint) (Created: $($keepCert.NotBefore))" -ForegroundColor Gray

        # Remove the rest
        for ($i = 1; $i -lt $sortedCerts.Count; $i++) {
            $oldCert = $sortedCerts[$i]
            Write-Host "    Removing: $($oldCert.Thumbprint)" -ForegroundColor Gray
            Remove-Item "Cert:\LocalMachine\My\$($oldCert.Thumbprint)" -Force -ErrorAction SilentlyContinue
        }

        $cert = $keepCert
    } elseif ($allTestCerts.Count -eq 1) {
        Write-Host "    Using existing certificate" -ForegroundColor Gray
        $cert = $allTestCerts[0]
    } else {
        Write-Host "    No existing certificates found, creating new one..." -ForegroundColor Gray
        $cert = $null
    }

    # Create new certificate if needed
    if (-not $cert) {
        Write-Host "[3/5] Creating new code signing certificate..." -ForegroundColor Yellow

        $cert = New-SelfSignedCertificate `
            -Subject "CN=WinApiRemotingTestCert" `
            -CertStoreLocation "Cert:\LocalMachine\My" `
            -KeyUsage DigitalSignature `
            -KeyAlgorithm RSA `
            -KeyLength 2048 `
            -KeyExportPolicy Exportable `
            -KeySpec Signature `
            -HashAlgorithm SHA256 `
            -NotAfter (Get-Date).AddYears(1) `
            -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3")  # Code Signing EKU

        Write-Host "[V] New certificate created: $($cert.Thumbprint)" -ForegroundColor Green
    } else {
        Write-Host "[3/5] Using existing certificate..." -ForegroundColor Yellow
        Write-Host "[V] Certificate: $($cert.Thumbprint)" -ForegroundColor Green
    }

    Write-Host "    Subject: $($cert.Subject)" -ForegroundColor Gray
    Write-Host "    Valid Until: $($cert.NotAfter)" -ForegroundColor Gray
    Write-Host "    Has Private Key: $($cert.HasPrivateKey)" -ForegroundColor Gray
    Write-Host ""

    # Install to trusted root
    Write-Host "[4/5] Installing to Trusted Root store..." -ForegroundColor Yellow
    $rootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
    $rootStore.Open("ReadWrite")

    # Check if already there
    $rootCerts = $rootStore.Certificates | Where-Object {$_.Thumbprint -eq $cert.Thumbprint}
    if ($rootCerts.Count -eq 0) {
        $rootStore.Add($cert)
        Write-Host "[V] Certificate added to Trusted Root" -ForegroundColor Green
    } else {
        Write-Host "[V] Certificate already in Trusted Root" -ForegroundColor Green
    }
    $rootStore.Close()
    Write-Host ""

    # Check catalog file
    if (-not (Test-Path "winApiRemoting.cat")) {
        Write-Host "    Catalog file missing, creating..." -ForegroundColor Yellow

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

        if ($inf2cat) {
            # Enable CatalogFile in minimal INF
            if (Test-Path "winApiRemoting_minimal.inf") {
                $infContent = Get-Content "winApiRemoting_minimal.inf"
                $infContent = $infContent -replace "; CatalogFile = winApiRemoting.cat.*", "CatalogFile = winApiRemoting.cat"
                Set-Content "winApiRemoting_minimal.inf" $infContent
            }

            & $inf2cat /driver:. /os:10_X64 2>$null

            if (Test-Path "winApiRemoting.cat") {
                Write-Host "[V] Catalog created" -ForegroundColor Green
            } else {
                Write-Host "[!] Catalog creation failed" -ForegroundColor Red
            }
        }
    }

    # Try signing the catalog
    Write-Host "[5/5] Signing catalog..." -ForegroundColor Yellow

    if (Test-Path "winApiRemoting.cat") {
        # Method 1: Sign by subject name
        Write-Host "    Trying subject name method..." -ForegroundColor Gray
        $signOutput1 = & $signtool sign /v /s "My" /n "WinApiRemotingTestCert" /fd SHA256 "winApiRemoting.cat" 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-Host "[V] SUCCESS: Catalog signed!" -ForegroundColor Green

            # Verify signature
            $verifyOutput = & $signtool verify /pa /v "winApiRemoting.cat" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[V] Signature verification passed!" -ForegroundColor Green
            }
        } else {
            # Method 2: Try by thumbprint
            Write-Host "    Subject name failed, trying thumbprint..." -ForegroundColor Gray
            $cleanThumbprint = $cert.Thumbprint.Trim().Replace(" ", "").ToUpper()

            $signOutput2 = & $signtool sign /v /s "My" /sha1 $cleanThumbprint /fd SHA256 "winApiRemoting.cat" 2>&1

            if ($LASTEXITCODE -eq 0) {
                Write-Host "[V] SUCCESS: Catalog signed with thumbprint!" -ForegroundColor Green
            } else {
                Write-Host "[!] Both signing methods failed" -ForegroundColor Red
                Write-Host "    Subject name error:" -ForegroundColor Gray
                $signOutput1 | ForEach-Object { Write-Host "        $_" -ForegroundColor Gray }
                Write-Host "    Thumbprint error:" -ForegroundColor Gray
                $signOutput2 | ForEach-Object { Write-Host "        $_" -ForegroundColor Gray }

                Write-Host ""
                Write-Host "Fallback: Use unsigned driver installation" -ForegroundColor Yellow
                Write-Host "    install_unsigned_driver.cmd" -ForegroundColor Gray
                exit 1
            }
        }
    } else {
        Write-Host "[!] No catalog file to sign" -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host " Success! Catalog is signed" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Files created:" -ForegroundColor White
    if (Test-Path "winApiRemoting.cat") {
        $catSize = (Get-Item "winApiRemoting.cat").Length
        Write-Host "[V] winApiRemoting.cat ($catSize bytes)" -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "Next step: Install the driver" -ForegroundColor White
    Write-Host "    install_driver.cmd" -ForegroundColor Gray
    Write-Host ""

} catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Fallback: Use unsigned driver installation" -ForegroundColor Yellow
    Write-Host "    install_unsigned_driver.cmd" -ForegroundColor Gray
    exit 1
}