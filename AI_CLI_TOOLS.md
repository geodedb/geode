# AI CLI Tools Guide

This guide covers using AI assistant command-line tools in the Geode development environment.

## 🤖 Available AI CLI Tools

The development container includes four AI CLI tools:

1. **GitHub Copilot CLI** (`copilot`) - Code suggestions and explanations (standalone tool)
2. **Claude Code CLI** (`claude`) - Anthropic's official CLI for coding assistance
3. **Cursor Agent CLI** (`cursor-agent`) - Cursor's command-line agent
4. **Aider** (`aider`) - AI pair programming tool

All CLI tools have their sessions and configurations automatically mounted from your host system.

## 📦 Installation Status

These tools are installed during the Docker image build:

- ✅ **GitHub Copilot CLI** - Installed via `npm install -g @github/copilot`
- ✅ **Claude Code CLI** - Installed via `npm install -g @anthropic-ai/claude-code`
- ✅ **Cursor Agent CLI** - Installed via `curl https://cursor.com/install -fsSL | bash`
- ✅ **Aider** - Installed via pip (`aider-chat`)

## 🔑 Authentication & Setup

### GitHub Copilot CLI

**Prerequisites**: You must have GitHub Copilot subscription.

**First-time setup**:

```bash
# Run copilot - it will guide you through authentication
copilot

# Follow the prompts to authenticate with GitHub
# This will open a browser for GitHub OAuth flow
```

Your authentication will be stored in `~/.config/github-copilot/` which is mounted from your host, so you only need to authenticate once.

**Note**: The Copilot CLI is now a standalone tool (`copilot` command), not a `gh` extension.

### Claude Code CLI

**Setup**:

```bash
# Navigate to your project directory and run
claude

# On first run, it will prompt for authentication
# You'll need an Anthropic API key from https://console.anthropic.com/

# Optionally, set API key in environment
export ANTHROPIC_API_KEY="your-api-key-here"
# Add to ~/.bashrc to make permanent
```

Configuration is stored in `~/.anthropic/` which is mounted from your host.

**Alternative**: Use Aider with Claude:

```bash
# Aider also supports Claude models
aider --model claude-3-5-sonnet-20241022
```

### Cursor Agent CLI

**Setup**:

```bash
# Run cursor-agent - it will guide you through setup
cursor-agent

# Configuration will be stored automatically
```

Configuration is stored in `~/.config/cursor/` which is mounted from your host.

### Aider

**Setup**:

```bash
# Configure your API key (choose one):
export ANTHROPIC_API_KEY="your-key"        # For Claude
export OPENAI_API_KEY="your-key"           # For GPT-4
export OPENROUTER_API_KEY="your-key"       # For OpenRouter

# Or add to ~/.bashrc for persistence
echo 'export ANTHROPIC_API_KEY="your-key"' >> ~/.bashrc
```

Configuration is stored in `~/.aider/` which is mounted from your host.

## 💻 Usage Examples

### GitHub Copilot CLI

#### Interactive Mode (Recommended)

```bash
# Start interactive Copilot session
copilot

# Copilot will guide you through:
# - Code explanations
# - Command suggestions
# - Code generation
# - Debugging assistance
```

#### Direct Commands

```bash
# Ask for coding help
copilot "write a function to parse JSON in Zig"

# Get command suggestions
copilot "find all zig files modified in last week"

# Explain code or commands
copilot "explain: docker-compose up -d"
```

**Note**: The new Copilot CLI provides an interactive chat interface. Simply run `copilot` to start.

### Claude Code CLI

```bash
# Start Claude Code in your project directory
cd /workspace
claude

# Claude Code provides:
# - Agentic coding assistance
# - Codebase understanding
# - Git workflow integration
# - Natural language commands
# - Automatic task execution

# Report bugs
claude /bug

# Use plugins (if available)
claude --help
```

### Cursor Agent CLI

```bash
# Start Cursor agent
cursor-agent

# The agent provides CLI-based assistance similar to Cursor IDE
# Follow interactive prompts for code generation and assistance
```

