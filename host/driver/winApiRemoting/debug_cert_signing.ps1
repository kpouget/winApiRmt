# Debug Certificate Signing Script
# Run as Administrator to diagnose signing issues

Write-Host "============================================" -ForegroundColor Green
Write-Host " Certificate Signing Debug Script" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator" -ForegroundColor Red
    exit 1
}

try {
    # Check for existing certificate
    Write-Host "[1/6] Checking for existing certificates..." -ForegroundColor Yellow
    $certs = Get-ChildItem "Cert:\LocalMachine\My" | Where-Object {$_.Subject -like "*WinApiRemotingTestCert*"}

    if ($certs.Count -eq 0) {
        Write-Host "[!] No WinApiRemotingTestCert found. Running certificate creation..." -ForegroundColor Yellow

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

        Write-Host "[V] New certificate created" -ForegroundColor Green
    } else {
        $cert = $certs[0]
        Write-Host "[V] Using existing certificate" -ForegroundColor Green
    }

    Write-Host "    Subject: $($cert.Subject)" -ForegroundColor Gray
    Write-Host "    Thumbprint: $($cert.Thumbprint)" -ForegroundColor Gray
    Write-Host "    Has Private Key: $($cert.HasPrivateKey)" -ForegroundColor Gray
    Write-Host ""

    # Install to Trusted Root if not already there
    Write-Host "[2/6] Checking Trusted Root store..." -ForegroundColor Yellow
    $rootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
    $rootStore.Open("ReadWrite")

    $rootCerts = $rootStore.Certificates | Where-Object {$_.Thumbprint -eq $cert.Thumbprint}
    if ($rootCerts.Count -eq 0) {
        $rootStore.Add($cert)
        Write-Host "[V] Certificate added to Trusted Root" -ForegroundColor Green
    } else {
        Write-Host "[V] Certificate already in Trusted Root" -ForegroundColor Green
    }
    $rootStore.Close()
    Write-Host ""

    # Find signtool
    Write-Host "[3/6] Finding signtool..." -ForegroundColor Yellow
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

    Write-Host "[V] signtool found: $signtool" -ForegroundColor Green
    Write-Host ""

    # Test certificate access
    Write-Host "[4/6] Testing certificate access..." -ForegroundColor Yellow
    $testResult = & $signtool sign /? 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[!] signtool basic test failed" -ForegroundColor Red
        Write-Host "Error: $testResult"
    } else {
        Write-Host "[V] signtool accessible" -ForegroundColor Green
    }

    # List certificates in My store for debugging
    Write-Host "    Certificates in My store:" -ForegroundColor Gray
    & $signtool sign /s "My" /sha1 "0000000000000000000000000000000000000000" "nonexistent.file" 2>&1 | Out-Null
    Write-Host ""

    # Check if catalog file exists
    Write-Host "[5/6] Checking catalog file..." -ForegroundColor Yellow
    if (-not (Test-Path "winApiRemoting.cat")) {
        Write-Host "[!] winApiRemoting.cat not found. Creating..." -ForegroundColor Yellow

        # Find inf2cat and create catalog
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
            # Enable CatalogFile in INF
            if (Test-Path "winApiRemoting_minimal.inf") {
                $infContent = Get-Content "winApiRemoting_minimal.inf"
                $infContent = $infContent -replace "; CatalogFile = winApiRemoting.cat.*", "CatalogFile = winApiRemoting.cat"
                Set-Content "winApiRemoting_minimal.inf" $infContent
            }

            Write-Host "    Creating catalog with inf2cat..." -ForegroundColor Gray
            & $inf2cat /driver:. /os:10_X64

            if (Test-Path "winApiRemoting.cat") {
                Write-Host "[V] Catalog created" -ForegroundColor Green
            } else {
                Write-Host "[!] Catalog creation failed" -ForegroundColor Red
                exit 1
            }
        } else {
            Write-Host "[!] inf2cat not found" -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "[V] Catalog file exists" -ForegroundColor Green
    }
    Write-Host ""

    # Try signing with detailed error output
    Write-Host "[6/6] Signing catalog file..." -ForegroundColor Yellow
    Write-Host "    Command: $signtool sign /v /s `"My`" /sha1 $($cert.Thumbprint) /fd SHA256 `"winApiRemoting.cat`"" -ForegroundColor Gray

    # Run signtool with full error output
    $signOutput = & $signtool sign /v /s "My" /sha1 $cert.Thumbprint /fd SHA256 "winApiRemoting.cat" 2>&1
    $signExitCode = $LASTEXITCODE

    Write-Host "    Output:" -ForegroundColor Gray
    $signOutput | ForEach-Object { Write-Host "        $_" -ForegroundColor Gray }
    Write-Host "    Exit code: $signExitCode" -ForegroundColor Gray

    if ($signExitCode -eq 0) {
        Write-Host "[V] Catalog file signed successfully!" -ForegroundColor Green

        # Verify the signature
        Write-Host "    Verifying signature..." -ForegroundColor Gray
        $verifyOutput = & $signtool verify /pa /v "winApiRemoting.cat" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[V] Signature verification passed" -ForegroundColor Green
        } else {
            Write-Host "[!] Signature verification failed" -ForegroundColor Yellow
            $verifyOutput | ForEach-Object { Write-Host "        $_" -ForegroundColor Gray }
        }
    } else {
        Write-Host "[!] Catalog signing failed" -ForegroundColor Red
        Write-Host ""
        Write-Host "Common solutions:" -ForegroundColor Yellow
        Write-Host "1. Ensure certificate has private key" -ForegroundColor Gray
        Write-Host "2. Check certificate is in LocalMachine\My store" -ForegroundColor Gray
        Write-Host "3. Verify certificate thumbprint is correct" -ForegroundColor Gray
        Write-Host "4. Try running as Administrator" -ForegroundColor Gray
        Write-Host "5. Check Windows SDK version compatibility" -ForegroundColor Gray
    }

} catch {
    Write-Host ""
    Write-Host "ERROR: Debug script failed" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Debug complete." -ForegroundColor White