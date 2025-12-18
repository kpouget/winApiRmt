#!/usr/bin/env python3
"""
Azure Windows 11 VM Manager with Persistent Disk Support

This script manages Azure VMs for the Windows API Remoting Framework testing.
Features:
- Create VM with specific Windows 11 configuration
- Destroy VM while preserving disk
- Recreate VM using existing disk
- Complete resource cleanup

Requirements:
- Azure CLI installed and authenticated
- Python packages: azure-mgmt-compute, azure-mgmt-resource, azure-mgmt-network
"""

import json
import os
import sys
import time
import logging
import argparse
import yaml
import subprocess
import base64
from datetime import datetime
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass, asdict
from dotenv import load_dotenv

# Azure SDK imports
try:
    from azure.identity import DefaultAzureCredential
    from azure.mgmt.compute import ComputeManagementClient
    from azure.mgmt.resource import ResourceManagementClient
    from azure.mgmt.network import NetworkManagementClient
    from azure.mgmt.storage import StorageManagementClient
    from azure.storage.blob import BlobServiceClient
    from azure.mgmt.compute.models import (
        VirtualMachine, HardwareProfile, StorageProfile, OSDisk,
        NetworkProfile, OSProfile, WindowsConfiguration, NetworkInterfaceReference,
        DiskCreateOption, CachingTypes, StorageAccountTypes,
        VirtualMachineScaleSetVMInstanceView, VirtualMachineSizeTypes
    )
    from azure.mgmt.network.models import (
        NetworkInterface, NetworkInterfaceIPConfiguration,
        PublicIPAddress, NetworkSecurityGroup, SecurityRule,
        VirtualNetwork, Subnet
    )
    from azure.mgmt.storage.models import (
        StorageAccount, StorageAccountCreateParameters, Sku, SkuName, Kind
    )
except ImportError as e:
    print(f"Error: Missing required Azure SDK packages. Install with:")
    print("pip install azure-mgmt-compute azure-mgmt-resource azure-mgmt-network azure-mgmt-storage azure-storage-blob azure-identity python-dotenv pyyaml")
    sys.exit(1)


def load_secrets() -> Dict[str, str]:
    """Load secrets from .env.secret file"""
    secret_file = '.env.secret'
    if os.path.exists(secret_file):
        load_dotenv(secret_file)
        return {
            'admin_username': os.getenv('ADMIN_USERNAME', 'azureuser'),
            'admin_password': os.getenv('ADMIN_PASSWORD', 'TestPass123!')
        }
    else:
        print(f"Warning: {secret_file} not found. Using default credentials.")
        return {
            'admin_username': 'azureuser',
            'admin_password': 'TestPass123!'
        }


def load_config() -> Dict:
    """Load configuration from config.yaml file"""
    config_file = 'config.yaml'
    if os.path.exists(config_file):
        with open(config_file, 'r') as f:
            return yaml.safe_load(f)
    else:
        print(f"Warning: {config_file} not found. Using default configuration.")
        return {}


@dataclass
class VMConfig:
    """VM Configuration Parameters"""
    project_name: str = None
    nested_virt: bool = None
    cpus: int = None
    windows_version: str = None
    windows_featurepack: str = None
    tags: Dict[str, str] = None
    spot: bool = None
    location: str = None
    vm_size: str = None
    admin_username: str = None
    admin_password: str = None
    install_wsl: bool = None
    reboot_after_wsl: bool = None

    def __post_init__(self):
        # Load configuration from files
        config_data = load_config()
        secrets_data = load_secrets()

        # Apply configuration values with fallbacks
        self.project_name = self.project_name or config_data.get('project_name', 'kpouget-windows-desktop-test')
        self.nested_virt = self.nested_virt if self.nested_virt is not None else config_data.get('nested_virt', True)
        self.cpus = self.cpus or config_data.get('cpus', 8)
        self.windows_version = self.windows_version or config_data.get('windows_version', '11')
        self.windows_featurepack = self.windows_featurepack or config_data.get('windows_featurepack', '25h2-ent')
        self.spot = self.spot if self.spot is not None else config_data.get('spot', True)
        self.location = self.location or config_data.get('location', 'eastus')
        self.vm_size = self.vm_size or config_data.get('vm_size', 'Standard_D8s_v3')

        # Load credentials from secrets
        self.admin_username = self.admin_username or secrets_data['admin_username']
        self.admin_password = self.admin_password or secrets_data['admin_password']

        # WSL configuration
        self.install_wsl = self.install_wsl if self.install_wsl is not None else config_data.get('install_wsl', False)
        self.reboot_after_wsl = self.reboot_after_wsl if self.reboot_after_wsl is not None else config_data.get('reboot_after_wsl', True)

        # Handle tags
        if self.tags is None:
            self.tags = config_data.get('tags', {
                'project': 'api-remoting',
                'user': 'kpouget',
                'org': 'crc',
                'run': 'dev'
            })


@dataclass
class VMState:
    """VM State tracking"""
    vm_name: str
    resource_group: str
    disk_name: str
    disk_resource_id: str
    network_interface_id: str
    public_ip_id: str
    created_at: str
    vm_resource_id: Optional[str] = None
    vm_exists: bool = False


