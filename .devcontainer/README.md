# Dev Container Setup for Geode

This directory contains the configuration for developing Geode using VSCode or Cursor Dev Containers.

## 🎯 Features

The dev container provides:

- **Complete Development Environment**: Zig, Rust, Go, Python, Node.js pre-installed
- **AI Assistant Integration**: Automatic mounting of:
  - GitHub Copilot
  - Claude Desktop
  - Cursor AI
  - Crush
  - OpenCode
- **IDE Support**: Optimized for VSCode and Cursor
- **Service Integration**: Vault, MinIO, Redis automatically started
- **Git Integration**: SSH keys and git config mounted from host
- **Hot Reload**: Source code changes reflected immediately

## 📋 Prerequisites

1. **Docker Desktop** (or Docker Engine + Docker Compose)
   - [Download for Mac](https://www.docker.com/products/docker-desktop)
   - [Download for Windows](https://www.docker.com/products/docker-desktop)
   - [Install on Linux](https://docs.docker.com/engine/install/)

2. **VSCode** with Dev Containers extension (recommended)
   ```bash
   code --install-extension ms-vscode-remote.remote-containers
   ```

   **OR**

3. **Cursor** (VSCode fork with AI)
   - [Download Cursor](https://cursor.sh/)

## 🚀 Quick Start

### Option 1: Using Helper Scripts (Easiest)

```bash
# For VSCode
./.devcontainer/open-vscode.sh

# For Cursor
./.devcontainer/open-cursor.sh
```

### Option 2: Using VSCode Directly

1. Open VSCode
2. Press `Cmd/Ctrl + Shift + P`
3. Select **"Dev Containers: Open Folder in Container"**
4. Navigate to the Geode repository root
5. Wait for the container to build (first time only, ~5-10 minutes)

### Option 3: Using Cursor

1. Open the repository in Cursor:
   ```bash
   cursor .
   ```
2. Press `Cmd/Ctrl + Shift + P`
3. Select **"Dev Containers: Reopen in Container"**
4. Wait for the container to build

### Option 4: Command Line

```bash
# Start the dev container
docker-compose -f docker-compose.dev.yml up -d

# Attach VSCode to running container
code --folder-uri vscode-remote://attached-container+$(docker ps -qf "name=geode-dev")/workspace

# Or open a shell
docker exec -it geode-dev bash
```

## 🔧 Configuration

### AI Assistant Configs Mounted

The following host directories are automatically mounted:

| Tool | Host Path | Container Path |
|------|-----------|----------------|
| VSCode | `~/.vscode` | `/home/$USER/.vscode` |
| VSCode Server | `~/.vscode-server` | `/home/$USER/.vscode-server` |
| Cursor | `~/.cursor` | `/home/$USER/.cursor` |
| Cursor Server | `~/.cursor-server` | `/home/$USER/.cursor-server` |
| Claude Desktop | `~/.config/Claude` | `/home/$USER/.config/Claude` |
| GitHub Copilot | `~/.config/github-copilot` | `/home/$USER/.config/github-copilot` |
| OpenCode | `~/.config/opencode` | `/home/$USER/.config/opencode` |
| Crush | `~/.config/crush` | `/home/$USER/.config/crush` |
| Anthropic | `~/.anthropic` | `/home/$USER/.anthropic` |

**Note**: Directories that don't exist on your host will be created automatically.

### Port Forwarding

The following ports are automatically forwarded:

- **3141**: Geode server
- **8200**: Vault UI
- **9000**: MinIO API
- **9001**: MinIO Console
- **6379**: Redis
- **9090**: Prometheus (if enabled)
- **3000**: Grafana (if enabled)

Access services from your host at `localhost:<port>`.

### Extensions Installed

The dev container automatically installs:

- **Zig Language Support** (`ziglang.vscode-zig`)
- **Rust Analyzer** (`rust-lang.rust-analyzer`)
- **Go** (`golang.go`)
- **Python** (`ms-python.python`, `ms-python.vscode-pylance`)
- **Docker** (`ms-azuretools.vscode-docker`)
- **GitLens** (`eamodio.gitlens`)
- **GitHub Copilot** (`github.copilot`, `github.copilot-chat`)
- **Makefile Tools** (`ms-vscode.makefile-tools`)
- **EditorConfig** (`editorconfig.editorconfig`)

Your host extensions for AI assistants (Cursor AI, Claude, etc.) will also work.

## 🛠️ Development Workflow

### Building Geode

```bash
# Inside the container terminal
zig build                           # Debug build
zig build -Doptimize=ReleaseSafe   # Release build

# Or use aliases
zb                                  # zig build
zbr                                 # zig build -Doptimize=ReleaseSafe
zbt                                 # zig build test
```

### Running Tests

```bash
make test                # Run all tests
make geodetestlab        # Run geodetestlab
zig build test          # Run unit tests
```

### Starting Geode Server

```bash
./zig-out/bin/geode serve --listen 0.0.0.0:3141
```

Then access from host at `http://localhost:3141`.

### Using AI Assistants

All your AI assistants configured on the host will work inside the container:

- **GitHub Copilot**: Just works if you're signed in on host
- **Cursor AI**: Available via Cmd/Ctrl+K
- **Claude Desktop**: If running on host, configs are shared
- **Codeium/Tabnine/etc**: If installed on host

## 🐛 Troubleshooting

### Container Won't Start

```bash
# Check Docker is running
docker info

# Rebuild the container
docker-compose -f docker-compose.dev.yml build --no-cache geode-dev

# Check logs
docker-compose -f docker-compose.dev.yml logs geode-dev
```

### AI Assistant Not Working

1. Ensure the assistant is configured on your **host** machine
2. Check the config directory exists: `ls ~/.config/<assistant-name>`
3. Restart the container: `docker-compose -f docker-compose.dev.yml restart`

### Extensions Not Installing

1. Open Command Palette: `Cmd/Ctrl + Shift + P`
2. Run: **"Dev Containers: Rebuild Container"**
3. Wait for rebuild to complete

### Permission Errors

```bash
# Fix workspace permissions
docker exec -u root geode-dev chown -R $USER:$USER /workspace

# Fix cache permissions
docker exec -u root geode-dev chown -R $USER:$USER /home/$USER/.cache
```

### Can't Access Services

Check port forwarding:
1. Open Command Palette: `Cmd/Ctrl + Shift + P`
2. Run: **"Ports: Focus on Ports View"**
3. Verify ports are forwarded

## 📚 Additional Resources

- [Dev Containers Documentation](https://code.visualstudio.com/docs/devcontainers/containers)
- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [Geode Development Guide](../DOCKER_DEV.md)
- [Geode Quick Start](../QUICKSTART_DOCKER.md)

## 🔄 Updating the Dev Container

When the dev container configuration changes:

```bash
# Option 1: Rebuild in VSCode/Cursor
# Press Cmd/Ctrl + Shift + P → "Dev Containers: Rebuild Container"

# Option 2: Rebuild via command line
docker-compose -f docker-compose.dev.yml build geode-dev
docker-compose -f docker-compose.dev.yml up -d
```

## 💡 Tips

1. **Use integrated terminal**: All tools are pre-configured
2. **Git operations**: Use your host SSH keys automatically
3. **Docker access**: Docker socket is mounted for building images
4. **Multi-root workspaces**: You can add other repos
5. **Extensions sync**: Enable Settings Sync for consistent setup

## 🆘 Getting Help

If you encounter issues:

1. Check this README
2. Review [DOCKER_DEV.md](../DOCKER_DEV.md)
3. Check [troubleshooting section](../DOCKER_DEV_SETUP.md#-troubleshooting)
4. Open an issue on GitHub

---

**Happy coding! 🚀**
