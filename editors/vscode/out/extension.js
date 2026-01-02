"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.activate = activate;
exports.deactivate = deactivate;
const vscode = __importStar(require("vscode"));
const path = __importStar(require("path"));
const cp = __importStar(require("child_process"));
const fs = __importStar(require("fs"));
const node_1 = require("vscode-languageclient/node");
let client;
let statusBarItem;
let outputChannel;
let isConnected = false;
const gqlExtensions = new Set(['.gql', '.gcypher', '.pgql']);
const cypherExtensions = new Set(['.cypher']);
function activate(context) {
    outputChannel = vscode.window.createOutputChannel('Geode GQL');
    context.subscriptions.push(outputChannel);
    // Ensure files with GQL-ish extensions don't get hijacked by SQL/Postgres modes
    // and that the language server activates even when VS Code guesses wrong.
    context.subscriptions.push(vscode.workspace.onDidOpenTextDocument(ensureGeodeLanguageMode));
    vscode.workspace.textDocuments.forEach(ensureGeodeLanguageMode);
    // Create status bar item
    statusBarItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
    statusBarItem.command = 'geode.showDocumentation';
    context.subscriptions.push(statusBarItem);
    updateStatusBar('disconnected');
    // Start LSP if enabled
    const config = vscode.workspace.getConfiguration('geode');
    if (config.get('lsp.enabled', true)) {
        startLanguageServer(context);
    }
    // Register commands
    context.subscriptions.push(vscode.commands.registerCommand('geode.runQuery', runQuery), vscode.commands.registerCommand('geode.runSelection', runSelection), vscode.commands.registerCommand('geode.formatDocument', formatDocument), vscode.commands.registerCommand('geode.connectServer', connectServer), vscode.commands.registerCommand('geode.disconnectServer', disconnectServer), vscode.commands.registerCommand('geode.showDocumentation', showDocumentation), vscode.commands.registerCommand('geode.explainQuery', explainQuery), vscode.commands.registerCommand('geode.restartLsp', () => restartLanguageServer(context)));
    // Auto-connect if configured
    if (config.get('server.autoConnect', false)) {
        connectServer();
    }
    outputChannel.appendLine('Geode GQL extension activated');
}
function deactivate() {
    if (!client) {
        return undefined;
    }
    return client.stop();
}
function ensureGeodeLanguageMode(doc) {
    if (doc.languageId === 'gql' || doc.languageId === 'cypher') {
        return;
    }
    if (doc.uri.scheme !== 'file') {
        return;
    }
    const ext = path.extname(doc.fileName).toLowerCase();
    if (gqlExtensions.has(ext)) {
        void vscode.languages.setTextDocumentLanguage(doc, 'gql').then(() => {
            outputChannel.appendLine(`Switched language mode to Geode GQL for ${path.basename(doc.fileName)}`);
        }, () => {
            // Ignore language switch failures; VS Code may refuse if the document is mid-close.
        });
    }
    else if (cypherExtensions.has(ext)) {
        void vscode.languages.setTextDocumentLanguage(doc, 'cypher').then(() => {
            outputChannel.appendLine(`Switched language mode to Geode Cypher for ${path.basename(doc.fileName)}`);
        }, () => {
            // Ignore language switch failures; VS Code may refuse if the document is mid-close.
        });
    }
}
// ============================================================================
// Language Server
// ============================================================================
function startLanguageServer(context) {
    const config = vscode.workspace.getConfiguration('geode.lsp');
    const serverPath = resolveGeodeBinary(config);
    const serverArgs = config.get('args', ['lsp']);
    // Server options
    const serverOptions = {
        command: serverPath,
        args: serverArgs,
        transport: node_1.TransportKind.stdio
    };
    // Client options
    const clientOptions = {
        documentSelector: [
            { scheme: 'file', language: 'gql' },
            { scheme: 'file', language: 'cypher' },
            { scheme: 'untitled', language: 'gql' },
            { scheme: 'untitled', language: 'cypher' }
        ],
        synchronize: {
            fileEvents: vscode.workspace.createFileSystemWatcher('**/*.{gql,gcypher,cypher,pgql}')
        },
        outputChannel: outputChannel,
        traceOutputChannel: outputChannel
    };
    // Create and start client
    client = new node_1.LanguageClient('geode-gql', 'Geode GQL Language Server', serverOptions, clientOptions);
    client.start().then(() => {
        outputChannel.appendLine('Language server started');
        updateStatusBar('lsp-ready');
    }).catch((error) => {
        outputChannel.appendLine(`Failed to start language server: ${error}`);
        vscode.window.showWarningMessage('Geode LSP failed to start. Make sure "geode" is in your PATH.', 'Show Output').then(choice => {
            if (choice === 'Show Output') {
                outputChannel.show();
            }
        });
    });
}
function resolveGeodeBinary(config) {
    const configured = config.get('path', 'geode');
    const workspaceFolders = vscode.workspace.workspaceFolders ?? [];
    const candidates = [];
    const addCandidate = (candidate) => {
        if (candidate && !candidates.includes(candidate)) {
            candidates.push(candidate);
        }
    };
    if (configured) {
        if (path.isAbsolute(configured)) {
            addCandidate(configured);
        }
        else {
            addCandidate(configured); // rely on PATH or workspace-relative lookup
            for (const folder of workspaceFolders) {
                addCandidate(path.join(folder.uri.fsPath, configured));
            }
        }
    }
    for (const folder of workspaceFolders) {
        addCandidate(path.join(folder.uri.fsPath, 'zig-out', 'bin', 'geode'));
        addCandidate(path.join(folder.uri.fsPath, 'dist', 'bin', 'geode'));
    }
    for (const candidate of candidates) {
        if (fs.existsSync(candidate)) {
            outputChannel.appendLine(`Using Geode binary at ${candidate}`);
            return candidate;
        }
    }
    const pathBinary = findInPath(configured || 'geode');
    if (pathBinary) {
        outputChannel.appendLine(`Using Geode binary from PATH at ${pathBinary}`);
        return pathBinary;
    }
    outputChannel.appendLine(`Geode binary not found at configured path (${configured}); falling back to ${configured || 'geode'} and relying on PATH.`);
    return configured || 'geode';
}
function findInPath(binary) {
    const searchTargets = process.platform === 'win32' && !binary.endsWith('.exe')
        ? [binary, `${binary}.exe`]
        : [binary];
    const parts = (process.env.PATH || '').split(path.delimiter);
    for (const dir of parts) {
        for (const target of searchTargets) {
            const candidate = path.join(dir, target);
            if (fs.existsSync(candidate)) {
                return candidate;
            }
        }
    }
    return undefined;
}
async function restartLanguageServer(context) {
    if (client) {
        await client.stop();
        client = undefined;
    }
    startLanguageServer(context);
    vscode.window.showInformationMessage('Geode Language Server restarted');
}
// ============================================================================
// Query Execution
// ============================================================================
async function runQuery() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
        vscode.window.showWarningMessage('No active editor');
        return;
    }
    const query = editor.document.getText();
    await executeQuery(query);
}
async function runSelection() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
        vscode.window.showWarningMessage('No active editor');
        return;
    }
    const selection = editor.selection;
    const query = editor.document.getText(selection);
    if (!query.trim()) {
        vscode.window.showWarningMessage('No text selected');
        return;
    }
    await executeQuery(query);
}
async function executeQuery(query) {
    const config = vscode.workspace.getConfiguration('geode');
    const host = config.get('server.host', 'localhost');
    const port = config.get('server.port', 3141);
    const timeout = config.get('query.timeout', 30000);
    outputChannel.appendLine(`\n--- Executing Query ---`);
    outputChannel.appendLine(query);
    outputChannel.appendLine('---');
    try {
        const result = await runGeodeQuery(query, host, port, timeout);
        showQueryResults(result);
    }
    catch (error) {
        outputChannel.appendLine(`Error: ${error}`);
        vscode.window.showErrorMessage(`Query failed: ${error}`);
    }
}
function runGeodeQuery(query, host, port, timeout) {
    return new Promise((resolve, reject) => {
        const geodeCmd = resolveGeodeBinary(vscode.workspace.getConfiguration('geode.lsp'));
        const args = ['query', '--server', `${host}:${port}`, '--format', 'json', query];
        const process = cp.spawn(geodeCmd, args, {
            timeout: timeout
        });
        let stdout = '';
        let stderr = '';
        process.stdout.on('data', (data) => {
            stdout += data.toString();
        });
        process.stderr.on('data', (data) => {
            stderr += data.toString();
        });
        process.on('close', (code) => {
            if (code === 0) {
                resolve(stdout);
            }
            else {
                reject(stderr || `Process exited with code ${code}`);
            }
        });
        process.on('error', (err) => {
            reject(err.message);
        });
    });
}
function showQueryResults(result) {
    const config = vscode.workspace.getConfiguration('geode');
    const maxResults = config.get('query.maxResults', 1000);
    outputChannel.appendLine('Results:');
    outputChannel.appendLine(result);
    outputChannel.show();
    // Also show in a webview panel for better visualization
    try {
        const data = JSON.parse(result);
        if (Array.isArray(data) && data.length > 0) {
            vscode.window.showInformationMessage(`Query returned ${data.length} result(s). See Output panel for details.`);
        }
    }
    catch {
        // Not JSON, just show in output
    }
}
async function explainQuery() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
        vscode.window.showWarningMessage('No active editor');
        return;
    }
    const selection = editor.selection;
    const query = selection.isEmpty
        ? editor.document.getText()
        : editor.document.getText(selection);
    const config = vscode.workspace.getConfiguration('geode');
    const host = config.get('server.host', 'localhost');
    const port = config.get('server.port', 3141);
    outputChannel.appendLine(`\n--- Query Plan ---`);
    outputChannel.appendLine(query);
    outputChannel.appendLine('---');
    try {
        const result = await runGeodeQuery(`EXPLAIN ${query}`, host, port, 30000);
        outputChannel.appendLine(result);
        outputChannel.show();
    }
    catch (error) {
        outputChannel.appendLine(`Error: ${error}`);
        vscode.window.showErrorMessage(`EXPLAIN failed: ${error}`);
    }
}
// ============================================================================
// Server Connection
// ============================================================================
async function connectServer() {
    const config = vscode.workspace.getConfiguration('geode');
    const host = config.get('server.host', 'localhost');
    const port = config.get('server.port', 3141);
    outputChannel.appendLine(`Connecting to ${host}:${port}...`);
    updateStatusBar('connecting');
    try {
        // Test connection with a simple query
        await runGeodeQuery('RETURN 1', host, port, 5000);
        isConnected = true;
        updateStatusBar('connected');
        vscode.window.showInformationMessage(`Connected to Geode server at ${host}:${port}`);
    }
    catch (error) {
        isConnected = false;
        updateStatusBar('disconnected');
        vscode.window.showErrorMessage(`Failed to connect: ${error}`);
    }
}
function disconnectServer() {
    isConnected = false;
    updateStatusBar('disconnected');
    vscode.window.showInformationMessage('Disconnected from Geode server');
}
// ============================================================================
// Formatting
// ============================================================================
async function formatDocument() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
        return;
    }
    // Use LSP formatting if available
    if (client) {
        await vscode.commands.executeCommand('editor.action.formatDocument');
    }
    else {
        vscode.window.showWarningMessage('LSP not available for formatting');
    }
}
// ============================================================================
// Documentation
// ============================================================================
function showDocumentation() {
    const panel = vscode.window.createWebviewPanel('geodeDocumentation', 'GQL Documentation', vscode.ViewColumn.Two, { enableScripts: true });
    panel.webview.html = getDocumentationHtml();
}
function getDocumentationHtml() {
    return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>GQL Documentation</title>
    <style>
        body { font-family: var(--vscode-font-family); padding: 20px; }
        h1, h2, h3 { color: var(--vscode-foreground); }
        code { background: var(--vscode-textCodeBlock-background); padding: 2px 6px; border-radius: 3px; }
        pre { background: var(--vscode-textCodeBlock-background); padding: 10px; overflow-x: auto; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid var(--vscode-panel-border); padding: 8px; text-align: left; }
        th { background: var(--vscode-editor-background); }
    </style>
</head>
<body>
    <h1>GQL Quick Reference</h1>

    <h2>Query Clauses</h2>
    <table>
        <tr><th>Clause</th><th>Description</th><th>Example</th></tr>
        <tr><td><code>MATCH</code></td><td>Find patterns in the graph</td><td><code>MATCH (n:Person)</code></td></tr>
        <tr><td><code>WHERE</code></td><td>Filter results</td><td><code>WHERE n.age > 25</code></td></tr>
        <tr><td><code>RETURN</code></td><td>Specify output</td><td><code>RETURN n.name</code></td></tr>
        <tr><td><code>CREATE</code></td><td>Create nodes/edges</td><td><code>CREATE (n:Person {name: 'Alice'})</code></td></tr>
        <tr><td><code>MERGE</code></td><td>Create if not exists</td><td><code>MERGE (n:Person {email: 'a@b.com'})</code></td></tr>
        <tr><td><code>DELETE</code></td><td>Delete nodes/edges</td><td><code>DELETE n</code></td></tr>
    </table>

    <h2>Aggregation Functions</h2>
    <table>
        <tr><th>Function</th><th>Description</th></tr>
        <tr><td><code>count()</code></td><td>Count items</td></tr>
        <tr><td><code>sum()</code></td><td>Sum numeric values</td></tr>
        <tr><td><code>avg()</code></td><td>Average of values</td></tr>
        <tr><td><code>min()</code> / <code>max()</code></td><td>Min/max value</td></tr>
        <tr><td><code>collect()</code></td><td>Collect into list</td></tr>
    </table>

    <h2>Vector Functions (Geode-specific)</h2>
    <table>
        <tr><th>Function</th><th>Description</th></tr>
        <tr><td><code>distance(v1, v2, metric)</code></td><td>Calculate distance (L2, cosine, etc.)</td></tr>
        <tr><td><code>similarity(v1, v2)</code></td><td>Cosine similarity</td></tr>
    </table>

    <h2>Keyboard Shortcuts</h2>
    <table>
        <tr><th>Action</th><th>Windows/Linux</th><th>macOS</th></tr>
        <tr><td>Run Query</td><td><code>Ctrl+Enter</code></td><td><code>Cmd+Enter</code></td></tr>
        <tr><td>Run Selection</td><td><code>Ctrl+Shift+Enter</code></td><td><code>Cmd+Shift+Enter</code></td></tr>
        <tr><td>Format Document</td><td><code>Shift+Alt+F</code></td><td><code>Shift+Option+F</code></td></tr>
    </table>

    <h2>Links</h2>
    <ul>
        <li><a href="https://github.com/geode-db/geode">Geode GitHub Repository</a></li>
        <li><a href="https://www.iso.org/standard/76120.html">ISO/IEC 39075 GQL Standard</a></li>
    </ul>
</body>
</html>`;
}
// ============================================================================
// Status Bar
// ============================================================================
function updateStatusBar(status) {
    switch (status) {
        case 'disconnected':
            statusBarItem.text = '$(database) Geode';
            statusBarItem.tooltip = 'Geode GQL - Click to view documentation';
            statusBarItem.backgroundColor = undefined;
            break;
        case 'connecting':
            statusBarItem.text = '$(sync~spin) Geode';
            statusBarItem.tooltip = 'Connecting to Geode server...';
            break;
        case 'connected':
            statusBarItem.text = '$(database) Geode $(check)';
            statusBarItem.tooltip = 'Connected to Geode server';
            statusBarItem.backgroundColor = new vscode.ThemeColor('statusBarItem.prominentBackground');
            break;
        case 'lsp-ready':
            statusBarItem.text = '$(database) Geode LSP';
            statusBarItem.tooltip = 'Geode Language Server active';
            break;
    }
    statusBarItem.show();
}
//# sourceMappingURL=extension.js.map