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
except ImportError as e:
    print(f"Error: Missing required Azure SDK packages. Install with:")
    print("pip install azure-mgmt-compute azure-mgmt-resource azure-mgmt-network azure-identity python-dotenv pyyaml")
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

        # Ensure var directories exist
        self._ensure_var_directories()

        # State file for persistence (in var/state/)
        self.state_file = f"var/state/{config.project_name}_state.json"
        self.state = self._load_state()

        # Setup logging
        self._setup_logging()

    def _ensure_var_directories(self):
        """Create var directories if they don't exist"""
        var_dirs = ['var', 'var/logs', 'var/state']
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
        """Install and configure SSH server on the VM using custom script extension"""
        try:
            # Generate SSH keys
            private_key_path, public_key = self._generate_ssh_keys()

            # Read the PowerShell script
            script_path = os.path.join(os.path.dirname(__file__), 'scripts', 'setup-ssh-server.ps1')
            with open(script_path, 'r') as f:
                ssh_script = f.read()

            # Escape the public key for PowerShell
            escaped_public_key = public_key.replace('"', '""')

            # Create PowerShell command that runs the script with parameters
            ssh_command = f'powershell.exe -ExecutionPolicy Bypass -Command "$publicKey = \\"{escaped_public_key}\\"; $adminUser = \\"{self.config.admin_username}\\"; {ssh_script}"'

            # Create custom script extension with correct parameters
            from azure.mgmt.compute.models import VirtualMachineExtension

            extension_params = VirtualMachineExtension(
                location=self.config.location,
                publisher='Microsoft.Compute',
                type_='CustomScriptExtension',
                type_handler_version='1.10',
                auto_upgrade_minor_version=True,
                settings={
                    'commandToExecute': ssh_command
                }
            )

            # Apply the extension
            extension_operation = self.compute_client.virtual_machine_extensions.begin_create_or_update(
                rg_name, vm_name, 'SSHServerSetup', extension_params
            )
            extension_operation.result()

            self.logger.info("✅ SSH server and key authentication configured successfully")
            self.logger.info(f"🔑 Private key saved to: {private_key_path}")
            self.logger.info(f"🔑 Public key deployed to VM authorized_keys")

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

        # Validate configuration before creating anything
        if not self.validate_configuration():
            raise ValueError("Configuration validation failed - aborting VM creation")

        # Create resource group
        rg_start = time.time()
        rg_name = self.create_resource_group()
        self.logger.info(f"⏱️ Resource group created in {self._format_duration(time.time() - rg_start)}")

        # Validate resource group consistency
        if not self._validate_resource_group_consistency(rg_name):
            raise ValueError("Resource group validation failed")

        self.logger.info(f"Creating all resources in resource group: {rg_name}")

        # Create network infrastructure
        network_start = self._log_operation_start("network infrastructure creation")
        nic_id, pip_id, nsg_id = self.create_network_infrastructure(rg_name)
        self._log_operation_end("Network infrastructure creation", network_start)

        names = self._get_resource_names()

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
        vm_operation = self.compute_client.virtual_machines.begin_create_or_update(
            self.state.resource_group, self.state.vm_name, vm_params
        )
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
                except:
                    pass

            except Exception as e:
                info["error"] = str(e)

        return info

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
        admin_password=args.admin_password
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

            # Wait a bit and get IP address
            time.sleep(30)
            info = manager.get_vm_info()
            if 'public_ip' in info:
                print(f"Public IP: {info['public_ip']}")
            print(f"RDP: mstsc /v:{info.get('public_ip', 'pending')}")

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

            # Wait a bit and get IP address
            time.sleep(30)
            info = manager.get_vm_info()
            if 'public_ip' in info:
                print(f"Public IP: {info['public_ip']}")
            print(f"RDP: mstsc /v:{info.get('public_ip', 'pending')}")

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
            response = input("Are you sure? Type 'yes' to confirm: ")
            if response.lower() == 'yes':
                success = manager.destroy_all_resources()
                if success:
                    print("✅ All resources destroyed")
                else:
                    print("❌ Failed to destroy all resources")
            else:
                print("Operation cancelled")

    except Exception as e:
        print(f"❌ Error: {e}")
        return 1

    return 0


if __name__ == '__main__':
    sys.exit(main())