# Install Podman on Windows

Quick automated installation guide for Podman on Windows.

## Installation Steps

### 1. Install Podman using Winget
```cmd
# Install Podman using Windows Package Manager
winget install RedHat.Podman

# Verify installation
podman --version
```

### 2. Initialize Podman Machine
```cmd
# Create a new Podman machine with sufficient resources
podman machine init --cpus 4 --memory 4096 --disk-size 20

# Start the machine
podman machine start

# Verify it's working
podman machine list
```

### 3. Test Podman Setup
```cmd
# Check machine status
podman machine info

# SSH into the machine to test
podman machine ssh

# Test basic functionality
podman run hello-world
```

## Next Steps for VMBus Testing

After installation, to test the VMBus driver:

1. **SSH into Podman machine:**
   ```cmd
   podman machine ssh
   ```

2. **Check VMBus support:**
   ```bash
   ls /sys/bus/vmbus/devices/
   dmesg | grep -i hyperv
   ```

3. **Build the Linux driver:**
   ```bash
   # Copy project files to machine
   # Build driver in guest/driver/ directory
   ```

## Troubleshooting

- **If winget fails:** Update Windows or install from [GitHub releases](https://github.com/containers/podman/releases)
- **If machine won't start:** Check Hyper-V is enabled: `Get-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V-All -Online`
- **If VMBus missing:** The machine needs Hyper-V backend (not WSL2)

## Alternative Installation Methods

If winget doesn't work:

### Chocolatey
```cmd
choco install podman-desktop
```

### Manual Download
Download from: https://github.com/containers/podman/releases/latest