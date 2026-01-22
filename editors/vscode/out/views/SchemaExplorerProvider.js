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
exports.SchemaExplorerProvider = exports.SchemaTreeItem = void 0;
exports.registerSchemaExplorer = registerSchemaExplorer;
// CANARY: REQ=REQ-VSCODE-SCHEMA-EXPLORER-001; FEATURE="SchemaExplorerTreeView"; ASPECT=VSCodeIntegration; STATUS=IMPL; OWNER=tooling; UPDATED=2026-01-03
const vscode = __importStar(require("vscode"));
const cp = __importStar(require("child_process"));
class SchemaTreeItem extends vscode.TreeItem {
    constructor(label, schemaType, collapsibleState, metadata, children) {
        super(label, collapsibleState);
        this.label = label;
        this.schemaType = schemaType;
        this.collapsibleState = collapsibleState;
        this.metadata = metadata;
        this.children = children;
        this.contextValue = schemaType;
        this.iconPath = this.getIcon();
        this.tooltip = this.getTooltip();
    }
    getIcon() {
        switch (this.schemaType) {
            case 'graphs':
                return new vscode.ThemeIcon('folder-library');
            case 'graph':
                return new vscode.ThemeIcon('graph');
            case 'labels':
                return new vscode.ThemeIcon('tag');
            case 'label':
                return new vscode.ThemeIcon('symbol-class');
            case 'properties':
                return new vscode.ThemeIcon('symbol-field');
            case 'property':
                return new vscode.ThemeIcon('symbol-property');
            case 'indexes':
                return new vscode.ThemeIcon('list-tree');
            case 'index':
                return new vscode.ThemeIcon('search');
            case 'constraints':
                return new vscode.ThemeIcon('shield');
            case 'constraint':
                return new vscode.ThemeIcon('lock');
            case 'procedures':
                return new vscode.ThemeIcon('symbol-method');
            case 'procedure':
                return new vscode.ThemeIcon('debug-stackframe');
            default:
                return new vscode.ThemeIcon('circle-outline');
        }
    }
    getTooltip() {
        if (this.metadata) {
            return Object.entries(this.metadata)
                .map(([k, v]) => `${k}: ${v}`)
                .join('\n');
        }
        return this.label;
    }
}
exports.SchemaTreeItem = SchemaTreeItem;
class SchemaExplorerProvider {
    constructor() {
        this._onDidChangeTreeData = new vscode.EventEmitter();
        this.onDidChangeTreeData = this._onDidChangeTreeData.event;
        this.schemaData = [];
        this.geodeCommand = 'geode';
        this.serverHost = 'localhost';
        this.serverPort = 3141;
        this.isInsecure = false;
        this.loadConfiguration();
    }
    loadConfiguration() {
        const config = vscode.workspace.getConfiguration('geode');
        this.serverHost = config.get('server.host', 'localhost');
        this.serverPort = config.get('server.port', 3141);
        this.isInsecure = config.get('server.insecure', false);
        const lspConfig = vscode.workspace.getConfiguration('geode.lsp');
        this.geodeCommand = lspConfig.get('path', 'geode');
    }
    refresh() {
        this.loadConfiguration();
        this.fetchSchema().then(() => {
            this._onDidChangeTreeData.fire();
        }).catch((error) => {
            vscode.window.showErrorMessage(`Failed to refresh schema: ${error}`);
        });
    }
    getTreeItem(element) {
        return element;
    }
    async getChildren(element) {
        if (!element) {
            // Root level - show main categories
            if (this.schemaData.length === 0) {
                await this.fetchSchema();
            }
            return this.schemaData.map(item => this.createTreeItem(item));
        }
        // Return children of the element
        if (element.children) {
            return element.children.map(child => this.createTreeItem(child));
        }
        return [];
    }
    createTreeItem(element) {
        const hasChildren = element.children && element.children.length > 0;
        return new SchemaTreeItem(element.name, element.type, hasChildren
            ? vscode.TreeItemCollapsibleState.Collapsed
            : vscode.TreeItemCollapsibleState.None, element.metadata, element.children);
    }
    async fetchSchema() {
        try {
            // Fetch available graphs using Geode's SHOW GRAPHS command
            const graphs = await this.runQuery('SHOW GRAPHS');
            // Build schema data from graphs
            const graphChildren = this.parseGraphs(graphs);
            // Also try to get node labels from current graph by sampling
            let nodeLabels = [];
            let relTypes = [];
            try {
                // Sample distinct labels from nodes
                const labelsResult = await this.runQuery('MATCH (n) RETURN DISTINCT labels(n) AS labels LIMIT 100');
                nodeLabels = this.parseDistinctLabels(labelsResult);
            }
            catch {
                // Labels query not supported, skip
            }
            try {
                // Sample distinct relationship types
                const relsResult = await this.runQuery('MATCH ()-[r]->() RETURN DISTINCT type(r) AS type LIMIT 100');
                relTypes = this.parseDistinctRelTypes(relsResult);
            }
            catch {
                // Relationship types query not supported, skip
            }
            this.schemaData = [
                {
                    type: 'graphs',
                    name: 'Graphs',
                    children: graphChildren.length > 0 ? graphChildren : [{
                            type: 'graph',
                            name: '(use SHOW GRAPHS to list)',
                            metadata: { hint: 'Run SHOW GRAPHS query' }
                        }]
                },
                {
                    type: 'labels',
                    name: 'Node Labels',
                    children: nodeLabels.length > 0 ? nodeLabels : [{
                            type: 'label',
                            name: '(no labels found)',
                            metadata: { hint: 'Create nodes with labels' }
                        }]
                },
                {
                    type: 'labels',
                    name: 'Relationship Types',
                    children: relTypes.length > 0 ? relTypes : [{
                            type: 'label',
                            name: '(no relationships found)',
                            metadata: { hint: 'Create relationships' }
                        }]
                }
            ];
        }
        catch (error) {
            // If queries fail, show placeholder with connection info
            this.schemaData = [
                {
                    type: 'graphs',
                    name: 'Click to connect',
                    children: [],
                    metadata: { status: 'Click refresh after connecting to server' }
                }
            ];
        }
    }
    parseGraphs(result) {
        try {
            const lines = result.trim().split('\n');
            const graphs = [];
            for (const line of lines) {
                if (!line.trim())
                    continue;
                try {
                    const json = JSON.parse(line);
                    if (json.result?.rows) {
                        for (const row of json.result.rows) {
                            const name = row.name || row.graph || Object.values(row)[0];
                            if (name && typeof name === 'string') {
                                graphs.push({
                                    type: 'graph',
                                    name: name,
                                    metadata: row
                                });
                            }
                        }
                    }
                }
                catch { /* skip non-JSON lines */ }
            }
            return graphs;
        }
        catch {
            return [];
        }
    }
    parseDistinctLabels(result) {
        try {
            const lines = result.trim().split('\n');
            const labelSet = new Set();
            for (const line of lines) {
                if (!line.trim())
                    continue;
                try {
                    const json = JSON.parse(line);
                    if (json.result?.rows) {
                        for (const row of json.result.rows) {
                            const labels = row.labels;
                            if (Array.isArray(labels)) {
                                labels.forEach((l) => labelSet.add(l));
                            }
                        }
                    }
                }
                catch { /* skip */ }
            }
            return Array.from(labelSet).sort().map(label => ({
                type: 'label',
                name: label,
                metadata: { nodeLabel: label }
            }));
        }
        catch {
            return [];
        }
    }
    parseDistinctRelTypes(result) {
        try {
            const lines = result.trim().split('\n');
            const typeSet = new Set();
            for (const line of lines) {
                if (!line.trim())
                    continue;
                try {
                    const json = JSON.parse(line);
                    if (json.result?.rows) {
                        for (const row of json.result.rows) {
                            const relType = row.type;
                            if (typeof relType === 'string') {
                                typeSet.add(relType);
                            }
                        }
                    }
                }
                catch { /* skip */ }
            }
            return Array.from(typeSet).sort().map(type => ({
                type: 'label',
                name: type,
                metadata: { relationshipType: type }
            }));
        }
        catch {
            return [];
        }
    }
    parseLabels(result) {
        try {
            const data = JSON.parse(result);
            if (Array.isArray(data)) {
                return data.map((row) => ({
                    type: 'label',
                    name: row.label || 'Unknown',
                    metadata: { nodeLabel: row.label }
                }));
            }
        }
        catch { /* ignore parse errors */ }
        return [];
    }
    parseRelTypes(result) {
        try {
            const data = JSON.parse(result);
            if (Array.isArray(data)) {
                return data.map((row) => ({
                    type: 'label',
                    name: row.type || 'Unknown',
                    metadata: { relationshipType: row.type }
                }));
            }
        }
        catch { /* ignore parse errors */ }
        return [];
    }
    parsePropertyKeys(result) {
        try {
            const data = JSON.parse(result);
            if (Array.isArray(data)) {
                return data.map((row) => ({
                    type: 'property',
                    name: row.propertyKey || 'Unknown'
                }));
            }
        }
        catch { /* ignore parse errors */ }
        return [];
    }
    parseIndexes(result) {
        try {
            const data = JSON.parse(result);
            if (Array.isArray(data)) {
                return data.map((row) => ({
                    type: 'index',
                    name: row.name || 'Unknown',
                    metadata: {
                        indexType: row.type,
                        labels: row.labelsOrTypes?.join(', '),
                        properties: row.properties?.join(', ')
                    }
                }));
            }
        }
        catch { /* ignore parse errors */ }
        return [];
    }
    parseConstraints(result) {
        try {
            const data = JSON.parse(result);
            if (Array.isArray(data)) {
                return data.map((row) => ({
                    type: 'constraint',
                    name: row.name || 'Unknown',
                    metadata: {
                        constraintType: row.type,
                        labels: row.labelsOrTypes?.join(', '),
                        properties: row.properties?.join(', ')
                    }
                }));
            }
        }
        catch { /* ignore parse errors */ }
        return [];
    }
    parseProcedures(result) {
        try {
            const data = JSON.parse(result);
            if (Array.isArray(data)) {
                return data.map((row) => ({
                    type: 'procedure',
                    name: row.name || 'Unknown',
                    metadata: { description: row.description }
                }));
            }
        }
        catch { /* ignore parse errors */ }
        return [];
    }
    runQuery(query) {
        return new Promise((resolve, reject) => {
            const args = ['query', '--server', `${this.serverHost}:${this.serverPort}`, '--format', 'json'];
            if (this.isInsecure) {
                args.push('--insecure');
            }
            args.push(query);
            const process = cp.spawn(this.geodeCommand, args, { timeout: 10000 });
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
}
exports.SchemaExplorerProvider = SchemaExplorerProvider;
function registerSchemaExplorer(context) {
    const provider = new SchemaExplorerProvider();
    const treeView = vscode.window.createTreeView('geodeSchemaExplorer', {
        treeDataProvider: provider,
        showCollapseAll: true
    });
    context.subscriptions.push(treeView);
    context.subscriptions.push(vscode.commands.registerCommand('geode.refreshSchema', () => provider.refresh()));
    return provider;
}
//# sourceMappingURL=SchemaExplorerProvider.js.map