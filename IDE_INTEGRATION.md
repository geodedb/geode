# IDE and AI Assistant Integration

This document describes the complete VSCode, Cursor, and AI assistant integration for the Geode development environment.

## 🎯 Overview

The Geode Docker development environment now supports:

- **VSCode Dev Containers** - Full IDE integration with all tools pre-installed
- **Cursor IDE** - VSCode fork with native AI capabilities
- **AI Assistants** - Automatic mounting and configuration of:
  - GitHub Copilot
  - Claude Desktop
  - Cursor AI
  - Crush
  - OpenCode
  - Any other AI tools you have configured

## 📦 What's Included

### Automatically Mounted Configurations

When you open the project in a dev container, the following host directories are automatically mounted:

| Tool/Config | Host Path | Container Path | Purpose |
|-------------|-----------|----------------|---------|
| VSCode Settings | `~/.vscode` | `/home/$USER/.vscode` | VSCode user settings |
| VSCode Server | `~/.vscode-server` | `/home/$USER/.vscode-server` | VSCode server components |
| Cursor Settings | `~/.cursor` | `/home/$USER/.cursor` | Cursor user settings |
| Cursor Server | `~/.cursor-server` | `/home/$USER/.cursor-server` | Cursor server components |
| VS Code Config | `~/.config/Code` | `/home/$USER/.config/Code` | VSCode application config |
| Cursor Config | `~/.config/Cursor` | `/home/$USER/.config/Cursor` | Cursor application config |
| Claude Desktop | `~/.config/Claude` | `/home/$USER/.config/Claude` | Claude Desktop settings |
| GitHub Copilot | `~/.config/github-copilot` | `/home/$USER/.config/github-copilot` | Copilot authentication |
| OpenCode | `~/.config/opencode` | `/home/$USER/.config/opencode` | OpenCode settings |
| Crush | `~/.config/crush` | `/home/$USER/.config/crush` | Crush settings |
| Anthropic API | `~/.anthropic` | `/home/$USER/.anthropic` | Anthropic API keys |
| SSH Keys | `~/.ssh` | `/home/$USER/.ssh` | Git authentication (read-only) |
| Git Config | `~/.gitconfig` | `/home/$USER/.gitconfig` | Git user config (read-only) |

**Note**: Directories that don't exist on your host system will be created automatically when the container starts.

### Pre-installed Extensions

The dev container automatically installs:

- **Zig Language Support** (`ziglang.vscode-zig`)
- **Rust Analyzer** (`rust-lang.rust-analyzer`)
- **LLDB Debugger** (`vadimcn.vscode-lldb`)
- **Go** (`golang.go`)
- **Python** (`ms-python.python`, `ms-python.vscode-pylance`)
- **Docker** (`ms-azuretools.vscode-docker`)
- **GitLens** (`eamodio.gitlens`)
- **GitHub Copilot** (`github.copilot`, `github.copilot-chat`)
- **Makefile Tools** (`ms-vscode.makefile-tools`)
- **EditorConfig** (`editorconfig.editorconfig`)
- **YAML Support** (`redhat.vscode-yaml`)
- **TOML Support** (`tamasfe.even-better-toml`)

## 🚀 Quick Start

### Method 1: Using Helper Scripts (Recommended)

The easiest way to get started:

```bash
# For VSCode
./dev.sh vscode

# For Cursor
./dev.sh cursor
```

### Method 2: Open in VSCode

1. Install the Dev Containers extension:
   ```bash
   code --install-extension ms-vscode-remote.remote-containers
   ```

2. Open VSCode and press `Cmd/Ctrl + Shift + P`

3. Select **"Dev Containers: Open Folder in Container"**

4. Navigate to the Geode repository root

5. Wait for the container to build (first time: ~10-15 minutes)

### Method 3: Open in Cursor

1. Open the repository:
   ```bash
   cursor .
   ```

2. Press `Cmd/Ctrl + Shift + P`

3. Select **"Dev Containers: Reopen in Container"**

4. Wait for the container to build

### Method 4: Command Line

```bash
# Start the dev environment
docker-compose -f docker-compose.dev.yml up -d

# Attach VSCode to running container
code --folder-uri vscode-remote://attached-container+$(docker ps -qf "name=geode-dev")/workspace
```

