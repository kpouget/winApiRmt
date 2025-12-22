# Kevin Pouget's Development Environment

Personal workspace containing various development projects, configurations, and tools.

## 🛠️ Environment Setup

- **OS**: Linux (Fedora 43) - `6.17.9-300.fc43.x86_64`
- **Shell**: Bash with custom configuration
- **Development Tools**: Git, Docker, Kubernetes, AI/ML tooling

## 📂 Key Directories & Projects

### AI/ML & Language Models
- **Claude Code**: `.claude/` - Claude Code CLI configuration and settings
- **LLaMA**: `.llama/` - LLaMA model configurations and cache
- **Ollama**: `.ollama/` - Local LLM management
- **Models**: `models/` - Various AI model files
- **Fine-tuning**: Various fine-tuning job configurations and logs

### Kubernetes & OpenShift
- **OpenShift**: `openshift/` - OpenShift project configurations
- **Kube Config**: `.kube/` - Kubernetes cluster configurations
- **KServe**: `kserve/` - Model serving configurations
- **Ray**: Ray cluster and job YAML files for distributed computing

### Development Projects
- **Pod Virtualization**: `pod-virt/` - Container virtualization work
- **Duplicate Code Detection**: `duplicate-code-detection-tool/` - Code analysis tooling
- **Data Science**: `ds/`, `diab/` - Data science and diabetes-related projects
- **Remoting**: `remoting-linux/` - Remote access and control tools
  - ⚠️ **VMBus approach**: Didn't work due to WSL limitations
  - 🔍 **VSOCK/HYPERVSOCK**: Currently non-functional, still investigating
  - 🔄 **TCP**: Using as temporary solution

### Configuration & Dotfiles
- **RC Config**: `.config/rc_config/` - Shell and tool configurations
- **Git**: `.gitconfig`, `.gitignore` - Git configuration
- **SSH**: `.ssh/` - SSH keys and configuration
- **AWS/Azure**: `.aws/`, `.azure/` - Cloud provider configurations

## 🚀 Notable Tools & Scripts

### AI & ML Utilities
- `llama-stack-local-mcp.py` - Local LLaMA stack MCP integration
- `mcp.py` - Model Control Protocol utilities
- `favorite-color.py` - AI preference learning example
- Various model fine-tuning and deployment scripts

### System & Network Tools
- `cleanup.py`, `cleanup.sh` - System cleanup utilities
- `discover.py` - Network device discovery
- `query_prometheus.py` - Prometheus monitoring queries
- `gen_jwt.py` - JWT token generation

### Kubernetes Utilities
- Multiple YAML configurations for:
  - Ray clusters and jobs
  - PyTorch training jobs
  - Data science pipelines
  - Network attachment definitions
  - Storage configurations

## 📊 Current Projects

### Active Development
- **AI Model Fine-tuning**: Working with various language models
- **Kubernetes Workloads**: Container orchestration and scaling
- **Data Science Pipeline**: Analytics and visualization tools
- **Remote Computing**: Distributed processing setups

### Research Areas
- Model serving and optimization
- Container security and isolation
- Distributed AI training
- Performance monitoring and metrics

## 🔧 Quick Start Commands

```bash
# Check system status
systemctl status

# View running containers
podman ps

# Check Kubernetes clusters
kubectl config get-contexts

# Monitor system resources
top -u $USER
```

## 📝 Notes

- Most configurations are symlinked to `.config/rc_config/` for centralized management
- AI/ML models and cache files are substantial in size
- Multiple cloud provider integrations configured
- Extensive logging and monitoring setup

---

*Last updated: $(date)*
