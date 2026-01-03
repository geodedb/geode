// CANARY: REQ=REQ-VSCODE-SCHEMA-EXPLORER-001; FEATURE="SchemaExplorerTreeView"; ASPECT=VSCodeIntegration; STATUS=IMPL; OWNER=tooling; UPDATED=2026-01-03
import * as vscode from 'vscode';
import * as cp from 'child_process';

/**
 * Schema Explorer Tree View Provider
 * Displays database schema structure in a tree view for easy navigation
 */

export interface SchemaElement {
    type: 'graphs' | 'graph' | 'labels' | 'label' | 'properties' | 'property' |
          'indexes' | 'index' | 'constraints' | 'constraint' | 'procedures' | 'procedure';
    name: string;
    children?: SchemaElement[];
    metadata?: Record<string, unknown>;
}

export class SchemaTreeItem extends vscode.TreeItem {
    constructor(
        public readonly label: string,
        public readonly schemaType: SchemaElement['type'],
        public readonly collapsibleState: vscode.TreeItemCollapsibleState,
        public readonly metadata?: Record<string, unknown>,
        public readonly children?: SchemaElement[]
    ) {
        super(label, collapsibleState);
        this.contextValue = schemaType;
        this.iconPath = this.getIcon();
        this.tooltip = this.getTooltip();
    }

    private getIcon(): vscode.ThemeIcon {
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

    private getTooltip(): string {
        if (this.metadata) {
            return Object.entries(this.metadata)
                .map(([k, v]) => `${k}: ${v}`)
                .join('\n');
        }
        return this.label;
    }
}

export class SchemaExplorerProvider implements vscode.TreeDataProvider<SchemaTreeItem> {
    private _onDidChangeTreeData = new vscode.EventEmitter<SchemaTreeItem | undefined | void>();
    readonly onDidChangeTreeData = this._onDidChangeTreeData.event;

    private schemaData: SchemaElement[] = [];
    private geodeCommand: string = 'geode';
    private serverHost: string = 'localhost';
    private serverPort: number = 3141;
    private isInsecure: boolean = false;

    constructor() {
        this.loadConfiguration();
    }

    private loadConfiguration(): void {
        const config = vscode.workspace.getConfiguration('geode');
        this.serverHost = config.get<string>('server.host', 'localhost');
        this.serverPort = config.get<number>('server.port', 3141);
        this.isInsecure = config.get<boolean>('server.insecure', false);

        const lspConfig = vscode.workspace.getConfiguration('geode.lsp');
        this.geodeCommand = lspConfig.get<string>('path', 'geode');
    }

    refresh(): void {
        this.loadConfiguration();
        this.fetchSchema().then(() => {
            this._onDidChangeTreeData.fire();
        }).catch((error) => {
            vscode.window.showErrorMessage(`Failed to refresh schema: ${error}`);
        });
    }

    getTreeItem(element: SchemaTreeItem): vscode.TreeItem {
        return element;
    }

