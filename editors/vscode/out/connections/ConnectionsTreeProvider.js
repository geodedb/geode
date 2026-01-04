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
exports.ConnectionsTreeProvider = exports.ConnectionTreeItem = void 0;
exports.registerConnectionsView = registerConnectionsView;
const vscode = __importStar(require("vscode"));
/**
 * Tree item representing a connection in the sidebar
 */
class ConnectionTreeItem extends vscode.TreeItem {
    constructor(profile, isActive, isConnected) {
        super(profile.name, vscode.TreeItemCollapsibleState.None);
        this.profile = profile;
        this.isActive = isActive;
        this.isConnected = isConnected;
        this.id = profile.id;
        this.description = `${profile.host}:${profile.port}`;
        this.tooltip = this.buildTooltip();
        this.contextValue = this.buildContextValue();
        this.iconPath = this.getIcon();
        // Click to connect
        this.command = {
            command: 'geode.connections.connect',
            title: 'Connect',
            arguments: [profile.id]
        };
    }
    buildTooltip() {
        const lines = [
            `Name: ${this.profile.name}`,
            `Host: ${this.profile.host}:${this.profile.port}`
        ];
        if (this.profile.database) {
            lines.push(`Database: ${this.profile.database}`);
        }
        if (this.profile.username) {
            lines.push(`User: ${this.profile.username}`);
        }
        lines.push(`TLS: ${this.profile.useTls ? 'Yes' : 'No'}`);
        if (this.profile.isDefault) {
            lines.push('(Default Connection)');
        }
        if (this.isConnected) {
            lines.push('Status: Connected');
        }
        return lines.join('\n');
    }
    buildContextValue() {
        const parts = ['connection'];
        if (this.isActive) {
            parts.push('active');
        }
        if (this.isConnected) {
            parts.push('connected');
        }
        if (this.profile.isDefault) {
            parts.push('default');
        }
        return parts.join('-');
    }
    getIcon() {
        if (this.isConnected) {
            return new vscode.ThemeIcon('database', new vscode.ThemeColor('charts.green'));
        }
        else if (this.isActive) {
            return new vscode.ThemeIcon('database', new vscode.ThemeColor('charts.yellow'));
        }
        else {
            return new vscode.ThemeIcon('database');
        }
    }
}
exports.ConnectionTreeItem = ConnectionTreeItem;
/**
 * "Add Connection" tree item
 */
class AddConnectionItem extends vscode.TreeItem {
    constructor() {
        super('Add Connection...', vscode.TreeItemCollapsibleState.None);
        this.iconPath = new vscode.ThemeIcon('add');
        this.command = {
            command: 'geode.connections.add',
            title: 'Add Connection'
        };
        this.contextValue = 'addConnection';
    }
}
/**
 * Tree data provider for the Connections view in the sidebar
 */
class ConnectionsTreeProvider {
    constructor(connectionManager) {
        this.connectionManager = connectionManager;
        this._onDidChangeTreeData = new vscode.EventEmitter();
        this.onDidChangeTreeData = this._onDidChangeTreeData.event;
        this.connectedIds = new Set();
        // Refresh when connections change
        connectionManager.onDidChangeConnections(() => {
            this.refresh();
        });
        connectionManager.onDidChangeActiveConnection(() => {
            this.refresh();
        });
    }
    refresh() {
        this._onDidChangeTreeData.fire(undefined);
    }
    setConnected(connectionId, connected) {
        if (connected) {
            this.connectedIds.add(connectionId);
        }
        else {
            this.connectedIds.delete(connectionId);
        }
        this.refresh();
    }
    clearConnections() {
        this.connectedIds.clear();
        this.refresh();
    }
    getTreeItem(element) {
        return element;
    }
    getChildren(element) {
        if (element) {
            return []; // No nested items
        }
        const items = [];
        const activeConnection = this.connectionManager.getActiveConnection();
        // Add all connections
        for (const profile of this.connectionManager.getConnections()) {
            const isActive = activeConnection?.id === profile.id;
            const isConnected = this.connectedIds.has(profile.id);
            items.push(new ConnectionTreeItem(profile, isActive, isConnected));
        }
        // Sort: active first, then by name
        items.sort((a, b) => {
            if (a instanceof ConnectionTreeItem && b instanceof ConnectionTreeItem) {
                if (a.isActive && !b.isActive)
                    return -1;
                if (!a.isActive && b.isActive)
                    return 1;
                if (a.profile.isDefault && !b.profile.isDefault)
                    return -1;
                if (!a.profile.isDefault && b.profile.isDefault)
                    return 1;
                return a.profile.name.localeCompare(b.profile.name);
            }
            return 0;
        });
        // Add the "Add Connection" item at the end
        items.push(new AddConnectionItem());
        return items;
    }
    dispose() {
        this._onDidChangeTreeData.dispose();
    }
}
exports.ConnectionsTreeProvider = ConnectionsTreeProvider;
/**
 * Register the connections tree view and commands
 */
