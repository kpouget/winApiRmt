# Windows SSH Server Setup Script with Key Authentication
# This script installs and configures OpenSSH Server on Windows

param(
    [string]$PublicKey = "",
    [string]$AdminUser = "azureuser",
    [string]$InstallWSL = "false",
    [string]$RebootAfterWSL = "true"
)

# Create temp directory and setup logging FIRST
$tempDir = "C:\temp"
$logFile = "$tempDir\ssh-setup.log"

try {
    if (!(Test-Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }
    "SSH setup script started at $(Get-Date)" | Out-File -FilePath $logFile -Force
    "Script execution from: $PSCommandPath" | Out-File -FilePath $logFile -Append
} catch {
    # If logging fails, continue anyway
    Write-Host "Warning: Could not setup logging at $logFile" -ForegroundColor Yellow
}

# Function to log both to console and file
function Write-LogHost {
    param(
        [string]$Message,
        [string]$ForegroundColor = "White"
    )
    Write-Host $Message -ForegroundColor $ForegroundColor
    try {
        $Message | Out-File -FilePath $logFile -Append -ErrorAction SilentlyContinue
    } catch {
        # Ignore logging errors
    }
}

# Convert string parameters to boolean values for internal use
$InstallWSLBool = $InstallWSL -eq "true" -or $InstallWSL -eq "\$true" -or $InstallWSL -eq "True"
$RebootAfterWSLBool = $RebootAfterWSL -eq "true" -or $RebootAfterWSL -eq "\$true" -or $RebootAfterWSL -eq "True"

Write-LogHost "Script parameters received:" -ForegroundColor Cyan
Write-LogHost "  PublicKey: $($PublicKey.Length) characters" -ForegroundColor Cyan
Write-LogHost "  AdminUser: $AdminUser" -ForegroundColor Cyan
Write-LogHost "  InstallWSL: '$InstallWSL' -> $InstallWSLBool" -ForegroundColor Cyan
Write-LogHost "  RebootAfterWSL: '$RebootAfterWSL' -> $RebootAfterWSLBool" -ForegroundColor Cyan

# Configure Windows for better automation
Write-Host "Configuring Windows for automation..." -ForegroundColor Green
try {
    # Set network location to private (more permissive for development)
    $networkProfiles = Get-NetConnectionProfile
    foreach ($profile in $networkProfiles) {
        if ($profile.NetworkCategory -ne "Private") {
            Set-NetConnectionProfile -InterfaceIndex $profile.InterfaceIndex -NetworkCategory Private
            Write-Host "Set network profile to Private for better connectivity" -ForegroundColor Green
        }
    }
} catch {
    Write-Host "Note: Could not set network profile (this is normal)" -ForegroundColor Yellow
}

Write-LogHost "Installing OpenSSH Server..." -ForegroundColor Green

# Install OpenSSH Server using MSI package (fastest method)
Write-LogHost "Downloading and installing OpenSSH MSI package..." -ForegroundColor Yellow
$msiSuccess = $false
try {
    curl.exe -LO https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.5.0.0p1-Beta/OpenSSH-Win64-v9.5.0.0.msi
    if ($LASTEXITCODE -eq 0) {
        Start-Process C:\Windows\System32\msiexec.exe -ArgumentList '/qb /i OpenSSH-Win64-v9.5.0.0.msi' -Wait
        if ($LASTEXITCODE -eq 0) {
            Write-LogHost "OpenSSH Server installed via MSI (fastest method)" -ForegroundColor Green
            $msiSuccess = $true
        }
    }
} catch {
    Write-LogHost "MSI installation failed: $_" -ForegroundColor Yellow
}

if (-not $msiSuccess) {
    # Fallback to DISM method
    Write-LogHost "Falling back to DISM method..." -ForegroundColor Yellow
    $dismResult = dism.exe /online /add-capability /capabilityname:OpenSSH.Server~~~~0.0.1.0 /NoRestart
    if ($LASTEXITCODE -ne 0) {
        Write-Host "DISM failed, falling back to Add-WindowsCapability..." -ForegroundColor Yellow
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
        Write-Host "OpenSSH Server installed via Windows capability" -ForegroundColor Green
    } else {
        Write-Host "OpenSSH Server installed via DISM" -ForegroundColor Green
    }
}

# Start SSH service
Start-Service sshd

# Set SSH service to start automatically
Set-Service -Name sshd -StartupType 'Automatic'

# Configure Windows Firewall rule for SSH
if (!(Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue | Select-Object Name, Enabled)) {
    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
    Write-Host "Created firewall rule for SSH" -ForegroundColor Green
} else {
    Write-Host "SSH firewall rule already exists" -ForegroundColor Yellow
}

# Configure SSH server settings
$sshdConfigPath = "C:\ProgramData\ssh\sshd_config"
if (Test-Path $sshdConfigPath) {
    Write-Host "Configuring SSH server..." -ForegroundColor Green

    # Enable both password and public key authentication
    (Get-Content $sshdConfigPath) -replace '#PasswordAuthentication yes', 'PasswordAuthentication yes' | Set-Content $sshdConfigPath
    (Get-Content $sshdConfigPath) -replace '#PubkeyAuthentication yes', 'PubkeyAuthentication yes' | Set-Content $sshdConfigPath

    # Enable authorized_keys file
    (Get-Content $sshdConfigPath) -replace '#AuthorizedKeysFile.*', 'AuthorizedKeysFile .ssh/authorized_keys' | Set-Content $sshdConfigPath
}

# Configure PowerShell as default SSH shell (instead of cmd.exe)
Write-Host "Configuring PowerShell as default SSH shell..." -ForegroundColor Green
try {
    New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force | Out-Null
    Write-Host "PowerShell set as default SSH shell" -ForegroundColor Green
} catch {
    Write-Host "Warning: Could not set PowerShell as default SSH shell" -ForegroundColor Yellow
}

# Set up SSH keys if public key is provided
if ($PublicKey -ne "") {
    Write-LogHost "Setting up SSH key authentication..." -ForegroundColor Green
    Write-LogHost "Public key length: $($PublicKey.Length) characters" -ForegroundColor Green

    # Verify user profile exists, create if needed
    $userProfile = "C:\Users\$AdminUser"
    Write-Host "Checking user profile: $userProfile" -ForegroundColor Yellow

    if (!(Test-Path $userProfile)) {
        Write-Host "User profile doesn't exist, attempting to create..." -ForegroundColor Yellow
        try {
            New-Item -ItemType Directory -Path $userProfile -Force | Out-Null
            Write-Host "Created user profile directory: $userProfile" -ForegroundColor Green
        } catch {
            Write-Host "Warning: Could not create user profile directory: $_" -ForegroundColor Yellow
            Write-Host "Continuing with SSH setup..." -ForegroundColor Yellow
        }
    } else {
        Write-Host "User profile exists: $userProfile" -ForegroundColor Green
    }

    # Create .ssh directory for the admin user
    $sshDir = "$userProfile\.ssh"
    Write-Host "Creating .ssh directory: $sshDir" -ForegroundColor Yellow

    try {
        if (!(Test-Path $sshDir)) {
            New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
            Write-LogHost "Created .ssh directory: $sshDir" -ForegroundColor Green
        } else {
            Write-LogHost ".ssh directory already exists: $sshDir" -ForegroundColor Green
        }

        # Create authorized_keys file
        $authorizedKeysFile = "$sshDir\authorized_keys"
        Write-LogHost "Creating authorized_keys file: $authorizedKeysFile" -ForegroundColor Yellow

        $PublicKey | Out-File -FilePath $authorizedKeysFile -Encoding ascii -Force

        if (Test-Path $authorizedKeysFile) {
            $fileSize = (Get-Item $authorizedKeysFile).Length
            Write-Host "✅ Created authorized_keys file: $authorizedKeysFile (size: $fileSize bytes)" -ForegroundColor Green

            # Verify file content
            $fileContent = Get-Content $authorizedKeysFile -Raw
            if ($fileContent -and $fileContent.Trim().Length -gt 0) {
                Write-Host "✅ Authorized_keys file has content" -ForegroundColor Green
            } else {
                Write-Host "⚠️ Warning: Authorized_keys file appears empty" -ForegroundColor Yellow
            }
        } else {
            Write-Host "❌ Failed to create authorized_keys file" -ForegroundColor Red
        }
    } catch {
        Write-Host "❌ Error creating authorized_keys: $_" -ForegroundColor Red
    }

    # Check if user is in Administrators group (Windows OpenSSH special case)
    $isAdmin = $false
    try {
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $adminGroup = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
        $isAdmin = $currentUser.Groups.Contains($adminGroup)

        # Also check if the specific admin user is in administrators group
        if (-not $isAdmin) {
            $userGroups = (Get-LocalUser $AdminUser | Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue)
            $isAdmin = $userGroups.Count -gt 0
        }
    } catch {
        # If we can't determine group membership, assume admin for safety
        $isAdmin = $true
    }

    # For admin users, Windows OpenSSH requires keys in administrators_authorized_keys
    Write-Host "Checking if user is administrator..." -ForegroundColor Yellow
    Write-Host "isAdmin result: $isAdmin" -ForegroundColor Yellow

    if ($isAdmin) {
        Write-Host "User $AdminUser is an administrator - setting up administrators_authorized_keys" -ForegroundColor Yellow
        $adminKeysFile = "C:\ProgramData\ssh\administrators_authorized_keys"

        # Ensure ProgramData\ssh directory exists
        $sshProgramDataDir = "C:\ProgramData\ssh"
        if (!(Test-Path $sshProgramDataDir)) {
            Write-Host "Creating ProgramData\ssh directory: $sshProgramDataDir" -ForegroundColor Yellow
            New-Item -ItemType Directory -Path $sshProgramDataDir -Force | Out-Null
        }

        # Create or append to administrators_authorized_keys file
        Write-Host "Creating administrators_authorized_keys: $adminKeysFile" -ForegroundColor Yellow
        try {
            $PublicKey | Out-File -FilePath $adminKeysFile -Encoding ascii -Force

            if (Test-Path $adminKeysFile) {
                $adminFileSize = (Get-Item $adminKeysFile).Length
                Write-Host "✅ Created administrators_authorized_keys: $adminKeysFile (size: $adminFileSize bytes)" -ForegroundColor Green

                # Verify file content
                $adminFileContent = Get-Content $adminKeysFile -Raw
                if ($adminFileContent -and $adminFileContent.Trim().Length -gt 0) {
                    Write-Host "✅ Administrators_authorized_keys file has content" -ForegroundColor Green
                } else {
                    Write-Host "⚠️ Warning: Administrators_authorized_keys file appears empty" -ForegroundColor Yellow
                }
            } else {
                Write-Host "❌ Failed to create administrators_authorized_keys file" -ForegroundColor Red
            }

            # Set proper permissions on administrators_authorized_keys (only SYSTEM and Administrators)
            Write-Host "Setting permissions on administrators_authorized_keys..." -ForegroundColor Yellow
            $icaclsResult = icacls $adminKeysFile /inheritance:r /grant "SYSTEM:F" /grant "Administrators:F" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✅ Set permissions on administrators_authorized_keys" -ForegroundColor Green
            } else {
                Write-Host "⚠️ Warning: Could not set permissions on administrators_authorized_keys" -ForegroundColor Yellow
                Write-Host "icacls output: $icaclsResult" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "❌ Error creating administrators_authorized_keys: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "User $AdminUser is not an administrator - using user authorized_keys only" -ForegroundColor Green
    }

    # Set proper permissions on SSH directory and files
    Write-Host "Setting permissions on .ssh directory and files..." -ForegroundColor Yellow

    try {
        # Set permissions on .ssh directory
        Write-Host "Setting permissions on .ssh directory: $sshDir" -ForegroundColor Yellow
        $acl = Get-Acl $sshDir
        $acl.SetAccessRuleProtection($true, $false)

        # Clear existing permissions
        $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) }

        # Add permissions for SYSTEM (Full Control)
        $systemSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
        $systemAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($systemSid, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.AddAccessRule($systemAccessRule)

        # Add permissions for Administrators (Full Control)
        $adminsSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
        $adminsAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($adminsSid, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.AddAccessRule($adminsAccessRule)

        # Add permissions for the specific admin user (Full Control)
        $userAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($AdminUser, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.AddAccessRule($userAccessRule)

        # Apply permissions to .ssh directory
        Set-Acl -Path $sshDir -AclObject $acl
        Write-Host "✅ Set permissions on .ssh directory" -ForegroundColor Green

        # Set specific permissions on authorized_keys file (more restrictive)
        if (Test-Path $authorizedKeysFile) {
            Write-Host "Setting permissions on authorized_keys file: $authorizedKeysFile" -ForegroundColor Yellow
            $fileAcl = Get-Acl $authorizedKeysFile
            $fileAcl.SetAccessRuleProtection($true, $false)

            # Clear existing permissions
            $fileAcl.Access | ForEach-Object { $fileAcl.RemoveAccessRule($_) }

            # Add permissions for SYSTEM (no inheritance flags for files)
            $systemFileAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($systemSid, "FullControl", "Allow")
            $fileAcl.AddAccessRule($systemFileAccessRule)

            # Add permissions for Administrators (no inheritance flags for files)
            $adminsFileAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($adminsSid, "FullControl", "Allow")
            $fileAcl.AddAccessRule($adminsFileAccessRule)

            # Add permissions for the specific admin user (Read/Write only)
            $userFileAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($AdminUser, "Read,Write", "Allow")
            $fileAcl.AddAccessRule($userFileAccessRule)

            # Apply permissions to authorized_keys file
            Set-Acl -Path $authorizedKeysFile -AclObject $fileAcl
            Write-Host "✅ Set permissions on authorized_keys file" -ForegroundColor Green
        } else {
            Write-Host "⚠️ Authorized_keys file not found, skipping file permissions" -ForegroundColor Yellow
        }

        Write-Host "✅ Completed SSH file permissions setup" -ForegroundColor Green
    } catch {
        Write-Host "⚠️ Warning: Could not set SSH file permissions: $_" -ForegroundColor Yellow
        Write-Host "SSH keys may still work with default permissions" -ForegroundColor Yellow
    }
}

# Restart SSH service to apply configuration changes
Restart-Service sshd
Write-Host "SSH server configured and restarted" -ForegroundColor Green

# Install WSL with Fedora Linux 43 if requested
if ($InstallWSLBool) {
    Write-Host "`n=== Installing WSL with Fedora Linux 43 ===" -ForegroundColor Yellow

    try {
        Write-Host "Installing WSL with Fedora Linux 43..." -ForegroundColor Green

        # This one command does everything: enables WSL, installs WSL2, and installs Fedora
        wsl.exe --install FedoraLinux-43

        Write-Host "✅ WSL installation initiated!" -ForegroundColor Green
        Write-Host "   Distribution: Fedora Linux 43" -ForegroundColor Cyan
        Write-Host "   Default user will be: $AdminUser (configured on first run)" -ForegroundColor Cyan
        Write-Host "   Access via: wsl -d FedoraLinux-43" -ForegroundColor Cyan
        Write-Host "⚠️  Note: VM restart may be required to complete WSL installation" -ForegroundColor Yellow

    } catch {
        Write-Host "⚠️  WSL installation failed: $_" -ForegroundColor Red
        Write-Host "   You can manually install with: wsl --install FedoraLinux-43" -ForegroundColor Yellow
    }

    Write-Host "=== WSL Installation Complete ===" -ForegroundColor Yellow

    # Schedule reboot if requested to complete WSL installation
    if ($RebootAfterWSLBool) {
        Write-Host "`n🔄 Scheduling system reboot to complete WSL installation..." -ForegroundColor Yellow
        Write-Host "   SSH server will be available after reboot" -ForegroundColor Cyan
        Write-Host "   WSL will be fully functional after reboot" -ForegroundColor Cyan

        # Create a flag file to indicate reboot was requested for WSL
        $rebootFlagFile = "C:\temp\wsl-reboot-requested.txt"
        New-Item -ItemType Directory -Path "C:\temp" -Force | Out-Null
        "WSL installation completed at $(Get-Date)" | Out-File -FilePath $rebootFlagFile -Encoding UTF8

        Write-Host "✅ Reboot will occur in 30 seconds..." -ForegroundColor Green

        # Schedule reboot in 30 seconds to allow script completion
        Start-Process -FilePath "shutdown.exe" -ArgumentList "/r", "/t", "30", "/c", "Reboot required to complete WSL installation" -NoNewWindow
    } else {
        Write-Host "`n⏭️  Automatic reboot disabled - manual restart recommended for full WSL functionality" -ForegroundColor Yellow
    }
} else {
    Write-Host "`n⏭️  WSL installation skipped (not requested)" -ForegroundColor Gray
}

# Display SSH service status
$sshStatus = Get-Service sshd
Write-Host "SSH Service Status: $($sshStatus.Status)" -ForegroundColor Cyan

# Display listening ports
$sshPort = Get-NetTCPConnection -LocalPort 22 -ErrorAction SilentlyContinue
if ($sshPort) {
    Write-Host "SSH is listening on port 22" -ForegroundColor Green
} else {
    Write-Host "Warning: SSH does not appear to be listening on port 22" -ForegroundColor Red
}

# Show authentication methods and SSH key file summary
Write-Host "SSH Authentication Methods:" -ForegroundColor Cyan
Write-Host "  - Password authentication: ENABLED" -ForegroundColor Green
if ($PublicKey -ne "") {
    Write-Host "  - Public key authentication: ENABLED" -ForegroundColor Green

    # Summary of created SSH key files
    Write-Host "`nSSH Key Files Created:" -ForegroundColor Cyan

    # Check user authorized_keys file
    $userAuthorizedKeys = "C:\Users\$AdminUser\.ssh\authorized_keys"
    if (Test-Path $userAuthorizedKeys) {
        $userKeySize = (Get-Item $userAuthorizedKeys).Length
        Write-Host "  User authorized_keys: $userAuthorizedKeys (size: $userKeySize bytes)" -ForegroundColor Green
    } else {
        Write-Host "  User authorized_keys: NOT FOUND at $userAuthorizedKeys" -ForegroundColor Red
    }

    # Check administrators_authorized_keys file
    $adminKeysFile = "C:\ProgramData\ssh\administrators_authorized_keys"
    if (Test-Path $adminKeysFile) {
        $adminKeySize = (Get-Item $adminKeysFile).Length
        Write-Host "  Admin authorized_keys: $adminKeysFile (size: $adminKeySize bytes)" -ForegroundColor Green
        Write-Host "  Note: Admin users will authenticate using administrators_authorized_keys" -ForegroundColor Cyan
    } else {
        Write-Host "  Admin authorized_keys: NOT FOUND at $adminKeysFile" -ForegroundColor Yellow
    }

    # Show which file will be used for authentication
    Write-Host "`nAuthentication Priority for ${AdminUser}:" -ForegroundColor Cyan
    if (Test-Path $adminKeysFile) {
        Write-Host "  Will use: administrators_authorized_keys (admin user)" -ForegroundColor Yellow
    } elseif (Test-Path $userAuthorizedKeys) {
        Write-Host "  Will use: user authorized_keys" -ForegroundColor Green
    } else {
        Write-Host "  ERROR: No authorized_keys files found!" -ForegroundColor Red
        Write-Host "  Will fall back to: Password authentication only" -ForegroundColor Yellow
    }
} else {
    Write-Host "  - Public key authentication: Available but no keys configured" -ForegroundColor Yellow
}

# Show shell configuration
Write-Host "SSH Shell Configuration:" -ForegroundColor Cyan
try {
    $defaultShell = Get-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -ErrorAction SilentlyContinue
    if ($defaultShell -and $defaultShell.DefaultShell) {
        Write-Host "  - Default SSH shell: PowerShell (ls and pwd commands available)" -ForegroundColor Green
    } else {
        Write-Host "  - Default SSH shell: Command Prompt (use dir instead of ls)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  - Default SSH shell: Command Prompt (use dir instead of ls)" -ForegroundColor Yellow
}

# Show WSL installation status
if ($InstallWSLBool) {
    Write-Host "WSL Configuration:" -ForegroundColor Cyan
    Write-Host "  - Distribution: Fedora Linux 43" -ForegroundColor Green
    Write-Host "  - Access command: wsl -d FedoraLinux-43" -ForegroundColor Green
    Write-Host "  - User setup: Will be configured on first WSL launch" -ForegroundColor Yellow

    if ($RebootAfterWSLBool) {
        Write-Host "  - Automatic reboot: ENABLED (reboot in 30 seconds)" -ForegroundColor Yellow
        Write-Host "  - WSL will be fully functional after reboot" -ForegroundColor Green
    } else {
        Write-Host "  - Automatic reboot: DISABLED" -ForegroundColor Yellow
        Write-Host "  - Manual restart recommended for full WSL functionality" -ForegroundColor Yellow
    }
} else {
    Write-Host "WSL Configuration:" -ForegroundColor Cyan
    Write-Host "  - WSL not installed (use -InstallWSL $true to enable)" -ForegroundColor Gray
}

Write-LogHost "SSH Server setup completed!" -ForegroundColor Green
Write-LogHost "Script finished at $(Get-Date)" -ForegroundColor Green

# Final log entry
try {
    "SSH setup script completed successfully at $(Get-Date)" | Out-File -FilePath $logFile -Append
    "Final status: SSH server configured and running" | Out-File -FilePath $logFile -Append
} catch {
    # Ignore logging errors
}

