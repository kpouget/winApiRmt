# scripts/ Directory

This directory contains PowerShell and other scripts used for VM configuration and management.

## Files

### `setup-ssh-server.ps1`
PowerShell script that configures OpenSSH Server on Windows VMs.

**Purpose:**
- Installs OpenSSH Server Windows feature (using fast DISM method)
- Configures SSH server settings (password + key authentication)
- Sets up SSH directories and authorized_keys file
- Applies proper Windows ACL permissions
- Configures Windows Firewall rules

**Usage:**
```powershell
# Automatic (via VM extension)
# Called automatically during VM creation

# Manual (if needed)
.\setup-ssh-server.ps1 -PublicKey "ssh-rsa AAAAB3..." -AdminUser "azureuser"
```

**Parameters:**
- `PublicKey` - SSH public key to add to authorized_keys
- `AdminUser` - Username to configure SSH for (default: azureuser)

## Organization

Scripts in this directory are:
- ✅ **Version controlled** (tracked in git)
- ✅ **Reusable** across different deployments
- ✅ **Referenced** by the main azure_vm_manager.py script
- ✅ **Documented** with clear purpose and usage