    async getChildren(element?: SchemaTreeItem): Promise<SchemaTreeItem[]> {
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

    private createTreeItem(element: SchemaElement): SchemaTreeItem {
        const hasChildren = element.children && element.children.length > 0;
        return new SchemaTreeItem(
            element.name,
            element.type,
            hasChildren
                ? vscode.TreeItemCollapsibleState.Collapsed
                : vscode.TreeItemCollapsibleState.None,
            element.metadata,
            element.children
        );
    }

    private async fetchSchema(): Promise<void> {
        try {
            // Fetch node labels
            const nodeLabels = await this.runQuery('CALL db.labels() YIELD label RETURN label');

            // Fetch relationship types
            const relTypes = await this.runQuery('CALL db.relationshipTypes() YIELD type RETURN type');

            // Fetch property keys
            const propertyKeys = await this.runQuery('CALL db.propertyKeys() YIELD propertyKey RETURN propertyKey');

            // Fetch indexes
            const indexes = await this.runQuery('CALL db.indexes() YIELD name, type, labelsOrTypes, properties RETURN name, type, labelsOrTypes, properties');

            // Fetch constraints
            const constraints = await this.runQuery('CALL db.constraints() YIELD name, type, labelsOrTypes, properties RETURN name, type, labelsOrTypes, properties');

            // Fetch procedures
            const procedures = await this.runQuery('CALL dbms.procedures() YIELD name, description RETURN name, description');

            this.schemaData = [
                {
                    type: 'labels',
                    name: 'Node Labels',
                    children: this.parseLabels(nodeLabels)
                },
                {
                    type: 'labels',
                    name: 'Relationship Types',
                    children: this.parseRelTypes(relTypes)
                },
                {
                    type: 'properties',
                    name: 'Property Keys',
                    children: this.parsePropertyKeys(propertyKeys)
                },
                {
                    type: 'indexes',
                    name: 'Indexes',
                    children: this.parseIndexes(indexes)
                },
                {
                    type: 'constraints',
                    name: 'Constraints',
                    children: this.parseConstraints(constraints)
                },
                {
                    type: 'procedures',
                    name: 'Procedures',
                    children: this.parseProcedures(procedures)
                }
            ];
        } catch (error) {
            // If queries fail, show empty schema with error indication
            this.schemaData = [
                {
                    type: 'graphs',
                    name: 'Connection required',
                    children: [],
                    metadata: { status: 'Not connected to server' }
                }
            ];
        }
    }

    private parseLabels(result: string): SchemaElement[] {
        try {
            const data = JSON.parse(result);
            if (Array.isArray(data)) {
                return data.map((row: { label?: string }) => ({
                    type: 'label' as const,
                    name: row.label || 'Unknown',
                    metadata: { nodeLabel: row.label }
                }));
            }
        } catch { /* ignore parse errors */ }
        return [];
    }

    private parseRelTypes(result: string): SchemaElement[] {
        try {
            const data = JSON.parse(result);
            if (Array.isArray(data)) {
                return data.map((row: { type?: string }) => ({
                    type: 'label' as const,
                    name: row.type || 'Unknown',
                    metadata: { relationshipType: row.type }
                }));
            }
        } catch { /* ignore parse errors */ }
        return [];
    }

    private parsePropertyKeys(result: string): SchemaElement[] {
        try {
            const data = JSON.parse(result);
            if (Array.isArray(data)) {
                return data.map((row: { propertyKey?: string }) => ({
                    type: 'property' as const,
                    name: row.propertyKey || 'Unknown'
                }));
            }
        } catch { /* ignore parse errors */ }
        return [];
    }

    private parseIndexes(result: string): SchemaElement[] {
        try {
            const data = JSON.parse(result);
            if (Array.isArray(data)) {
                return data.map((row: { name?: string; type?: string; labelsOrTypes?: string[]; properties?: string[] }) => ({
                    type: 'index' as const,
                    name: row.name || 'Unknown',
                    metadata: {
                        indexType: row.type,
                        labels: row.labelsOrTypes?.join(', '),
                        properties: row.properties?.join(', ')
                    }
                }));
            }
        } catch { /* ignore parse errors */ }
        return [];
    }

    private parseConstraints(result: string): SchemaElement[] {
        try {
            const data = JSON.parse(result);
            if (Array.isArray(data)) {
                return data.map((row: { name?: string; type?: string; labelsOrTypes?: string[]; properties?: string[] }) => ({
                    type: 'constraint' as const,
                    name: row.name || 'Unknown',
                    metadata: {
                        constraintType: row.type,
                        labels: row.labelsOrTypes?.join(', '),
                        properties: row.properties?.join(', ')
                    }
                }));
            }
        } catch { /* ignore parse errors */ }
        return [];
    }

    private parseProcedures(result: string): SchemaElement[] {
        try {
            const data = JSON.parse(result);
            if (Array.isArray(data)) {
                return data.map((row: { name?: string; description?: string }) => ({
                    type: 'procedure' as const,
                    name: row.name || 'Unknown',
                    metadata: { description: row.description }
                }));
            }
        } catch { /* ignore parse errors */ }
        return [];
    }

    private runQuery(query: string): Promise<string> {
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
                } else {
                    reject(stderr || `Process exited with code ${code}`);
                }
            });

            process.on('error', (err) => {
                reject(err.message);
            });
        });
    }
}

export function registerSchemaExplorer(context: vscode.ExtensionContext): SchemaExplorerProvider {
    const provider = new SchemaExplorerProvider();

    const treeView = vscode.window.createTreeView('geodeSchemaExplorer', {
        treeDataProvider: provider,
        showCollapseAll: true
    });

    context.subscriptions.push(treeView);

    context.subscriptions.push(
        vscode.commands.registerCommand('geode.refreshSchema', () => provider.refresh())
    );

    return provider;
}
