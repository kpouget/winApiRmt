# SSH Key Authentication for Azure Windows VMs

This Azure VM manager automatically generates SSH key pairs and configures Windows VMs for both password and key-based SSH authentication.

## How It Works

### Automatic SSH Key Generation
- When creating a VM, if no SSH keys exist, a new RSA 4096-bit key pair is generated
- Private key: `{project-name}-ssh-key`
- Public key: `{project-name}-ssh-key.pub`
- Keys are excluded from git via .gitignore for security

### Windows SSH Server Configuration
The VM automatically:
- Installs OpenSSH Server Windows feature (using fast DISM method)
- Enables both password and public key authentication
- Creates proper `.ssh` directory structure
- Deploys public key to `authorized_keys` file
- Sets correct Windows ACL permissions on SSH files
- Configures Windows Firewall for SSH access
- Sets network profile to Private for better connectivity

**Performance Note:** Uses DISM instead of Add-WindowsCapability for much faster installation (seconds vs minutes).

## SSH Connection Methods

### 1. Using SSH Key (Recommended)
```bash
ssh -i {project-name}-ssh-key {username}@{vm-ip}
```

### 2. Using Password
```bash
ssh {username}@{vm-ip}
# Enter password when prompted
```

### 3. Using RDP (Alternative)
```bash
mstsc /v:{vm-ip}
```

## SSH File Permissions

The setup script creates proper Windows ACL permissions:

**`.ssh` Directory:**
- SYSTEM: Full Control
- Administrators: Full Control
- Admin User: Full Control
- Inheritance: Disabled

**`authorized_keys` File:**
- SYSTEM: Full Control
- Administrators: Full Control
- Admin User: Read/Write
- Inheritance: Disabled

## Troubleshooting SSH

### Check SSH Service Status
```powershell
Get-Service sshd
Get-NetTCPConnection -LocalPort 22
```

### Verify SSH Configuration
```powershell
Get-Content C:\ProgramData\ssh\sshd_config | Select-String -Pattern "PasswordAuthentication|PubkeyAuthentication|AuthorizedKeysFile"
```

### Check SSH Directory Permissions
```powershell
Get-Acl C:\Users\{username}\.ssh
Get-Acl C:\Users\{username}\.ssh\authorized_keys
```

### Manual SSH Server Setup
If automatic setup fails, run the PowerShell script manually:
```powershell
.\scripts\setup-ssh-server.ps1 -PublicKey "ssh-rsa AAAAB3..." -AdminUser "azureuser"
```

## Security Notes

- SSH keys are generated locally and private keys never leave your machine
- Public keys are deployed securely via Azure VM extensions
- Both password and key authentication are enabled for flexibility
- Private keys have 600 permissions (read/write for owner only)
- Windows ACLs prevent unauthorized access to SSH files

## Key Management

### Regenerating Keys
Delete the existing private key file and create a new VM:
```bash
rm {project-name}-ssh-key {project-name}-ssh-key.pub
python azure_vm_manager.py create
```

### Using Existing Keys
If you have existing SSH keys, replace the generated files:
```bash
cp ~/.ssh/id_rsa {project-name}-ssh-key
cp ~/.ssh/id_rsa.pub {project-name}-ssh-key.pub
```

### Multiple VMs
Each project generates its own key pair. To use the same key across projects:
```bash
cp project1-ssh-key project2-ssh-key
cp project1-ssh-key.pub project2-ssh-key.pub
```

## Connection Examples

```bash
# Connect with key
ssh -i kpouget-windows-desktop-test-ssh-key azureuser@20.1.2.3

# Connect with password
ssh azureuser@20.1.2.3

# Copy files to VM
scp -i kpouget-windows-desktop-test-ssh-key file.txt azureuser@20.1.2.3:C:/

# Run remote command
ssh -i kpouget-windows-desktop-test-ssh-key azureuser@20.1.2.3 "powershell Get-ComputerInfo"
```