function registerConnectionsView(context, connectionManager, outputChannel, onConnect, onDisconnect) {
    const treeProvider = new ConnectionsTreeProvider(connectionManager);
    // Register the tree view
    const treeView = vscode.window.createTreeView('geodeConnections', {
        treeDataProvider: treeProvider,
        showCollapseAll: false
    });
    context.subscriptions.push(treeView);
    // Register connection commands
    context.subscriptions.push(vscode.commands.registerCommand('geode.connections.add', async () => {
        await showConnectionEditor(connectionManager, outputChannel);
    }), vscode.commands.registerCommand('geode.connections.edit', async (item) => {
        if (item instanceof ConnectionTreeItem) {
            await showConnectionEditor(connectionManager, outputChannel, item.profile);
        }
    }), vscode.commands.registerCommand('geode.connections.delete', async (item) => {
        if (item instanceof ConnectionTreeItem) {
            const confirm = await vscode.window.showWarningMessage(`Delete connection "${item.profile.name}"?`, { modal: true }, 'Delete');
            if (confirm === 'Delete') {
                await connectionManager.deleteConnection(item.profile.id);
                treeProvider.setConnected(item.profile.id, false);
            }
        }
    }), vscode.commands.registerCommand('geode.connections.connect', async (idOrItem) => {
        const id = typeof idOrItem === 'string' ? idOrItem : idOrItem.profile.id;
        const profile = connectionManager.getConnection(id);
        if (!profile) {
            vscode.window.showErrorMessage('Connection not found');
            return;
        }
        // Get password if needed
        let password;
        if (profile.username) {
            password = await connectionManager.getPassword(profile.id);
            if (!password) {
                password = await vscode.window.showInputBox({
                    prompt: `Enter password for ${profile.username}@${profile.host}`,
                    password: true,
                    placeHolder: 'Password'
                });
                if (password === undefined) {
                    return; // Cancelled
                }
                // Ask if they want to save the password
                const save = await vscode.window.showQuickPick(['Save password securely', 'Use for this session only'], { placeHolder: 'Save password?' });
                if (save === 'Save password securely') {
                    await connectionManager.setPassword(profile.id, password);
                }
            }
        }
        // Set as active and connect
        await connectionManager.setActiveConnection(profile.id);
        const success = await onConnect(profile, password);
        if (success) {
            treeProvider.setConnected(profile.id, true);
        }
    }), vscode.commands.registerCommand('geode.connections.disconnect', async (item) => {
        onDisconnect();
        treeProvider.clearConnections();
    }), vscode.commands.registerCommand('geode.connections.setDefault', async (item) => {
        if (item instanceof ConnectionTreeItem) {
            const profile = { ...item.profile, isDefault: true };
            await connectionManager.saveConnection(profile);
            vscode.window.showInformationMessage(`"${profile.name}" is now the default connection`);
        }
    }), vscode.commands.registerCommand('geode.connections.copyDsn', async (item) => {
        if (item instanceof ConnectionTreeItem) {
            const dsn = connectionManager.buildDsn(item.profile);
            await vscode.env.clipboard.writeText(dsn);
            vscode.window.showInformationMessage('Connection string copied to clipboard');
        }
    }), vscode.commands.registerCommand('geode.connections.refresh', () => {
        treeProvider.refresh();
    }));
    return treeProvider;
}
/**
 * Show the connection editor dialog
 */
