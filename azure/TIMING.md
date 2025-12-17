# VM Operation Timing

The Azure VM Manager now tracks and logs the duration of all major operations to help monitor performance and identify bottlenecks.

## Tracked Operations

### **VM Creation Process** (`create_vm`)
- **Overall timing**: Complete VM creation from start to finish
- **Resource group creation**: Time to create or verify resource group
- **Network infrastructure creation**: Time to create VNet, NSG, Public IP, and NIC
- **VM provisioning**: Time for Azure to provision the VM itself
- **SSH server configuration**: Time to install and configure SSH server

### **VM Deletion Process** (`destroy_vm_keep_disk`)
- **VM destruction**: Time to delete VM while preserving disk

### **Complete Cleanup** (`destroy_all_resources`)
- **Resource group destruction**: Time to delete entire resource group and all resources

### **VM Recreation** (`recreate_vm_with_disk`)
- **VM recreation**: Time to recreate VM using existing disk

## Log Format

### Start Messages
```
🚀 Starting {operation} at 2025-12-17 16:30:45
```

### Completion Messages
```
✅ {operation} completed in 2.3 minutes (142.1 seconds)
✅ {operation} completed in 45.7 seconds
✅ {operation} completed in 1.2 hours, 15.3 minutes (4515.2 seconds)
```

## Example Output

### VM Creation
```
🚀 Starting VM creation process at 2025-12-17 16:30:00
🔍 Validating configuration...
✅ Azure connectivity validated
✅ Configuration validation passed
⏱️ Resource group created in 2.1 seconds
✅ All resources will be created in resource group: test-rg
🚀 Starting network infrastructure creation at 2025-12-17 16:30:05
✅ Network infrastructure creation completed in 45.3 seconds
🚀 Starting VM 'test-vm' provisioning at 2025-12-17 16:30:50
🖥️ Submitting VM creation request...
✅ VM 'test-vm' provisioning completed in 3.2 minutes (194.5 seconds)
🚀 Starting SSH server configuration at 2025-12-17 16:34:05
✅ SSH server configuration completed in 1.1 minutes (67.2 seconds)
✅ VM creation process completed in 4.8 minutes (288.1 seconds)
```

### VM Deletion
```
🚀 Starting VM 'test-vm' destruction (preserving disk) at 2025-12-17 17:15:00
🗑️ Submitting VM deletion request...
✅ VM 'test-vm' destruction (disk preserved) completed in 1.3 minutes (78.9 seconds)
```

### Complete Cleanup
```
🚀 Starting complete resource group 'test-rg' destruction at 2025-12-17 17:20:00
Resources to be deleted:
  - test-vm (Microsoft.Compute/virtualMachines)
  - test-disk (Microsoft.Compute/disks)
  - test-nic (Microsoft.Network/networkInterfaces)
  - test-nsg (Microsoft.Network/networkSecurityGroups)
  - test-pip (Microsoft.Network/publicIPAddresses)
  - test-vnet (Microsoft.Network/virtualNetworks)
🗑️ Submitting resource group deletion request...
✅ complete resource group destruction completed in 2.1 minutes (127.4 seconds)
```

## Performance Benefits

### **Monitoring**
- Track deployment time trends
- Identify slow operations
- Compare performance across different VM sizes/regions

### **Troubleshooting**
- Pinpoint which stage is taking longest
- Identify performance bottlenecks
- Monitor Azure service performance

### **Planning**
- Estimate deployment times for automation
- Schedule operations based on historical timing
- Budget time for different operation types

## Timing Data Location

All timing information is logged to:
- **Console output**: Real-time visibility during operations
- **Log files**: `var/logs/{project-name}.log` for historical analysis

The timing data helps track performance and provides valuable insights for optimizing VM deployment workflows.