## 🔧 Configuration Files

### Created Files

The following files have been added to support IDE integration:

```
.devcontainer/
├── devcontainer.json       # Dev container configuration
├── open-vscode.sh         # VSCode launcher script (executable)
├── open-cursor.sh         # Cursor launcher script (executable)
└── README.md              # Dev container documentation

.vscode/
├── settings.json          # Workspace settings
└── extensions.json        # Recommended extensions
```

### Modified Files

- **docker-compose.dev.yml** - Added volume mounts for IDE and AI configs
- **.gitignore** - Updated to keep workspace settings but ignore user files
- **dev.sh** - Added `vscode` and `cursor` commands

## 💻 Development Workflow

### Using AI Assistants

All AI assistants configured on your host machine work seamlessly inside the container:

#### GitHub Copilot

1. Sign in to Copilot on your **host machine**
2. Open the project in dev container
3. Copilot works automatically - no additional setup needed
4. Use `Tab` to accept suggestions or `Cmd/Ctrl+Enter` for inline chat

#### Cursor AI

1. Configure Cursor AI on your host machine
2. Open in dev container: `./dev.sh cursor`
3. Use `Cmd/Ctrl+K` for AI chat
4. Use `Cmd/Ctrl+L` for inline suggestions

#### Claude Desktop

If running Claude Desktop on your host:
1. Configs are automatically shared with the container
2. API keys from `~/.anthropic` are mounted
3. Use Cursor or VSCode extensions that integrate with Claude

### Building and Testing

Inside the container:

```bash
# Build Geode
zig build                           # Debug build
zig build -Doptimize=ReleaseSafe   # Release build

# Or use aliases (pre-configured in container)
zb                                  # zig build
zbr                                 # zig build -Doptimize=ReleaseSafe
zbt                                 # zig build test

# Run tests
make test                           # All tests
make geodetestlab                   # Geodetestlab tests
zig build test                      # Unit tests

# Start server
./zig-out/bin/geode serve --listen 0.0.0.0:3141
```

### Accessing Services

Services are automatically forwarded to your host:

- **Geode Server**: http://localhost:3141
- **Vault UI**: http://localhost:8200
- **MinIO Console**: http://localhost:9001
- **MinIO API**: http://localhost:9000
- **Redis**: localhost:6379
- **Prometheus**: http://localhost:9090 (if monitoring enabled)
- **Grafana**: http://localhost:3000 (if monitoring enabled)

View and manage port forwarding:
1. Press `Cmd/Ctrl + Shift + P`
2. Select **"Ports: Focus on Ports View"**

## 🐛 Troubleshooting

### AI Assistant Not Working

**Issue**: Copilot/Claude/Cursor AI not functioning

**Solution**:
1. Ensure the assistant is configured on your **host** machine first
2. Check the config directory exists: `ls ~/.config/<assistant-name>`
3. Restart the container:
   ```bash
   docker-compose -f docker-compose.dev.yml restart geode-dev
   ```
4. For Copilot, ensure you're signed in on the host

### Extensions Not Installing

**Issue**: Recommended extensions aren't installed

**Solution**:
1. Open Command Palette: `Cmd/Ctrl + Shift + P`
2. Run: **"Dev Containers: Rebuild Container"**
3. Wait for rebuild to complete (~10-15 minutes)

### Container Won't Start

**Issue**: Dev container fails to start

**Solution**:
```bash
# Check Docker is running
docker info

# Rebuild the container
docker-compose -f docker-compose.dev.yml build --no-cache geode-dev

# Check logs
docker-compose -f docker-compose.dev.yml logs geode-dev

# Ensure no containers are conflicting
docker ps -a
docker-compose -f docker-compose.dev.yml down
```

### Permission Errors

**Issue**: Can't write to workspace or cache directories

**Solution**:
```bash
# Fix workspace permissions
docker exec -u root geode-dev chown -R $USER:$USER /workspace

# Fix cache permissions
docker exec -u root geode-dev chown -R $USER:$USER /home/$USER/.cache

# Or rebuild with correct UID/GID
echo "USER_UID=$(id -u)" > .env
echo "USER_GID=$(id -g)" >> .env
docker-compose -f docker-compose.dev.yml up -d --build
```

