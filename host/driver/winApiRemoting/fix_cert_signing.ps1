# Fix Certificate Signing Script
# Run as Administrator to fix the signtool certificate access issue

Write-Host "============================================" -ForegroundColor Green
Write-Host " Certificate Signing Fix Script" -ForegroundColor Green
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

    # Check available certificates
    Write-Host "[2/5] Listing available certificates..." -ForegroundColor Yellow
    $allCerts = Get-ChildItem "Cert:\LocalMachine\My"
    Write-Host "    Found $($allCerts.Count) certificates in LocalMachine\My:" -ForegroundColor Gray

    foreach ($cert in $allCerts) {
        $hasPrivateKey = if ($cert.HasPrivateKey) { "YES" } else { "NO" }
        Write-Host "    - Subject: $($cert.Subject)" -ForegroundColor Gray
        Write-Host "      Thumbprint: $($cert.Thumbprint)" -ForegroundColor Gray
        Write-Host "      Private Key: $hasPrivateKey" -ForegroundColor Gray
        Write-Host "      Valid: $($cert.NotBefore) to $($cert.NotAfter)" -ForegroundColor Gray
        Write-Host ""
    }

    # Find our certificate
    $cert = Get-ChildItem "Cert:\LocalMachine\My" | Where-Object {$_.Subject -like "*WinApiRemotingTestCert*"}
    if (-not $cert) {
        Write-Host "[!] WinApiRemotingTestCert not found" -ForegroundColor Red
        exit 1
    }
    Write-Host "[V] Target certificate found: $($cert.Subject)" -ForegroundColor Green
    Write-Host ""

    # Clean the thumbprint (remove any hidden characters)
    $cleanThumbprint = $cert.Thumbprint.Trim().Replace(" ", "").ToUpper()
    Write-Host "[3/5] Testing certificate access methods..." -ForegroundColor Yellow
    Write-Host "    Clean thumbprint: $cleanThumbprint" -ForegroundColor Gray

    # Method 1: Try by subject name
    Write-Host "    Method 1: Signing by subject name..." -ForegroundColor Gray
    $signOutput1 = & $signtool sign /v /s "My" /n "WinApiRemotingTestCert" /fd SHA256 "winApiRemoting.cat" 2>&1
    $exitCode1 = $LASTEXITCODE

    if ($exitCode1 -eq 0) {
        Write-Host "[V] SUCCESS: Signed using subject name!" -ForegroundColor Green
        Write-Host "    Verifying signature..." -ForegroundColor Gray
        $verifyOutput = & $signtool verify /pa /v "winApiRemoting.cat" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[V] Signature verification passed!" -ForegroundColor Green
        } else {
            Write-Host "[!] Signature verification failed" -ForegroundColor Yellow
        }
    } else {
        Write-Host "    Failed with subject name. Output:" -ForegroundColor Gray
        $signOutput1 | ForEach-Object { Write-Host "        $_" -ForegroundColor Gray }

        # Method 2: Try by thumbprint with CurrentUser store
        Write-Host "    Method 2: Trying CurrentUser store..." -ForegroundColor Gray

        # Copy certificate to CurrentUser\My if needed
        $userStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("My", "CurrentUser")
        $userStore.Open("ReadWrite")

        $userCerts = $userStore.Certificates | Where-Object {$_.Thumbprint -eq $cert.Thumbprint}
        if ($userCerts.Count -eq 0) {
            Write-Host "        Copying certificate to CurrentUser\My..." -ForegroundColor Gray
            $userStore.Add($cert)
        }
        $userStore.Close()

        $signOutput2 = & $signtool sign /v /s "My" /sha1 $cleanThumbprint /fd SHA256 "winApiRemoting.cat" 2>&1
        $exitCode2 = $LASTEXITCODE

        if ($exitCode2 -eq 0) {
            Write-Host "[V] SUCCESS: Signed using CurrentUser thumbprint!" -ForegroundColor Green
        } else {
            Write-Host "    Failed with CurrentUser thumbprint. Output:" -ForegroundColor Gray
            $signOutput2 | ForEach-Object { Write-Host "        $_" -ForegroundColor Gray }

            # Method 3: Create new certificate with proper code signing extension
            Write-Host "    Method 3: Creating new code signing certificate..." -ForegroundColor Gray

            # Remove old certificates first
            $oldCerts = Get-ChildItem "Cert:\LocalMachine\My" | Where-Object {$_.Subject -like "*WinApiRemotingTestCert*"}
            foreach ($oldCert in $oldCerts) {
                Write-Host "        Removing old certificate: $($oldCert.Thumbprint)" -ForegroundColor Gray
                Remove-Item "Cert:\LocalMachine\My\$($oldCert.Thumbprint)" -Force
            }

            # Create certificate with proper extensions for code signing
            Write-Host "[4/5] Creating new code signing certificate..." -ForegroundColor Yellow

            $newCert = New-SelfSignedCertificate `
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

            Write-Host "[V] New certificate created" -ForegroundColor Green
            Write-Host "    Subject: $($newCert.Subject)" -ForegroundColor Gray
            Write-Host "    Thumbprint: $($newCert.Thumbprint)" -ForegroundColor Gray

            # Install to trusted root
            $rootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
            $rootStore.Open("ReadWrite")
            $rootStore.Add($newCert)
            $rootStore.Close()

            Write-Host "[5/5] Signing with new certificate..." -ForegroundColor Yellow
            $cleanNewThumbprint = $newCert.Thumbprint.Trim().Replace(" ", "").ToUpper()

            # Try signing by subject name first
            $signOutput3 = & $signtool sign /v /s "My" /n "WinApiRemotingTestCert" /fd SHA256 "winApiRemoting.cat" 2>&1
            $exitCode3 = $LASTEXITCODE

            if ($exitCode3 -eq 0) {
                Write-Host "[V] SUCCESS: Signed with new certificate!" -ForegroundColor Green

                # Verify signature
                $verifyOutput = & $signtool verify /pa /v "winApiRemoting.cat" 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "[V] Signature verification passed!" -ForegroundColor Green
                } else {
                    Write-Host "[!] Signature verification failed" -ForegroundColor Yellow
                }
            } else {
                Write-Host "[!] Still failed with new certificate" -ForegroundColor Red
                Write-Host "    Output:" -ForegroundColor Gray
                $signOutput3 | ForEach-Object { Write-Host "        $_" -ForegroundColor Gray }

                # Last resort: try to export/import certificate
                Write-Host "    Last resort: Export and reimport certificate..." -ForegroundColor Yellow

                # Export certificate
                Export-Certificate -Cert $newCert -FilePath "temp_cert.cer" -Type CERT | Out-Null

                # Import it back (this sometimes fixes private key associations)
                Import-Certificate -FilePath "temp_cert.cer" -CertStoreLocation "Cert:\LocalMachine\TrustedPublisher" | Out-Null

                # Clean up
                Remove-Item "temp_cert.cer" -Force -ErrorAction SilentlyContinue

                Write-Host "[!] Manual intervention required. Try these commands:" -ForegroundColor Yellow
                Write-Host "    certlm.msc  (check certificate private key permissions)" -ForegroundColor Gray
                Write-Host "    or try unsigned installation: install_unsigned_driver.cmd" -ForegroundColor Gray
            }
        }
    }

    # Final status
    Write-Host ""
    if (Test-Path "winApiRemoting.cat") {
        $catInfo = Get-Item "winApiRemoting.cat"
        Write-Host "Catalog file: winApiRemoting.cat ($($catInfo.Length) bytes)" -ForegroundColor White

        # Test if it's signed
        $verifyResult = & $signtool verify /pa "winApiRemoting.cat" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[V] Catalog is properly signed!" -ForegroundColor Green
        } else {
            Write-Host "[!] Catalog exists but is not properly signed" -ForegroundColor Yellow
            Write-Host "    Consider using unsigned installation instead" -ForegroundColor Gray
        }
    }

} catch {
    Write-Host ""
    Write-Host "ERROR: Certificate fix failed" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Fallback option: Use unsigned driver installation" -ForegroundColor Yellow
    Write-Host "    install_unsigned_driver.cmd" -ForegroundColor Gray
    exit 1
}

Write-Host ""
Write-Host "Certificate fix complete!" -ForegroundColor Green