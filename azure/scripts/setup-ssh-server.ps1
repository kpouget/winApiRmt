# Windows SSH Server Setup Script with Key Authentication
# This script installs and configures OpenSSH Server on Windows

param(
    [string]$PublicKey = "",
    [string]$AdminUser = "azureuser",
    [bool]$InstallWSL = $false,
    [bool]$RebootAfterWSL = $true
)

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

Write-Host "Installing OpenSSH Server..." -ForegroundColor Green

# Install OpenSSH Server feature (faster method)
Write-Host "Trying DISM method first (faster)..." -ForegroundColor Yellow
$dismResult = dism.exe /online /add-capability /capabilityname:OpenSSH.Server~~~~0.0.1.0 /NoRestart
if ($LASTEXITCODE -ne 0) {
    Write-Host "DISM failed, falling back to Add-WindowsCapability..." -ForegroundColor Yellow
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
} else {
    Write-Host "OpenSSH Server installed via DISM (faster method)" -ForegroundColor Green
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
    Write-Host "✅ PowerShell set as default SSH shell" -ForegroundColor Green
} catch {
    Write-Host "Warning: Could not set PowerShell as default SSH shell" -ForegroundColor Yellow
}

# Set up SSH keys if public key is provided
if ($PublicKey -ne "") {
    Write-Host "Setting up SSH key authentication..." -ForegroundColor Green

    # Create .ssh directory for the admin user
    $userProfile = "C:\Users\$AdminUser"
    $sshDir = "$userProfile\.ssh"

    if (!(Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
        Write-Host "Created .ssh directory: $sshDir" -ForegroundColor Green
    }

    # Create authorized_keys file
    $authorizedKeysFile = "$sshDir\authorized_keys"
    $PublicKey | Out-File -FilePath $authorizedKeysFile -Encoding ascii
    Write-Host "Created authorized_keys file: $authorizedKeysFile" -ForegroundColor Green

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
    if ($isAdmin) {
        Write-Host "User $AdminUser is an administrator - setting up administrators_authorized_keys" -ForegroundColor Yellow
        $adminKeysFile = "C:\ProgramData\ssh\administrators_authorized_keys"

        # Create or append to administrators_authorized_keys file
        $PublicKey | Out-File -FilePath $adminKeysFile -Encoding ascii
        Write-Host "Added key to administrators_authorized_keys: $adminKeysFile" -ForegroundColor Green

        # Set proper permissions on administrators_authorized_keys (only SYSTEM and Administrators)
        try {
            icacls $adminKeysFile /inheritance:r /grant "SYSTEM:F" /grant "Administrators:F" | Out-Null
            Write-Host "Set permissions on administrators_authorized_keys" -ForegroundColor Green
        } catch {
            Write-Host "Warning: Could not set permissions on administrators_authorized_keys" -ForegroundColor Yellow
        }
    }

    # Set proper permissions on SSH directory and files
    # Remove inheritance and set explicit permissions
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

    # Set specific permissions on authorized_keys file (more restrictive)
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

    Write-Host "Set proper ACL permissions on SSH files" -ForegroundColor Green
}

# Restart SSH service to apply configuration changes
Restart-Service sshd
Write-Host "SSH server configured and restarted" -ForegroundColor Green

# Install WSL with Fedora Linux 43 if requested
if ($InstallWSL) {
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
    if ($RebootAfterWSL) {
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

# Show authentication methods
Write-Host "SSH Authentication Methods:" -ForegroundColor Cyan
Write-Host "  - Password authentication: ENABLED" -ForegroundColor Green
if ($PublicKey -ne "") {
    Write-Host "  - Public key authentication: ENABLED" -ForegroundColor Green
    Write-Host "  - User authorized keys file: $authorizedKeysFile" -ForegroundColor Green

    # Show administrators_authorized_keys info if it was created
    $adminKeysFile = "C:\ProgramData\ssh\administrators_authorized_keys"
    if (Test-Path $adminKeysFile) {
        Write-Host "  - Admin authorized keys file: $adminKeysFile (ACTIVE for admin users)" -ForegroundColor Yellow
        Write-Host "  - Note: Admin users will authenticate using administrators_authorized_keys" -ForegroundColor Cyan
    }
} else {
    Write-Host "  - Public key authentication: Available but no keys configured" -ForegroundColor Yellow
}

# Show shell configuration
Write-Host "SSH Shell Configuration:" -ForegroundColor Cyan
try {
    $defaultShell = Get-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -ErrorAction SilentlyContinue
    if ($defaultShell -and $defaultShell.DefaultShell) {
        Write-Host "  - Default SSH shell: PowerShell (ls, pwd, etc. commands available)" -ForegroundColor Green
    } else {
        Write-Host "  - Default SSH shell: Command Prompt (use dir instead of ls)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  - Default SSH shell: Command Prompt (use dir instead of ls)" -ForegroundColor Yellow
}

# Show WSL installation status
if ($InstallWSL) {
    Write-Host "WSL Configuration:" -ForegroundColor Cyan
    Write-Host "  - Distribution: Fedora Linux 43" -ForegroundColor Green
    Write-Host "  - Access command: wsl -d FedoraLinux-43" -ForegroundColor Green
    Write-Host "  - User setup: Will be configured on first WSL launch" -ForegroundColor Yellow

    if ($RebootAfterWSL) {
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

Write-Host "SSH Server setup completed!" -ForegroundColor Green