### Config Directories Not Mounting

**Issue**: AI assistant configs not accessible in container

**Solution**:
```bash
# Check if directories exist on host
ls -la ~/.config/github-copilot
ls -la ~/.config/Claude

# Create missing directories
mkdir -p ~/.config/github-copilot
mkdir -p ~/.config/Claude
mkdir -p ~/.anthropic

# Restart container
docker-compose -f docker-compose.dev.yml restart geode-dev
```

## 📚 Additional Features

### Integrated Terminal

The container's bash shell is pre-configured with:

- **Aliases**: `zb`, `zbr`, `zbt`, `ll`
- **Colored prompt**: Shows you're in the Geode dev container
- **Tool paths**: All development tools in PATH
- **Git integration**: SSH keys and config mounted
- **Welcome message**: Displays available tools on login

### Docker-in-Docker

The Docker socket is mounted, allowing you to:

- Build Docker images from within the container
- Run docker-compose commands
- Manage containers on your host
- Test deployment configurations

**Example**:
```bash
# Inside the container
docker ps                    # See host containers
docker build -t test .       # Build images
docker-compose up -d         # Run compose files
```

### Multi-Root Workspaces

You can add other repositories to your workspace:

1. In VSCode/Cursor: File → Add Folder to Workspace
2. Navigate to another project directory
3. All folders open in the same container
4. Useful for working on client libraries alongside Geode

## 🔄 Updating Configuration

When dev container configuration changes:

### Option 1: Rebuild in IDE

1. Press `Cmd/Ctrl + Shift + P`
2. Select **"Dev Containers: Rebuild Container"**
3. Wait for rebuild (~10-15 minutes)

### Option 2: Command Line Rebuild

```bash
# Stop and remove current container
docker-compose -f docker-compose.dev.yml down

# Rebuild from scratch
docker-compose -f docker-compose.dev.yml build --no-cache geode-dev

# Start fresh container
docker-compose -f docker-compose.dev.yml up -d

# Or use helper script
./dev.sh rebuild
```

## 💡 Tips and Best Practices

### 1. Use Workspace Settings

The `.vscode/settings.json` file contains project-specific settings:
- Language-specific formatting
- File associations
- Build configurations

These settings apply to all team members using the dev container.

### 2. Sync Your Extensions

Enable VSCode Settings Sync to maintain your personal extensions across machines:
1. Sign in with GitHub/Microsoft account
2. Settings Sync will include extensions not in the container
3. Container extensions install automatically

### 3. Customize Your Shell

Add personal aliases to `~/.bashrc` inside the container:
```bash
# Inside container
echo 'alias myalias="my command"' >> ~/.bashrc
source ~/.bashrc
```

Note: These changes persist in the Docker volume.

### 4. Use Git from Host

For complex Git operations, use your host terminal:
- Host has your full Git configuration
- Signing commits works out of the box
- Git GUIs (GitKraken, Tower) see your changes

For simple operations, use the container terminal.

### 5. Monitor Resource Usage

Keep an eye on Docker resource usage:
```bash
# On host
docker stats geode-dev

# Check disk usage
docker system df
```

## 🆘 Getting Help

If you encounter issues:

1. Check this document's Troubleshooting section
2. Review [.devcontainer/README.md](.devcontainer/README.md)
3. Check [DOCKER_DEV_SETUP.md](DOCKER_DEV_SETUP.md)
4. Open an issue on GitHub with:
   - Your OS and Docker version
   - IDE version (VSCode/Cursor)
   - Error messages
   - Output of `docker logs geode-dev`

## 📖 Further Reading

- [Dev Containers Documentation](https://code.visualstudio.com/docs/devcontainers/containers)
- [Cursor Documentation](https://cursor.sh/docs)
- [GitHub Copilot Docs](https://docs.github.com/en/copilot)
- [Geode Development Guide](DOCKER_DEV.md)
- [Geode Quick Start](QUICKSTART_DOCKER.md)

---

**Happy coding with AI assistance! 🤖🚀**
