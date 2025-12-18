# Simplified SSH Server Setup Script for Azure VM Extension
# This script installs and configures OpenSSH Server with key authentication

param(
    [string]$PublicKey = "",
    [string]$AdminUser = "azureuser"
)

Write-Host 'Starting SSH Server setup...'

# Create temp directory
New-Item -ItemType Directory -Path 'C:\temp' -Force | Out-Null
Write-Host 'Created temp directory'

# Install OpenSSH Server using DISM (most reliable method)
Write-Host 'Installing OpenSSH Server...'
dism.exe /online /add-capability /capabilityname:OpenSSH.Server~~~~0.0.1.0 /NoRestart | Out-Host

# Start SSH service
Write-Host 'Starting SSH service...'
Start-Service sshd -ErrorAction SilentlyContinue
Set-Service -Name sshd -StartupType 'Automatic'

# Configure Windows Firewall for SSH
Write-Host 'Configuring firewall...'
if (!(Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
    Write-Host 'SSH firewall rule created'
} else {
    Write-Host 'SSH firewall rule already exists'
}

# Configure SSH server settings
Write-Host 'Configuring SSH server...'
$sshdConfig = 'C:\ProgramData\ssh\sshd_config'
if (Test-Path $sshdConfig) {
    (Get-Content $sshdConfig) -replace '#PasswordAuthentication yes', 'PasswordAuthentication yes' | Set-Content $sshdConfig
    (Get-Content $sshdConfig) -replace '#PubkeyAuthentication yes', 'PubkeyAuthentication yes' | Set-Content $sshdConfig
    (Get-Content $sshdConfig) -replace '#AuthorizedKeysFile.*', 'AuthorizedKeysFile .ssh/authorized_keys' | Set-Content $sshdConfig
    Write-Host 'SSH server configured for password and key auth'
}

# Set PowerShell as default SSH shell
Write-Host 'Setting PowerShell as default SSH shell...'
try {
    New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null
    Write-Host 'PowerShell set as default SSH shell'
} catch {
    Write-Host 'Warning: Could not set PowerShell as default shell'
}

# Setup SSH key authentication if public key provided
if ($PublicKey -ne "") {
    Write-Host 'Setting up SSH key authentication...'
    $userProfile = "C:\Users\$AdminUser"
    $sshDir = "$userProfile\.ssh"
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    Write-Host 'Created .ssh directory'

    # Create user authorized_keys file
    $authorizedKeysFile = "$sshDir\authorized_keys"
    $PublicKey | Out-File -FilePath $authorizedKeysFile -Encoding ascii
    Write-Host 'Created user authorized_keys file'

    # For admin users, also create administrators_authorized_keys
    Write-Host 'Setting up admin authorized keys...'
    $adminKeysFile = 'C:\ProgramData\ssh\administrators_authorized_keys'
    $PublicKey | Out-File -FilePath $adminKeysFile -Encoding ascii

    # Set proper permissions on administrators_authorized_keys
    icacls $adminKeysFile /inheritance:r /grant 'SYSTEM:F' /grant 'Administrators:F' | Out-Null
    Write-Host 'Set permissions on admin authorized keys'
}

# Restart SSH service to apply all changes
Write-Host 'Restarting SSH service...'
Restart-Service sshd
Write-Host 'SSH server restarted successfully'

# Verify SSH is running
$sshStatus = Get-Service sshd
Write-Host "SSH Service Status: $($sshStatus.Status)"

Write-Host 'SSH Server setup completed successfully!'
Write-Host 'Authentication methods: Password + Public Key'
Write-Host 'Default shell: PowerShell'