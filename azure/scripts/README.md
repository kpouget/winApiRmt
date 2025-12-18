# scripts/ Directory

This directory contains PowerShell scripts used for VM configuration and management.

## Files

### `setup-ssh-server.ps1`
Comprehensive PowerShell script that configures OpenSSH Server and WSL on Windows VMs.

**Purpose:**
- Installs OpenSSH Server Windows feature (using fast DISM method)
- Configures SSH server settings (password + key authentication)
- Sets up SSH directories and authorized_keys files with proper permissions
- Configures Windows Firewall rules for SSH
- Installs Windows Subsystem for Linux (WSL) with Fedora Linux 43 (optional)
- Configures PowerShell as default SSH shell

**Usage:**
```powershell
# Automatic (via Azure VM Custom Script Extension)
# Called automatically during VM creation with parameters from config.yaml

# Manual (if needed)
.\setup-ssh-server.ps1 -PublicKey "ssh-rsa AAAAB3..." -AdminUser "azureuser" -InstallWSL "true" -RebootAfterWSL "true"
```

**Parameters:**
- `PublicKey` - SSH public key to add to authorized_keys (default: "")
- `AdminUser` - Username to configure SSH for (default: "azureuser")
- `InstallWSL` - Whether to install WSL with Fedora Linux 43 (default: "false")
- `RebootAfterWSL` - Whether to reboot after WSL installation (default: "true")

**Note:** Boolean parameters accept string values ("true"/"false") for command-line compatibility.

## Organization

Scripts in this directory are:
- ✅ **Version controlled** (tracked in git)
- ✅ **Reusable** across different deployments
- ✅ **Referenced and used** by azure_vm_manager.py via Azure blob storage
- ✅ **Documented** with clear purpose and usage
- ✅ **Parameterized** to support different configurations