### Aider - AI Pair Programming

Aider is a powerful AI pair programming tool that can directly edit your code.

#### Basic Usage

```bash
# Start aider in current directory
aider

# Start with specific files
aider src/main.zig src/parser.zig

# Use Claude instead of GPT-4
aider --model claude-3-5-sonnet-20241022

# Use GPT-4
aider --model gpt-4-turbo-preview
```

#### Interactive Commands (inside Aider)

```
# In aider session:
/add src/newfile.zig      # Add file to chat
/drop src/oldfile.zig     # Remove file from chat
/help                      # Show all commands
/diff                      # Show pending changes
/commit                    # Commit changes with AI-generated message
/undo                      # Undo last change
/exit                      # Exit aider
```

#### Example Workflow

```bash
# Start aider with your files
aider src/storage.zig src/types.zig

# Inside aider, give instructions:
> Add error handling to the readFile function
> Refactor the Storage struct to use a HashMap instead of ArrayList
> Add unit tests for the parseQuery function

# Review changes
/diff

# Commit if happy
/commit

# Or undo if not
/undo
```

#### Advanced Aider Options

```bash
# Architect mode (better for large refactors)
aider --architect

# Auto-commit changes
aider --auto-commits

# Specify model and creativity
aider --model claude-3-5-sonnet-20241022 --creativity 0.7

# Read-only mode (no file edits)
aider --read

# Use with specific repository
aider --git-root /workspace
```

### Claude CLI (if available)

```bash
# Interactive chat
claude chat

# One-shot question
claude ask "What's the best way to implement MVCC in Zig?"

# With context from a file
claude ask "Review this code:" < src/main.zig
```

## 🔧 Configuration Files

All configuration files are mounted from your host system:

### GitHub Copilot CLI

- **Location**: `~/.config/github-copilot/`
- **Files**: Authentication tokens, settings
- **Mounted**: ✅ Yes (cached)

### Claude Code CLI

- **Location**: `~/.anthropic/`
- **Files**: API keys, settings, session data
- **Mounted**: ✅ Yes (cached)

### Cursor Agent CLI

- **Location**: `~/.config/cursor/`
- **Files**: Configuration, authentication
- **Mounted**: ✅ Yes (cached)

### Aider

- **Location**: `~/.aider/` and `~/.config/aider/`
- **Files**: Chat history, model preferences, API keys
- **Mounted**: ✅ Yes (cached)

## 🎯 Best Practices

### 1. Use the Right Tool for the Job

- **Interactive coding help**: `copilot` (GitHub Copilot CLI)
- **Agentic coding tasks**: `claude` (Claude Code CLI)
- **Cursor-style assistance**: `cursor-agent`
- **Direct code editing**: `aider`
- **Complex refactoring**: `aider --architect`

### 2. Provide Context

```bash
# Good: Specific context
copilot "create a Zig function that parses GQL query syntax"

# Better: Use Claude Code for agentic tasks
cd /workspace && claude
> Create a parser for ISO GQL SELECT statements in Zig 0.15.1

# Best: Direct code editing with context
cd src/gql/ && aider parser.zig lexer.zig
> Implement support for UNION queries
```

### 3. Iterate with Aider

```bash
# Start broad
aider src/feature.zig
> Add basic implementation of feature X

# Then refine
> Add error handling
> Add tests
> Optimize for performance
```

### 4. Use Models Appropriately

```bash
# For complex refactoring
aider --model claude-3-5-sonnet-20241022 --architect

# For quick edits
aider --model gpt-3.5-turbo  # Faster, cheaper

# For high-stakes code
aider --model gpt-4-turbo-preview  # Most capable
```

## 🔒 Security Considerations

### API Keys

**Store API keys securely**:

```bash
# In container's .bashrc
echo 'export ANTHROPIC_API_KEY="sk-..."' >> ~/.bashrc

# Or use host's environment (recommended)
# Add to host's ~/.bashrc or ~/.zshrc, it will be available in container
```