async function showConnectionEditor(connectionManager, outputChannel, existingProfile) {
    const isNew = !existingProfile;
    const profile = existingProfile ? { ...existingProfile } : {
        id: connectionManager.generateId(),
        name: '',
        host: 'localhost',
        port: 3141,
        useTls: true,
        insecure: false,
        timeout: 5000,
        queryTimeout: 30000,
        isDefault: false
    };
    // Step 1: Connection name
    const name = await vscode.window.showInputBox({
        prompt: 'Connection name',
        value: profile.name,
        placeHolder: 'My Geode Server',
        validateInput: (value) => {
            if (!value.trim()) {
                return 'Name is required';
            }
            return undefined;
        }
    });
    if (!name) {
        return undefined;
    }
    profile.name = name;
    // Step 2: Host
    const host = await vscode.window.showInputBox({
        prompt: 'Server hostname',
        value: profile.host,
        placeHolder: 'localhost'
    });
    if (!host) {
        return undefined;
    }
    profile.host = host;
    // Step 3: Port
    const portStr = await vscode.window.showInputBox({
        prompt: 'Server port',
        value: profile.port.toString(),
        placeHolder: '3141',
        validateInput: (value) => {
            const num = parseInt(value, 10);
            if (isNaN(num) || num < 1 || num > 65535) {
                return 'Port must be between 1 and 65535';
            }
            return undefined;
        }
    });
    if (!portStr) {
        return undefined;
    }
    profile.port = parseInt(portStr, 10);
    // Step 4: Database (optional)
    const database = await vscode.window.showInputBox({
        prompt: 'Database name (optional)',
        value: profile.database || '',
        placeHolder: 'Leave empty for default'
    });
    if (database === undefined) {
        return undefined;
    }
    profile.database = database || undefined;
    // Step 5: Username (optional)
    const username = await vscode.window.showInputBox({
        prompt: 'Username (optional)',
        value: profile.username || '',
        placeHolder: 'Leave empty for anonymous'
    });
    if (username === undefined) {
        return undefined;
    }
    profile.username = username || undefined;
    // Step 6: Password (if username provided)
    let password;
    if (profile.username) {
        password = await vscode.window.showInputBox({
            prompt: 'Password (optional)',
            password: true,
            placeHolder: 'Leave empty if not required'
        });
        if (password === undefined) {
            return undefined;
        }
    }
    // Step 7: TLS settings
    const tlsOption = await vscode.window.showQuickPick([
        { label: 'TLS Enabled (Recommended)', value: 'tls' },
        { label: 'TLS with self-signed certificate', value: 'insecure' },
        { label: 'No TLS (Insecure)', value: 'none' }
    ], {
        placeHolder: 'TLS Settings'
    });
    if (!tlsOption) {
        return undefined;
    }
    profile.useTls = tlsOption.value !== 'none';
    profile.insecure = tlsOption.value === 'insecure';
    // Step 8: Make default?
    if (isNew) {
        const makeDefault = await vscode.window.showQuickPick([
            { label: 'Yes', value: true },
            { label: 'No', value: false }
        ], {
            placeHolder: 'Set as default connection?'
        });
        if (makeDefault === undefined) {
            return undefined;
        }
        profile.isDefault = makeDefault.value;
    }
    // Save the connection
    await connectionManager.saveConnection(profile, password);
    vscode.window.showInformationMessage(`Connection "${profile.name}" ${isNew ? 'created' : 'updated'}`);
    return profile;
}
//# sourceMappingURL=ConnectionsTreeProvider.js.map