class AzureVMManager:
    """Azure VM Manager with persistent disk support"""

    def __init__(self, subscription_id: str, config: VMConfig):
        self.subscription_id = subscription_id
        self.config = config
        self.credential = DefaultAzureCredential()

        # Initialize Azure clients
        self.compute_client = ComputeManagementClient(
            self.credential, subscription_id
        )
        self.resource_client = ResourceManagementClient(
            self.credential, subscription_id
        )
        self.network_client = NetworkManagementClient(
            self.credential, subscription_id
        )
        self.storage_client = StorageManagementClient(
            self.credential, subscription_id
        )

        # Ensure var directories exist
        self._ensure_var_directories()

        # State file for persistence (in var/state/)
        self.state_file = f"var/state/{config.project_name}_state.json"
        self.state = self._load_state()

        # Setup logging
        self._setup_logging()

    def _ensure_var_directories(self):
        """Create var and generated directories if they don't exist"""
        var_dirs = ['var', 'var/logs', 'var/state', 'generated']
        for var_dir in var_dirs:
            if not os.path.exists(var_dir):
                os.makedirs(var_dir, exist_ok=True)

    def _setup_logging(self):
        """Setup logging configuration"""
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler(f"var/logs/{self.config.project_name}.log"),
                logging.StreamHandler(sys.stdout)
            ]
        )

        # Reduce Azure SDK logging verbosity
        logging.getLogger('azure').setLevel(logging.WARNING)
        logging.getLogger('azure.core.pipeline.policies.http_logging_policy').setLevel(logging.WARNING)
        logging.getLogger('azure.mgmt').setLevel(logging.WARNING)
        logging.getLogger('azure.identity').setLevel(logging.WARNING)
        logging.getLogger('urllib3').setLevel(logging.WARNING)

        self.logger = logging.getLogger(__name__)

    def _load_state(self) -> Optional[VMState]:
        """Load VM state from file"""
        if os.path.exists(self.state_file):
            try:
                with open(self.state_file, 'r') as f:
                    data = json.load(f)
                    return VMState(**data)
            except (json.JSONDecodeError, TypeError) as e:
                self.logger.warning(f"Could not load state file: {e}")
        return None

    def _save_state(self, state: VMState):
        """Save VM state to file"""
        try:
            with open(self.state_file, 'w') as f:
                json.dump(asdict(state), f, indent=2)
            self.state = state
        except Exception as e:
            self.logger.error(f"Could not save state: {e}")

    def _get_resource_names(self) -> Dict[str, str]:
        """Generate resource names based on project name"""
        base_name = self.config.project_name.replace('_', '-')
        return {
            'resource_group': f"{base_name}-rg",
            'vm_name': f"{base_name}-vm",
            'disk_name': f"{base_name}-disk",
            'nic_name': f"{base_name}-nic",
            'pip_name': f"{base_name}-pip",
            'nsg_name': f"{base_name}-nsg",
            'vnet_name': f"{base_name}-vnet",
            'subnet_name': 'default'
        }

    def _get_windows_image_reference(self):
        """Get the appropriate Windows 11 image reference"""
        # Windows 11 Enterprise 25H2 image
        return {
            'publisher': 'MicrosoftWindowsDesktop',
            'offer': 'Windows-11',
            'sku': 'win11-25h2-ent',
            'version': 'latest'
        }

    def validate_configuration(self) -> bool:
        """Simple validation of configuration before creating resources"""
        self.logger.info("🔍 Validating configuration...")

        # Check required files exist
        if not os.path.exists('.env.secret'):
            self.logger.warning("⚠️  .env.secret not found, using default credentials")

        if not os.path.exists('config.yaml'):
            self.logger.warning("⚠️  config.yaml not found, using default configuration")

        # Basic Azure connectivity test
        try:
            # Test credential and subscription access by listing resource groups
            list(self.resource_client.resource_groups.list())
            self.logger.info("✅ Azure connectivity validated")
        except Exception as e:
            self.logger.error(f"❌ Azure connectivity failed: {e}")
            return False

        # Check basic configuration
        if not self.config.admin_username or not self.config.admin_password:
            self.logger.error("❌ Missing admin credentials")
            return False

        if len(self.config.project_name) == 0:
            self.logger.error("❌ Project name cannot be empty")
            return False

        self.logger.info("✅ Configuration validation passed")
        return True

    def _format_duration(self, seconds: float) -> str:
        """Format duration in a human-readable way"""
        if seconds < 60:
            return f"{seconds:.1f} seconds"
        elif seconds < 3600:
            minutes = seconds / 60
            return f"{minutes:.1f} minutes ({seconds:.1f} seconds)"
        else:
            hours = seconds / 3600
            minutes = (seconds % 3600) / 60
            return f"{hours:.1f} hours, {minutes:.1f} minutes ({seconds:.1f} seconds)"

    def _log_operation_start(self, operation: str) -> float:
        """Log operation start and return start time"""
        start_time = time.time()
        self.logger.info(f"🚀 Starting {operation} at {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        return start_time

    def _log_operation_end(self, operation: str, start_time: float):
        """Log operation completion with duration"""
        end_time = time.time()
        duration = end_time - start_time
        formatted_duration = self._format_duration(duration)
        self.logger.info(f"✅ {operation} completed in {formatted_duration}")

    def _generate_ssh_keys(self) -> Tuple[str, str]:
        """Generate SSH key pair if private key doesn't exist"""
        private_key_path = f"{self.config.project_name}-ssh-key"
        public_key_path = f"{private_key_path}.pub"

        if os.path.exists(private_key_path):
            self.logger.info(f"Using existing SSH key: {private_key_path}")
            with open(public_key_path, 'r') as f:
                public_key = f.read().strip()
            return private_key_path, public_key

        self.logger.info("🔑 Generating new SSH key pair...")
        try:
            # Generate SSH key pair
            subprocess.run([
                'ssh-keygen', '-t', 'rsa', '-b', '4096',
                '-C', f'{self.config.admin_username}@{self.config.project_name}',
                '-f', private_key_path,
                '-N', ''  # No passphrase
            ], check=True, capture_output=True)

            # Set proper permissions on private key
            os.chmod(private_key_path, 0o600)

            # Read public key
            with open(public_key_path, 'r') as f:
                public_key = f.read().strip()

            self.logger.info(f"✅ SSH key pair generated: {private_key_path}")
            return private_key_path, public_key

        except subprocess.CalledProcessError as e:
            self.logger.error(f"Failed to generate SSH keys: {e}")
            raise
        except Exception as e:
            self.logger.error(f"SSH key generation error: {e}")
            raise

    def _install_ssh_server(self, rg_name: str, vm_name: str):
        """Install and configure SSH server on the VM using blob storage approach"""
        try:
            # Generate SSH keys
            private_key_path, public_key = self._generate_ssh_keys()

            # Read the external PowerShell script template
            script_path = os.path.join(os.path.dirname(__file__), 'scripts', 'setup-ssh-simple.ps1')
            with open(script_path, 'r') as f:
                script_template = f.read()

            # Create a parameterized PowerShell script
            # Using the blob storage approach like the working Go example
            script_content = f"""# SSH Server Setup Script for Azure VM
# Auto-generated by Azure VM Manager

param(
    [string]$PublicKey = "{public_key}",
    [string]$AdminUser = "{self.config.admin_username}"
)

# Create temp directory and logging
New-Item -ItemType Directory -Path 'C:\\temp' -Force | Out-Null
$logFile = 'C:\\temp\\ssh-setup.log'
'SSH setup started at ' + (Get-Date) | Out-File $logFile

try {{
    # Install OpenSSH Server
    'Installing OpenSSH Server...' | Tee-Object $logFile -Append | Write-Host
    dism.exe /online /add-capability /capabilityname:OpenSSH.Server~~~~0.0.1.0 /NoRestart | Out-File $logFile -Append

    # Start SSH service
    'Starting SSH service...' | Tee-Object $logFile -Append | Write-Host
    Start-Service sshd -ErrorAction SilentlyContinue
    Set-Service -Name sshd -StartupType 'Automatic'

    # Configure firewall (remove any existing rule first, then create properly)
    'Configuring firewall...' | Tee-Object $logFile -Append | Write-Host
    Remove-NetFirewallRule -DisplayName 'OpenSSH Server' -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName 'OpenSSH Server' -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow

    # Configure SSH server for both password and key auth
    'Configuring SSH server...' | Tee-Object $logFile -Append | Write-Host
    $sshdConfig = 'C:\\ProgramData\\ssh\\sshd_config'
    if (Test-Path $sshdConfig) {{
        (Get-Content $sshdConfig) -replace '#PasswordAuthentication yes', 'PasswordAuthentication yes' | Set-Content $sshdConfig
        (Get-Content $sshdConfig) -replace '#PubkeyAuthentication yes', 'PubkeyAuthentication yes' | Set-Content $sshdConfig
    }}

    # Set PowerShell as default SSH shell
    'Setting PowerShell as default shell...' | Tee-Object $logFile -Append | Write-Host
    New-ItemProperty -Path 'HKLM:\\SOFTWARE\\OpenSSH' -Name DefaultShell -Value 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe' -PropertyType String -Force | Out-Null

    # Setup SSH keys
    'Setting up SSH keys...' | Tee-Object $logFile -Append | Write-Host
    $userProfile = "C:\\Users\\$AdminUser"
    $sshDir = "$userProfile\\.ssh"
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null

    # Create authorized_keys files
    $userKeys = "$sshDir\\authorized_keys"
    $adminKeys = 'C:\\ProgramData\\ssh\\administrators_authorized_keys'
    $PublicKey | Out-File -FilePath $userKeys -Encoding ascii
    $PublicKey | Out-File -FilePath $adminKeys -Encoding ascii

    # Set permissions on admin keys
    'Setting permissions...' | Tee-Object $logFile -Append | Write-Host
    icacls $adminKeys /inheritance:r /grant 'SYSTEM:F' /grant 'Administrators:F' | Out-Null

    # Restart SSH service
    'Restarting SSH service...' | Tee-Object $logFile -Append | Write-Host
    Restart-Service sshd

    # Install WSL if configured (from config.yaml)
    if ({str(self.config.install_wsl).lower()}) {{
        'Installing WSL with Fedora Linux 43...' | Tee-Object $logFile -Append | Write-Host
        try {{
            # This command enables WSL, installs WSL2, and installs Fedora in one go
            wsl.exe --install FedoraLinux-43 | Out-File $logFile -Append
            'WSL installation initiated successfully' | Tee-Object $logFile -Append | Write-Host

            # Check if reboot is configured
            if ({str(self.config.reboot_after_wsl).lower()}) {{
                'Scheduling reboot to complete WSL installation...' | Tee-Object $logFile -Append | Write-Host
                'Reboot will occur in 30 seconds to complete WSL setup' | Tee-Object $logFile -Append | Write-Host
                Start-Process -FilePath "shutdown.exe" -ArgumentList "/r", "/t", "30", "/c", "Reboot to complete WSL installation" -NoNewWindow
            }} else {{
                'Automatic reboot disabled - manual restart recommended for WSL' | Tee-Object $logFile -Append | Write-Host
            }}
        }} catch {{
            'WSL installation failed: ' + $_.Exception.Message | Tee-Object $logFile -Append | Write-Host
        }}
    }} else {{
        'WSL installation skipped (not enabled in config)' | Tee-Object $logFile -Append | Write-Host
    }}

    'SSH setup completed successfully at ' + (Get-Date) | Tee-Object $logFile -Append | Write-Host

}} catch {{
    $errorMsg = 'ERROR: ' + $_.Exception.Message
    $errorMsg | Tee-Object $logFile -Append | Write-Host
    throw
}}
"""

            # Upload script to blob storage
            script_name = "setup-ssh-server.ps1"
            self.logger.info("📤 Uploading SSH script to Azure blob storage...")
            blob_url = self._upload_script_to_blob(rg_name, script_content, script_name)

            # Create simple execution command (like the Go example)
            execution_command = f"powershell.exe -ExecutionPolicy Unrestricted -File {script_name}"

            # Log configuration details
            self.logger.info("📝 SSH extension configuration (BLOB STORAGE APPROACH):")
            self.logger.info(f"   - Script uploaded to blob: {blob_url}")
            self.logger.info(f"   - Execution command: {execution_command}")
            self.logger.info(f"   - Script size: {len(script_content)} characters")
            self.logger.info(f"   - Admin user: {self.config.admin_username}")

            # Get storage credentials for private blob access
            storage_name = blob_url.split('.blob.core.windows.net')[0].split('https://')[-1]
            keys = self.storage_client.storage_accounts.list_keys(rg_name, storage_name)
            storage_key = keys.keys[0].value

            # Create VM extension using blob storage pattern with private access
            extension_params = {
                "location": self.config.location,
                "publisher": "Microsoft.Compute",
                "type": "CustomScriptExtension",
                "typeHandlerVersion": "1.10",
                "autoUpgradeMinorVersion": True,
                "protectedSettings": {
                    "fileUris": [blob_url],
                    "commandToExecute": execution_command,
                    "storageAccountName": storage_name,
                    "storageAccountKey": storage_key
                },
                "settings": {}
            }

            self.logger.info(f"Extension configured with storage account: {storage_name}")

            # Apply the extension
            self.logger.info("🔧 Deploying SSH setup extension to VM...")
            self.logger.info(f"   - Resource Group: {rg_name}")
            self.logger.info(f"   - VM Name: {vm_name}")
            self.logger.info(f"   - Extension Name: CustomScriptExtension")
            self.logger.info(f"   - Will create detailed log at: C:\\temp\\ssh-setup.log")

            try:
                extension_operation = self.compute_client.virtual_machine_extensions.begin_create_or_update(
                    rg_name, vm_name, 'CustomScriptExtension', extension_params
                )
                self.logger.info("✅ Extension deployment request submitted successfully")
            except Exception as e:
                self.logger.error(f"❌ Failed to submit extension deployment: {e}")
                raise

            self.logger.info("⏳ Waiting for extension deployment...")
            extension_result = extension_operation.result()
            self.logger.info(f"📦 Extension deployment completed: {extension_result.provisioning_state}")

            # Check extension status
            try:
                extension_status = self.compute_client.virtual_machine_extensions.get(
                    rg_name, vm_name, 'CustomScriptExtension', expand='instanceView'
                )
                if extension_status.instance_view:
                    self.logger.info("📊 Extension execution status:")
                    for status in extension_status.instance_view.statuses:
                        self.logger.info(f"   - {status.code}: {status.message}")

                    # Check for errors
                    error_statuses = [s for s in extension_status.instance_view.statuses if s.level == 'Error']
                    if error_statuses:
                        self.logger.error("❌ Extension execution errors found:")
                        for error in error_statuses:
                            self.logger.error(f"   - {error.code}: {error.message}")
                        raise Exception(f"SSH extension failed: {error_statuses[0].message}")
                    else:
                        self.logger.info("✅ No extension errors detected")
                else:
                    self.logger.warning("⚠️  Extension status not available")
            except Exception as e:
                self.logger.warning(f"⚠️  Could not check extension status: {e}")

            self.logger.info("✅ SSH server extension deployment completed")
            self.logger.info(f"🔑 Private key saved to: {private_key_path}")
            self.logger.info(f"🔑 Public key deployed to VM authorized_keys")

            # Log WSL and reboot status
            if self.config.install_wsl:
                self.logger.info("🐧 WSL (Fedora Linux 43) installation initiated")
                if self.config.reboot_after_wsl:
                    self.logger.warning("🔄 VM will automatically reboot in ~30 seconds to complete WSL installation")
                    self.logger.info("⏳ SSH access will be temporarily unavailable during reboot")
                    self.logger.info("✅ After reboot: SSH and WSL will be fully functional")
                else:
                    self.logger.warning("⚠️  Automatic reboot disabled - manual restart recommended for full WSL")

        except Exception as e:
            self.logger.warning(f"⚠️  SSH server setup failed: {e}")
            self.logger.info("💡 You can manually install SSH server by connecting to the VM and running:")
            self.logger.info("   RDP to the VM and run scripts/setup-ssh-server.ps1")
            self.logger.info("   Or use DISM: dism.exe /online /add-capability /capabilityname:OpenSSH.Server~~~~0.0.1.0")
            self.logger.info("   Or PowerShell: Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0")

    def create_resource_group(self) -> str:
        """Create resource group if it doesn't exist"""
        names = self._get_resource_names()
        rg_name = names['resource_group']

        try:
            self.resource_client.resource_groups.get(rg_name)
            self.logger.info(f"Resource group {rg_name} already exists")
        except:
            self.logger.info(f"Creating resource group {rg_name}")
            rg_params = {
                'location': self.config.location,
                'tags': self.config.tags
            }
            self.resource_client.resource_groups.create_or_update(rg_name, rg_params)
            self.logger.info(f"Resource group {rg_name} created")

        return rg_name

    def create_network_infrastructure(self, rg_name: str) -> Tuple[str, str, str]:
        """Create VNet, subnet, NSG, and public IP"""
        names = self._get_resource_names()

        # Create Virtual Network
        self.logger.info("Creating virtual network infrastructure")
        vnet_params = VirtualNetwork(
            location=self.config.location,
            address_space={'address_prefixes': ['10.0.0.0/16']},
            subnets=[
                Subnet(
                    name=names['subnet_name'],
                    address_prefix='10.0.0.0/24'
                )
            ],
            tags=self.config.tags
        )

        vnet_operation = self.network_client.virtual_networks.begin_create_or_update(
            rg_name, names['vnet_name'], vnet_params
        )
        vnet_operation.result()

        # Create Network Security Group with RDP and SSH rules
        nsg_params = NetworkSecurityGroup(
            location=self.config.location,
            security_rules=[
                SecurityRule(
                    name='AllowRDP',
                    protocol='Tcp',
                    source_address_prefix='*',
                    source_port_range='*',
                    destination_address_prefix='*',
                    destination_port_range='3389',
                    access='Allow',
                    direction='Inbound',
                    priority=1000
                ),
                SecurityRule(
                    name='AllowSSH',
                    protocol='Tcp',
                    source_address_prefix='*',
                    source_port_range='*',
                    destination_address_prefix='*',
                    destination_port_range='22',
                    access='Allow',
                    direction='Inbound',
                    priority=1001
                )
            ],
            tags=self.config.tags
        )

        nsg_operation = self.network_client.network_security_groups.begin_create_or_update(
            rg_name, names['nsg_name'], nsg_params
        )
        nsg_result = nsg_operation.result()

        # Create Public IP
        pip_params = PublicIPAddress(
            location=self.config.location,
            sku={'name': 'Basic'},
            public_ip_allocation_method='Dynamic',
            tags=self.config.tags
        )

        pip_operation = self.network_client.public_ip_addresses.begin_create_or_update(
            rg_name, names['pip_name'], pip_params
        )
        pip_result = pip_operation.result()

        # Create Network Interface
        nic_params = NetworkInterface(
            location=self.config.location,
            ip_configurations=[
                NetworkInterfaceIPConfiguration(
                    name='ipconfig1',
                    subnet={'id': f"/subscriptions/{self.subscription_id}/resourceGroups/{rg_name}/providers/Microsoft.Network/virtualNetworks/{names['vnet_name']}/subnets/{names['subnet_name']}"},
                    public_ip_address={'id': pip_result.id}
                )
            ],
            network_security_group={'id': nsg_result.id},
            tags=self.config.tags
        )

        nic_operation = self.network_client.network_interfaces.begin_create_or_update(
            rg_name, names['nic_name'], nic_params
        )
        nic_result = nic_operation.result()

        self.logger.info("Network infrastructure created successfully")
        return nic_result.id, pip_result.id, nsg_result.id

    def create_managed_disk(self, rg_name: str) -> str:
        """Create managed disk for the VM"""
        names = self._get_resource_names()

        # Check if disk already exists
        try:
            existing_disk = self.compute_client.disks.get(rg_name, names['disk_name'])
            self.logger.info(f"Using existing disk: {names['disk_name']}")
            return existing_disk.id
        except:
            pass

        self.logger.info(f"Creating managed disk: {names['disk_name']}")

        disk_config = {
            'location': self.config.location,
            'sku': {'name': StorageAccountTypes.premium_lrs},
            'disk_size_gb': 256,
            'creation_data': {
                'create_option': DiskCreateOption.from_image,
                'image_reference': {
                    'id': f"/subscriptions/{self.subscription_id}/providers/Microsoft.Compute/locations/{self.config.location}/publishers/MicrosoftWindowsDesktop/artifactTypes/vmimage/offers/Windows-11/skus/win11-25h2-ent/versions/latest"
                }
            },
            'tags': self.config.tags
        }

        operation = self.compute_client.disks.begin_create_or_update(
            rg_name, names['disk_name'], disk_config
        )
        disk_result = operation.result()

        self.logger.info(f"Managed disk created: {disk_result.id}")
        return disk_result.id

    def _validate_resource_group_consistency(self, rg_name: str) -> bool:
        """Validate that all resources will be created in the same resource group"""
        names = self._get_resource_names()
        expected_rg = names['resource_group']

        if rg_name != expected_rg:
            self.logger.error(f"Resource group mismatch: using {rg_name}, expected {expected_rg}")
            return False

        self.logger.info(f"✅ All resources will be created in resource group: {rg_name}")
        return True

    def create_vm(self) -> VMState:
        """Create the complete VM with specified configuration"""
        # Start overall timing
        overall_start = self._log_operation_start("VM creation process")

        self.logger.info(f"Project: {self.config.project_name}")
        self.logger.info(f"Location: {self.config.location}")

        # Check if VM state or disk already exists
        if self.state and self.state.vm_exists:
            self.logger.warning("⚠️  VM already exists! Use 'recreate' to recreate or 'info' to check status.")
            raise ValueError(f"VM {self.state.vm_name} already exists. Use 'python azure_vm_manager.py recreate' instead.")

        # Validate configuration before creating anything
        if not self.validate_configuration():
            raise ValueError("Configuration validation failed - aborting VM creation")

        # Create resource group
        rg_start = time.time()
        rg_name = self.create_resource_group()
        self.logger.info(f"⏱️ Resource group created in {self._format_duration(time.time() - rg_start)}")

        # Check if disk already exists (common issue)
        names = self._get_resource_names()
        existing_disk = None
        try:
            existing_disk = self.compute_client.disks.get(rg_name, names['disk_name'])
            if existing_disk:
                self.logger.warning(f"⚠️  Disk '{names['disk_name']}' already exists!")
                self.logger.info("💡 This usually means you should use 'recreate' instead of 'create'")
                self.logger.info(f"   To recreate VM with existing disk: python azure_vm_manager.py recreate")
                self.logger.info(f"   To delete everything and start fresh: python azure_vm_manager.py destroy-all")
                raise ValueError(f"Disk {names['disk_name']} already exists. Use 'recreate' command to reuse existing disk.")
        except Exception as e:
            if "ResourceNotFound" not in str(e):
                self.logger.debug(f"Disk check failed: {e}")
            # Disk doesn't exist, which is expected for create command

        # Validate resource group consistency
        if not self._validate_resource_group_consistency(rg_name):
            raise ValueError("Resource group validation failed")

        self.logger.info(f"Creating all resources in resource group: {rg_name}")

        # Create network infrastructure
        network_start = self._log_operation_start("network infrastructure creation")
        nic_id, pip_id, nsg_id = self.create_network_infrastructure(rg_name)
        self._log_operation_end("Network infrastructure creation", network_start)

        # VM Configuration and Creation
        vm_start = self._log_operation_start(f"VM '{names['vm_name']}' provisioning")
        vm_params = VirtualMachine(
            location=self.config.location,
            hardware_profile=HardwareProfile(
                vm_size=self.config.vm_size
            ),
            storage_profile=StorageProfile(
                image_reference=self._get_windows_image_reference(),
                os_disk=OSDisk(
                    name=names['disk_name'],
                    create_option=DiskCreateOption.from_image,
                    caching=CachingTypes.read_write,
                    managed_disk={'storage_account_type': StorageAccountTypes.premium_lrs},
                    disk_size_gb=256
                )
            ),
            os_profile=OSProfile(
                computer_name=names['vm_name'][:15],  # Windows computer name limit
                admin_username=self.config.admin_username,
                admin_password=self.config.admin_password,
                windows_configuration=WindowsConfiguration(
                    enable_automatic_updates=False,
                    provision_vm_agent=True
                )
            ),
            network_profile=NetworkProfile(
                network_interfaces=[
                    NetworkInterfaceReference(id=nic_id)
                ]
            ),
            tags=self.config.tags
        )

        # Add spot instance configuration if requested
        if self.config.spot:
            vm_params.priority = 'Spot'
            vm_params.eviction_policy = 'Deallocate'
            vm_params.billing_profile = {'max_price': 0.5}  # Max $0.50/hour

        self.logger.info(f"🖥️ Submitting VM creation request...")
        vm_operation = self.compute_client.virtual_machines.begin_create_or_update(
            rg_name, names['vm_name'], vm_params
        )

        # Start polling for IP immediately after VM creation request is submitted
        # The IP becomes available much sooner than the full VM provisioning
        self.logger.info("🌐 VM creation request submitted, checking for IP address...")

        # Create temporary state for IP polling
        temp_state = VMState(
            vm_name=names['vm_name'],
            resource_group=rg_name,
            disk_name=names['disk_name'],
            disk_resource_id="",  # Will be set later
            network_interface_id=nic_id,
            public_ip_id=pip_id,
            created_at=datetime.now().isoformat(),
            vm_resource_id="",  # Will be set later
            vm_exists=False  # Not fully created yet
        )
        self.state = temp_state

        # Poll for IP while VM is still provisioning
        public_ip = self.wait_for_public_ip(timeout=180)  # 3 minutes should be enough
        if public_ip:
            self.logger.info(f"🎉 Got IP address early: {public_ip}")
        else:
            self.logger.warning("⏰ IP not available yet, will continue VM setup")

        # Wait for VM provisioning to complete
        self.logger.info("⏳ Waiting for VM provisioning to complete...")
        vm_result = vm_operation.result()
        self._log_operation_end(f"VM '{names['vm_name']}' provisioning", vm_start)

        # Configure SSH Server using custom script extension
        ssh_start = self._log_operation_start("SSH server configuration")
        self._install_ssh_server(rg_name, names['vm_name'])
        self._log_operation_end("SSH server configuration", ssh_start)

        # Get the disk resource ID from the created VM
        disk_resource_id = f"/subscriptions/{self.subscription_id}/resourceGroups/{rg_name}/providers/Microsoft.Compute/disks/{names['disk_name']}"

        # Create and save state
        state = VMState(
            vm_name=names['vm_name'],
            resource_group=rg_name,
            disk_name=names['disk_name'],
            disk_resource_id=disk_resource_id,
            network_interface_id=nic_id,
            public_ip_id=pip_id,
            created_at=datetime.now().isoformat(),
            vm_resource_id=vm_result.id,
            vm_exists=True
        )

        self._save_state(state)

        # Summary of created resources
        self.logger.info("✅ VM and all resources created successfully!")
        self.logger.info(f"📁 Resource Group: {rg_name}")
        self.logger.info(f"🖥️  VM: {names['vm_name']}")
        self.logger.info(f"💾 Disk: {names['disk_name']}")
        self.logger.info(f"📡 Network Interface: {names['nic_name']}")
        self.logger.info(f"🌐 Public IP: {names['pip_name']}")
        self.logger.info(f"🔒 Security Group: {names['nsg_name']} (RDP:3389, SSH:22)")
        self.logger.info(f"🔗 Virtual Network: {names['vnet_name']}")
        self.logger.info(f"🔧 SSH Server: Password + Key authentication configured")
        self.logger.info(f"🖥️ Windows: Ready for RDP and SSH connections")
        self.logger.info(f"💡 All resources are grouped in '{rg_name}' for easy deletion")
        self.logger.info("")
        self.logger.info("🔑 SSH Connection Options:")
        private_key_path = f"{self.config.project_name}-ssh-key"
        if os.path.exists(private_key_path):
            self.logger.info(f"   ssh -i {private_key_path} {self.config.admin_username}@<vm-ip>")
            self.logger.info(f"   ssh {self.config.admin_username}@<vm-ip>  (with password)")
        else:
            self.logger.info(f"   ssh {self.config.admin_username}@<vm-ip>  (with password)")

        # Log overall completion time
        self._log_operation_end("VM creation process", overall_start)

        return state

    def destroy_vm_keep_disk(self) -> bool:
        """Destroy VM but keep the disk for later reuse"""
        if not self.state or not self.state.vm_exists:
            self.logger.warning("No VM exists to destroy")
            return False

        # Start timing
        destroy_start = self._log_operation_start(f"VM '{self.state.vm_name}' destruction (preserving disk)")

        try:
            # Delete the VM
            self.logger.info(f"🗑️ Submitting VM deletion request...")
            vm_operation = self.compute_client.virtual_machines.begin_delete(
                self.state.resource_group, self.state.vm_name
            )
            vm_operation.result()

            # Update state
            self.state.vm_exists = False
            self.state.vm_resource_id = None
            self._save_state(self.state)

            # Log completion time
            self._log_operation_end(f"VM '{self.state.vm_name}' destruction (disk preserved)", destroy_start)
            return True

        except Exception as e:
            self.logger.error(f"Failed to destroy VM: {e}")
            return False

    def recreate_vm_with_disk(self) -> VMState:
        """Recreate VM using existing disk"""
        if not self.state:
            raise ValueError("No state found. Cannot recreate VM without existing disk state.")

        if self.state.vm_exists:
            self.logger.warning("VM already exists")
            return self.state

        # Start timing
        recreate_start = self._log_operation_start(f"VM '{self.state.vm_name}' recreation with existing disk")

        names = self._get_resource_names()

        # Verify disk exists
        try:
            disk = self.compute_client.disks.get(self.state.resource_group, self.state.disk_name)
            self.logger.info(f"Using existing disk: {disk.id}")
        except Exception as e:
            raise ValueError(f"Disk {self.state.disk_name} not found: {e}")

        # Verify network interface exists
        try:
            nic = self.network_client.network_interfaces.get(
                self.state.resource_group, names['nic_name']
            )
            self.logger.info(f"Using existing network interface: {nic.id}")
        except Exception as e:
            self.logger.warning(f"Network interface not found, recreating: {e}")
            _, _, _ = self.create_network_infrastructure(self.state.resource_group)

        # VM Configuration for recreation
        vm_params = VirtualMachine(
            location=self.config.location,
            hardware_profile=HardwareProfile(
                vm_size=self.config.vm_size
            ),
            storage_profile=StorageProfile(
                os_disk=OSDisk(
                    name=self.state.disk_name,
                    create_option=DiskCreateOption.attach,
                    managed_disk={'id': self.state.disk_resource_id},
                    caching=CachingTypes.read_write,
                    os_type='Windows'  # Required when attaching existing disk
                )
            ),
            network_profile=NetworkProfile(
                network_interfaces=[
                    NetworkInterfaceReference(id=self.state.network_interface_id)
                ]
            ),
            tags=self.config.tags
        )

        # Add spot instance configuration if requested
        if self.config.spot:
            vm_params.priority = 'Spot'
            vm_params.eviction_policy = 'Deallocate'
            vm_params.billing_profile = {'max_price': 0.5}

        # Create the VM
        self.logger.info("🖥️ Submitting VM recreation request...")
        vm_operation = self.compute_client.virtual_machines.begin_create_or_update(
            self.state.resource_group, self.state.vm_name, vm_params
        )

        # Start polling for IP immediately after VM recreation request is submitted
        self.logger.info("🌐 VM recreation request submitted, checking for IP address...")
        public_ip = self.wait_for_public_ip(timeout=180)  # 3 minutes should be enough
        if public_ip:
            self.logger.info(f"🎉 Got IP address early during recreation: {public_ip}")
        else:
            self.logger.warning("⏰ IP not available yet during recreation")

        # Wait for VM recreation to complete
        self.logger.info("⏳ Waiting for VM recreation to complete...")
        vm_result = vm_operation.result()

        # Update state
        self.state.vm_resource_id = vm_result.id
        self.state.vm_exists = True
        self._save_state(self.state)

        # Log completion time
        self._log_operation_end(f"VM '{self.state.vm_name}' recreation with existing disk", recreate_start)
        return self.state

    def get_vm_info(self) -> Dict:
        """Get current VM information"""
        if not self.state:
            return {"status": "No VM state found"}

        # Get all resources in the group
        resources = self.list_resources_in_group()

        info = {
            "vm_name": self.state.vm_name,
            "resource_group": self.state.resource_group,
            "vm_exists": self.state.vm_exists,
            "disk_name": self.state.disk_name,
            "created_at": self.state.created_at,
            "resource_count": len(resources),
            "resources_in_group": [f"{r['name']} ({r['type']})" for r in resources]
        }

        if self.state.vm_exists:
            try:
                vm = self.compute_client.virtual_machines.get(
                    self.state.resource_group, self.state.vm_name,
                    expand='instanceView'
                )
                info.update({
                    "vm_size": vm.hardware_profile.vm_size,
                    "power_state": vm.instance_view.statuses[-1].display_status if vm.instance_view and vm.instance_view.statuses else "Unknown"
                })

                # Get public IP if available
                try:
                    names = self._get_resource_names()
                    pip = self.network_client.public_ip_addresses.get(
                        self.state.resource_group, names['pip_name']
                    )
                    if pip.ip_address:
                        info["public_ip"] = pip.ip_address
                        # Also save to generated/host file
                        self._save_ip_to_file(pip.ip_address)
                except:
                    pass

            except Exception as e:
                info["error"] = str(e)

        return info

    def wait_for_public_ip(self, timeout: int = 300, check_interval: int = 5) -> Optional[str]:
        """
        Poll for public IP address to become available.

        Args:
            timeout: Maximum time to wait in seconds (default: 5 minutes)
            check_interval: How often to check in seconds (default: 5 seconds)

        Returns:
            Public IP address when available, None if timeout reached
        """
        if not self.state:
            self.logger.warning("No VM state found")
            return None

        names = self._get_resource_names()
        start_time = time.time()
        attempts = 0

        self.logger.info("🔄 Waiting for public IP address to become available...")

        while time.time() - start_time < timeout:
            try:
                attempts += 1
                pip = self.network_client.public_ip_addresses.get(
                    self.state.resource_group, names['pip_name']
                )

                if pip.ip_address and pip.ip_address != "Not Assigned":
                    elapsed = time.time() - start_time
                    self.logger.info(f"🎉 Public IP address found after {elapsed:.1f} seconds ({attempts} attempts): {pip.ip_address}")

                    # Save IP to generated/host file
                    self._save_ip_to_file(pip.ip_address)

                    return pip.ip_address

                # Show progress every 15 seconds or on first few attempts
                if attempts <= 3 or (time.time() - start_time) % 15 < check_interval:
                    elapsed = time.time() - start_time
                    self.logger.info(f"⏳ Checking for IP... ({elapsed:.0f}s elapsed, attempt {attempts})")

                time.sleep(check_interval)

            except Exception as e:
                self.logger.debug(f"IP check failed (attempt {attempts}): {e}")
                time.sleep(check_interval)

        # Timeout reached
        elapsed = time.time() - start_time
        self.logger.warning(f"⏰ Timeout reached after {elapsed:.1f} seconds. IP address may not be available yet.")
        self.logger.info("💡 You can check IP later with: python azure_vm_manager.py info")
        return None

    def _save_ip_to_file(self, ip_address: str):
        """Save IP address to generated/host file with proper EOL"""
        try:
            with open('generated/host', 'w') as f:
                f.write(f"{ip_address}\n")
            self.logger.info(f"💾 IP address saved to generated/host: {ip_address}")
        except Exception as e:
            self.logger.warning(f"⚠️  Failed to save IP to generated/host: {e}")

    def _create_storage_account(self, rg_name: str) -> str:
        """Create or get existing storage account for script hosting"""
        import random
        import string
        import re

        # Clean project name and remove reserved words like "windows", "microsoft", "demo", etc.
        clean_name = self.config.project_name.lower()
        # Remove reserved words that Azure doesn't allow
        reserved_words = ['windows', 'microsoft', 'azure', 'demo', 'test', 'admin', 'root', 'api']
        for word in reserved_words:
            clean_name = clean_name.replace(word, '')

        # Remove all non-alphanumeric characters
        clean_name = re.sub(r'[^a-z0-9]', '', clean_name)

        # Ensure we have something left, fallback to 'vmscripts'
        if len(clean_name) < 3:
            clean_name = 'vmscripts'

        # Generate a unique storage account name (must be globally unique, lowercase, no special chars)
        storage_name = f"{clean_name[:10]}scripts"
        # Add random suffix to ensure uniqueness
        suffix = ''.join(random.choices(string.ascii_lowercase + string.digits, k=8))
        storage_name = f"{storage_name}{suffix}"[:24]  # Max 24 chars total

        try:
            # Check if storage account already exists
            storage_account = self.storage_client.storage_accounts.get_properties(rg_name, storage_name)
            self.logger.info(f"Using existing storage account: {storage_name}")
            return storage_name
        except Exception as e:
            if "ResourceNotFound" not in str(e):
                self.logger.error(f"Error checking storage account: {e}")
                raise

            # Create new storage account
            self.logger.info(f"Creating storage account: {storage_name}")

            storage_params = StorageAccountCreateParameters(
                sku=Sku(name=SkuName.standard_lrs),
                kind=Kind.storage_v2,
                location=self.config.location,
                tags=self.config.tags
            )

            try:
                operation = self.storage_client.storage_accounts.begin_create(
                    rg_name, storage_name, storage_params
                )
                result = operation.result()
                self.logger.info(f"Storage account created successfully: {storage_name}")
                self.logger.info(f"Storage account location: {result.location}")
                self.logger.info(f"Storage account provisioning state: {result.provisioning_state}")
                return storage_name
            except Exception as create_error:
                self.logger.error(f"Failed to create storage account: {create_error}")
                raise

    def _upload_script_to_blob(self, rg_name: str, script_content: str, script_name: str) -> str:
        """Upload script to blob storage and return URL"""
        storage_name = self._create_storage_account(rg_name)

        try:
            # Get storage account keys
            self.logger.info(f"Retrieving storage account keys for: {storage_name}")
            keys = self.storage_client.storage_accounts.list_keys(rg_name, storage_name)
            storage_key = keys.keys[0].value
            self.logger.info(f"Successfully retrieved storage key")

            # Create blob service client
            account_url = f"https://{storage_name}.blob.core.windows.net"
            self.logger.info(f"Creating blob service client for: {account_url}")
            blob_service = BlobServiceClient(
                account_url=account_url,
                credential=storage_key
            )
            self.logger.info("Blob service client created successfully")

        except Exception as e:
            self.logger.error(f"Failed to create blob service client: {e}")
            raise

        container_name = "scripts"

        try:
            # Check if container exists first
            container_client = blob_service.get_container_client(container_name)
            if container_client.exists():
                self.logger.info(f"Using existing blob container: {container_name}")
            else:
                self.logger.info(f"Creating private blob container: {container_name}")
                # Don't use public access - Azure VM extensions access internally
                container_client.create_container()
                self.logger.info(f"Created private blob container: {container_name}")
        except Exception as e:
            self.logger.error(f"Failed to create/access blob container: {e}")
            raise

        # Upload script to blob
        blob_name = script_name
        blob_client = blob_service.get_blob_client(container=container_name, blob=blob_name)

        try:
            blob_client.upload_blob(script_content, overwrite=True)
            self.logger.info(f"Successfully uploaded blob: {blob_name}")
        except Exception as e:
            self.logger.error(f"Failed to upload blob: {e}")
            raise

        # Return blob URL
        blob_url = f"https://{storage_name}.blob.core.windows.net/{container_name}/{blob_name}"
        self.logger.info(f"Script uploaded to blob: {blob_url}")
        return blob_url

    def list_resources_in_group(self) -> List[Dict]:
        """List all resources in the resource group"""
        if not self.state:
            return []

        try:
            resources = []
            resource_list = self.resource_client.resources.list_by_resource_group(
                self.state.resource_group
            )
            for resource in resource_list:
                resources.append({
                    'name': resource.name,
                    'type': resource.type,
                    'location': resource.location
                })
            return resources
        except Exception as e:
            self.logger.error(f"Failed to list resources: {e}")
            return []

    def destroy_all_resources(self) -> bool:
        """Destroy all resources including the disk"""
        if not self.state:
            self.logger.warning("No state found. Nothing to destroy.")
            return True

        # Start timing
        destroy_all_start = self._log_operation_start(f"complete resource group '{self.state.resource_group}' destruction")

        # List resources that will be deleted
        resources = self.list_resources_in_group()
        if resources:
            self.logger.info("Resources to be deleted:")
            for resource in resources:
                self.logger.info(f"  - {resource['name']} ({resource['type']})")

        try:
            # Delete the entire resource group (this removes ALL resources in one operation)
            self.logger.info("🗑️ Submitting resource group deletion request...")
            rg_operation = self.resource_client.resource_groups.begin_delete(
                self.state.resource_group
            )
            rg_operation.result()

            # Remove state file
            if os.path.exists(self.state_file):
                os.remove(self.state_file)
                self.logger.info("State file removed")

            self.state = None

            # Log completion time
            self._log_operation_end(f"complete resource group destruction", destroy_all_start)
            return True

        except Exception as e:
            self.logger.error(f"Failed to destroy all resources: {e}")
            return False


def main():
    """Main CLI interface"""
    parser = argparse.ArgumentParser(description='Azure Windows 11 VM Manager')
    parser.add_argument('--subscription-id',
                       help='Azure subscription ID (will use az cli default if not provided)')
    parser.add_argument('action', choices=[
        'create', 'destroy-vm', 'recreate', 'info', 'list-resources', 'destroy-all'
    ], help='Action to perform')

    # Configuration options (these override config.yaml values if provided)
    parser.add_argument('--project-name',
                       help='Project name for resource naming (overrides config.yaml)')
    parser.add_argument('--location',
                       help='Azure region (overrides config.yaml)')
    parser.add_argument('--vm-size',
                       help='VM size (overrides config.yaml)')
    parser.add_argument('--no-spot', action='store_true',
                       help='Disable spot instance (use regular pricing)')
    parser.add_argument('--admin-username',
                       help='Admin username (overrides .env.secret)')
    parser.add_argument('--admin-password',
                       help='Admin password (overrides .env.secret)')
    parser.add_argument('--install-wsl', action='store_true',
                       help='Install WSL with Fedora Linux 43 (overrides config.yaml)')
    parser.add_argument('--no-reboot-after-wsl', action='store_true',
                       help='Disable automatic reboot after WSL installation')
    parser.add_argument('--yes', '-y', action='store_true',
                       help='Automatically answer yes to all prompts (for destroy-all)')

    args = parser.parse_args()

    # Get subscription ID from CLI or environment
    subscription_id = args.subscription_id
    if not subscription_id:
        try:
            import subprocess
            result = subprocess.run(['az', 'account', 'show', '--query', 'id', '-o', 'tsv'],
                                  capture_output=True, text=True, check=True)
            subscription_id = result.stdout.strip()
        except (subprocess.CalledProcessError, FileNotFoundError):
            print("Error: Could not get subscription ID from Azure CLI.")
            print("Please run 'az login' or provide --subscription-id")
            return 1

    # Create VM configuration (command line args override config files)
    config = VMConfig(
        project_name=args.project_name,
        location=args.location,
        vm_size=args.vm_size,
        spot=not args.no_spot if args.no_spot else None,
        admin_username=args.admin_username,
        admin_password=args.admin_password,
        install_wsl=args.install_wsl,
        reboot_after_wsl=not args.no_reboot_after_wsl if args.no_reboot_after_wsl else None
    )

    # Initialize manager
    manager = AzureVMManager(subscription_id, config)

    try:
        if args.action == 'create':
            print("Creating Windows 11 VM with persistent disk...")
            state = manager.create_vm()
            print(f"✅ VM created successfully!")
            print(f"VM Name: {state.vm_name}")
            print(f"Resource Group: {state.resource_group}")
            print(f"Disk: {state.disk_name}")

            # Check if we already have the IP from the creation process
            info = manager.get_vm_info()
            public_ip = info.get('public_ip')

            # If we don't have IP yet, do a quick poll (this should be rare now)
            if not public_ip:
                print("🔄 Getting final IP address...")
                public_ip = manager.wait_for_public_ip(timeout=30)  # Short timeout since we already tried

            if public_ip:
                print(f"Public IP: {public_ip}")
                print(f"💾 IP saved to: generated/host")
                print(f"RDP: mstsc /v:{public_ip}")
                private_key_path = f"{manager.config.project_name}-ssh-key"
                if os.path.exists(private_key_path):
                    print(f"SSH (with key): ssh -i {private_key_path} {manager.config.admin_username}@{public_ip}")
                    print(f"SSH (with password): ssh {manager.config.admin_username}@{public_ip}")
                else:
                    print(f"SSH: ssh {manager.config.admin_username}@{public_ip}")
            else:
                print("Public IP: Not yet available")
                print("RDP: Check IP later with 'python azure_vm_manager.py info'")

        elif args.action == 'destroy-vm':
            print("Destroying VM while preserving disk...")
            success = manager.destroy_vm_keep_disk()
            if success:
                print("✅ VM destroyed, disk preserved")
            else:
                print("❌ Failed to destroy VM")

        elif args.action == 'recreate':
            print("Recreating VM with existing disk...")
            state = manager.recreate_vm_with_disk()
            print(f"✅ VM recreated successfully!")

            # Check if we already have the IP from the recreation process
            info = manager.get_vm_info()
            public_ip = info.get('public_ip')

            # If we don't have IP yet, do a quick poll (this should be rare now)
            if not public_ip:
                print("🔄 Getting final IP address...")
                public_ip = manager.wait_for_public_ip(timeout=30)  # Short timeout since we already tried

            if public_ip:
                print(f"Public IP: {public_ip}")
                print(f"💾 IP saved to: generated/host")
                print(f"RDP: mstsc /v:{public_ip}")
                private_key_path = f"{manager.config.project_name}-ssh-key"
                if os.path.exists(private_key_path):
                    print(f"SSH (with key): ssh -i {private_key_path} {manager.config.admin_username}@{public_ip}")
                    print(f"SSH (with password): ssh {manager.config.admin_username}@{public_ip}")
                else:
                    print(f"SSH: ssh {manager.config.admin_username}@{public_ip}")
            else:
                print("Public IP: Not yet available")
                print("RDP: Check IP later with 'python azure_vm_manager.py info'")

        elif args.action == 'info':
            info = manager.get_vm_info()
            print("Current VM Status:")
            for key, value in info.items():
                print(f"  {key}: {value}")

        elif args.action == 'list-resources':
            resources = manager.list_resources_in_group()
            if not resources:
                print("No resources found or no VM state available.")
            else:
                print(f"Resources in group '{manager.state.resource_group}':")
                print(f"Total resources: {len(resources)}")
                print()
                for resource in resources:
                    print(f"  📦 {resource['name']}")
                    print(f"     Type: {resource['type']}")
                    print(f"     Location: {resource['location']}")
                    print()
                print(f"💡 All {len(resources)} resources can be deleted at once using 'destroy-all'")

        elif args.action == 'destroy-all':
            print("⚠️  WARNING: This will destroy ALL resources including the disk!")

            # Check for --yes flag to bypass confirmation
            if args.yes:
                print("🚀 --yes flag provided, proceeding without confirmation...")
                confirm_destroy = True
            else:
                response = input("Are you sure? Type 'yes' to confirm: ")
                confirm_destroy = response.lower() == 'yes'

            if confirm_destroy:
                success = manager.destroy_all_resources()
                if success:
                    print("✅ All resources destroyed")
                else:
                    print("❌ Failed to destroy all resources")
            else:
                print("Operation cancelled")

    except Exception as e:
        error_msg = str(e)
        print(f"❌ Error: {error_msg}")

        # Provide helpful guidance for common errors
        if "already exists" in error_msg and "CreateOption.Attach" in error_msg:
            print("\n💡 Helpful guidance:")
            print("   This error occurs when trying to 'create' a VM but the disk already exists.")
            print("   Try one of these solutions:")
            print(f"   1. Use existing disk: python azure_vm_manager.py recreate")
            print(f"   2. Delete everything:  python azure_vm_manager.py destroy-all")
            print(f"   3. Check current state: python azure_vm_manager.py info")
        elif "already exists" in error_msg and "recreate" in error_msg:
            print("\n💡 Use the 'recreate' command instead:")
            print(f"   python azure_vm_manager.py recreate")

        return 1

    return 0


if __name__ == '__main__':
    sys.exit(main())