**Never commit API keys**:
- Don't add API keys to files that get committed
- Use environment variables
- The `.anthropic/` directory is already gitignored

### Review AI-Generated Code

**Always review changes**:

```bash
# In aider, always check diff before committing
/diff

# Test AI-generated code
zig build test

# Use version control
git diff
```

## 🐛 Troubleshooting

### GitHub Copilot CLI Not Working

```bash
# Try running copilot - it will guide you through auth
copilot

# If authentication fails, check npm installation
npm list -g @github/copilot

# Reinstall if needed
npm install -g @github/copilot

# Check Node.js version (requires v22+)
node --version
```

### Aider Can't Find API Key

```bash
# Set environment variable
export ANTHROPIC_API_KEY="your-key"

# Check it's set
echo $ANTHROPIC_API_KEY

# Make permanent
echo 'export ANTHROPIC_API_KEY="your-key"' >> ~/.bashrc
source ~/.bashrc
```

### Aider Won't Edit Files

```bash
# Check git status
git status

# Aider needs a clean git repository
git add .
git commit -m "Before aider session"

# Then run aider
aider src/file.zig
```

### Claude Code CLI Not Working

```bash
# Check installation
claude --version

# Reinstall if needed
npm install -g @anthropic-ai/claude-code

# Set API key
export ANTHROPIC_API_KEY="your-key-here"
echo 'export ANTHROPIC_API_KEY="your-key"' >> ~/.bashrc

# Alternative: Use Aider with Claude
aider --model claude-3-5-sonnet-20241022
```

## 📚 Additional Resources

### GitHub Copilot CLI

- [Official Documentation](https://docs.github.com/en/copilot/github-copilot-in-the-cli)
- [npm Package](https://www.npmjs.com/package/@github/copilot)
- Run: `copilot --help`

### Claude Code CLI

- [Official Documentation](https://docs.anthropic.com/en/docs/claude-code/overview)
- [npm Package](https://www.npmjs.com/package/@anthropic-ai/claude-code)
- [GitHub Repository](https://github.com/anthropics/claude-code)
- Run: `claude --help`

### Cursor Agent CLI

- [Cursor Documentation](https://cursor.sh/docs)
- Installation: `curl https://cursor.com/install -fsSL | bash`
- Run: `cursor-agent --help`

### Aider

- [Official Documentation](https://aider.chat/)
- [GitHub Repository](https://github.com/paul-gauthier/aider)
- Run: `aider --help`

## 💡 Example Workflows

### Workflow 1: Add a New Feature

```bash
# 1. Use Claude Code for agentic task
cd /workspace
claude
> Implement vector similarity search in Zig with HNSW index
> Create src/vector_search.zig and add tests

# 2. Review the changes
git diff

# 3. Refine with Aider if needed
aider src/vector_search.zig src/types.zig
> Optimize the distance calculation
/commit

# 4. Or use Copilot for quick suggestions
copilot "optimize this HNSW implementation"
```

### Workflow 2: Debug an Issue

```bash
# 1. Use Copilot to understand the issue
copilot "explain this code: $(cat src/problematic.zig)"

# 2. Use Claude Code for comprehensive fix
claude
> Fix the memory leak in src/problematic.zig parseQuery function
> Run tests to verify the fix

# 3. Or use Aider for direct code editing
aider src/problematic.zig
> Fix the memory leak identified in the parseQuery function
```

### Workflow 3: Refactor Codebase

```bash
# 1. Use Claude Code for planning and execution
claude
> Review the storage layer and refactor to improve performance
> Ensure all tests still pass after refactoring

# 2. Or use Aider architect mode for planning
aider --architect --model claude-3-5-sonnet-20241022
> Review the storage layer and suggest refactoring to improve performance

# 3. Implement with Aider
aider src/storage/*.zig
> Implement the suggested refactoring
/diff
/commit

# 4. Verify
make test
```

---

**Happy AI-assisted coding! 🤖✨**
