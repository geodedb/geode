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
exports.PathExplorerPanel = void 0;
// CANARY: REQ=REQ-VSCODE-PATHS-001; FEATURE="PathExplorerPanel"; ASPECT=Implementation; STATUS=IMPL; OWNER=vscode; UPDATED=2026-01-03
const vscode = __importStar(require("vscode"));
const BaseWebviewPanel_1 = require("./BaseWebviewPanel");
/**
 * Path and Relationship Explorer Panel
 * Visualizes paths between nodes and relationship patterns in the graph.
 */
class PathExplorerPanel extends BaseWebviewPanel_1.BaseWebviewPanel {
    constructor(panel, extensionUri) {
        super(panel, extensionUri);
        this._pathResults = [];
        this._searchParams = {
            sourceNode: '',
            targetNode: '',
            relationshipTypes: [],
            maxDepth: 5,
            pathType: 'shortest'
        };
    }
    static createOrShow(options) {
        const column = options.viewColumn || vscode.ViewColumn.Two;
        if (PathExplorerPanel._instance) {
            PathExplorerPanel._instance.reveal(column);
            return PathExplorerPanel._instance;
        }
        const panel = vscode.window.createWebviewPanel(PathExplorerPanel.viewType, 'Geode Path Explorer', column, (0, BaseWebviewPanel_1.getWebviewOptions)(options.extensionUri));
        PathExplorerPanel._instance = new PathExplorerPanel(panel, options.extensionUri);
        return PathExplorerPanel._instance;
    }
    get title() {
        return 'Geode Path Explorer';
    }
    _handleMessage(message) {
        switch (message.type) {
            case 'searchPaths':
                this._searchPaths(message.params);
                break;
            case 'expandPath':
                this._expandPath(message.pathIndex);
                break;
            case 'exportPaths':
                this._exportPaths();
                break;
            case 'generateQuery':
                this._generateQuery();
                break;
            case 'visualizePath':
                this._visualizePath(message.pathIndex);
                break;
        }
    }
    getStylesheets() {
        return [this.getWebviewUri('src', 'webviews', 'paths', 'paths.css')];
    }
    getScripts() {
        return [this.getWebviewUri('src', 'webviews', 'paths', 'paths.js')];
    }
    getBodyContent() {
        return `
        <div class="path-explorer">
            <div class="search-panel">
                <h2>Path Search</h2>

                <div class="search-form">
                    <div class="form-row">
                        <div class="form-group">
                            <label for="sourceNode">Source Node</label>
                            <input type="text" id="sourceNode" placeholder="Node ID or label:property"
                                   value="${this._escapeHtml(this._searchParams.sourceNode)}">
                        </div>
                        <div class="form-group">
                            <label for="targetNode">Target Node</label>
                            <input type="text" id="targetNode" placeholder="Node ID or label:property"
                                   value="${this._escapeHtml(this._searchParams.targetNode)}">
                        </div>
                    </div>

                    <div class="form-row">
                        <div class="form-group">
                            <label for="relTypes">Relationship Types (comma-separated)</label>
                            <input type="text" id="relTypes" placeholder="FOLLOWS, KNOWS, LIKES"
                                   value="${this._searchParams.relationshipTypes.join(', ')}">
                        </div>
                    </div>

                    <div class="form-row">
                        <div class="form-group">
                            <label for="maxDepth">Max Depth</label>
                            <input type="number" id="maxDepth" min="1" max="20"
                                   value="${this._searchParams.maxDepth}">
                        </div>
                        <div class="form-group">
                            <label for="pathType">Path Type</label>
                            <select id="pathType">
                                <option value="shortest" ${this._searchParams.pathType === 'shortest' ? 'selected' : ''}>Shortest Path</option>
                                <option value="all" ${this._searchParams.pathType === 'all' ? 'selected' : ''}>All Paths</option>
                                <option value="weighted" ${this._searchParams.pathType === 'weighted' ? 'selected' : ''}>Weighted Shortest</option>
                            </select>
                        </div>
                    </div>

                    <div class="form-actions">
                        <button class="btn btn-primary" onclick="searchPaths()">
                            Search Paths
                        </button>
                        <button class="btn btn-secondary" onclick="postToExtension('generateQuery')">
                            Generate GQL
                        </button>
                    </div>
                </div>
            </div>

            <div class="results-panel">
                <div class="results-header">
                    <h2>Path Results</h2>
                    <div class="results-actions">
                        <span class="result-count">${this._pathResults.length} paths found</span>
                        <button class="btn btn-secondary" onclick="postToExtension('exportPaths')"
                                ${this._pathResults.length === 0 ? 'disabled' : ''}>
                            Export
                        </button>
                    </div>
                </div>

                <div class="path-list">
                    ${this._renderPathResults()}
                </div>
            </div>

            <div class="relationship-patterns">
                <h3>Common Relationship Patterns</h3>
                <div class="pattern-grid">
                    ${this._renderRelationshipPatterns()}
                </div>
            </div>
        </div>
        `;
    }
    _renderPathResults() {
        if (this._pathResults.length === 0) {
            return '<div class="no-results">No paths found. Enter source and target nodes to search.</div>';
        }
        return this._pathResults.map((path, index) => `
            <div class="path-item ${path.expanded ? 'expanded' : ''}">
                <div class="path-header" onclick="togglePath(${index})">
                    <span class="path-icon">${path.expanded ? '▼' : '▶'}</span>
                    <span class="path-summary">
                        <strong>Path ${index + 1}</strong>: ${path.nodes.length} nodes, ${path.relationships.length} relationships
                    </span>
                    <span class="path-length">Length: ${path.length}</span>
                    ${path.cost !== undefined ? `<span class="path-cost">Cost: ${path.cost.toFixed(2)}</span>` : ''}
                    <button class="btn-icon" onclick="event.stopPropagation(); postToExtension('visualizePath', {pathIndex: ${index}})" title="Visualize">
                        ◎
                    </button>
                </div>
                ${path.expanded ? this._renderExpandedPath(path) : ''}
            </div>
        `).join('');
    }
    _renderExpandedPath(path) {
        const segments = [];
        for (let i = 0; i < path.nodes.length; i++) {
            const node = path.nodes[i];
            segments.push(`
                <div class="path-node">
                    <span class="node-icon">●</span>
                    <span class="node-label">${this._escapeHtml(node.labels.join(':'))}</span>
                    <span class="node-id">#${node.id}</span>
                    ${node.properties ? `<span class="node-props">${this._formatProperties(node.properties)}</span>` : ''}
                </div>
            `);
            if (i < path.relationships.length) {
                const rel = path.relationships[i];
                segments.push(`
                    <div class="path-edge">
                        <span class="edge-line">──</span>
                        <span class="edge-type">${this._escapeHtml(rel.type)}</span>
                        <span class="edge-arrow">→</span>
                        ${rel.properties ? `<span class="edge-props">${this._formatProperties(rel.properties)}</span>` : ''}
                    </div>
                `);
            }
        }
        return `<div class="path-detail">${segments.join('')}</div>`;
    }
    _renderRelationshipPatterns() {
        const patterns = [
            { name: 'Direct Connection', pattern: '(a)-[r]->(b)', description: 'Single hop relationship' },
            { name: 'Two Hops', pattern: '(a)-[*2]->(b)', description: 'Exactly two relationships' },
            { name: 'Variable Length', pattern: '(a)-[*1..5]->(b)', description: '1 to 5 hops' },
            { name: 'Typed Path', pattern: '(a)-[:KNOWS*]->(b)', description: 'Only KNOWS relationships' },
            { name: 'Shortest Path', pattern: 'shortestPath((a)-[*]->(b))', description: 'Minimum hops' },
            { name: 'All Shortest', pattern: 'allShortestPaths((a)-[*]->(b))', description: 'All minimum paths' }
        ];
        return patterns.map(p => `
            <div class="pattern-card" onclick="applyPattern('${p.pattern}')">
                <div class="pattern-name">${p.name}</div>
                <code class="pattern-code">${p.pattern}</code>
                <div class="pattern-desc">${p.description}</div>
            </div>
        `).join('');
    }
    _formatProperties(props) {
        const entries = Object.entries(props).slice(0, 3);
        const formatted = entries.map(([k, v]) => `${k}: ${JSON.stringify(v)}`).join(', ');
        return `{${formatted}${Object.keys(props).length > 3 ? ', ...' : ''}}`;
    }
    async _searchPaths(params) {
        this._searchParams = params;
        // Generate sample path results for demonstration
        // In production, this would query the Geode server
        this._pathResults = this._generateSamplePaths(params);
        this._updateContent();
    }
    _generateSamplePaths(params) {
        const count = params.pathType === 'all' ? 5 : params.pathType === 'shortest' ? 1 : 3;
        const results = [];
        for (let i = 0; i < count; i++) {
            const pathLength = Math.min(params.maxDepth, Math.floor(Math.random() * 4) + 2);
            const nodes = [];
            const relationships = [];
            for (let j = 0; j <= pathLength; j++) {
                nodes.push({
                    id: Math.floor(Math.random() * 10000),
                    labels: ['Node', `Type${j % 3}`],
                    properties: { name: `Node_${j}`, created: new Date().toISOString() }
                });
                if (j < pathLength) {
                    const relTypes = params.relationshipTypes.length > 0
                        ? params.relationshipTypes
                        : ['CONNECTED', 'KNOWS', 'FOLLOWS'];
                    relationships.push({
                        id: Math.floor(Math.random() * 10000),
                        type: relTypes[Math.floor(Math.random() * relTypes.length)],
                        properties: { weight: Math.random() }
                    });
                }
            }
            results.push({
                nodes,
                relationships,
                length: pathLength,
                cost: params.pathType === 'weighted' ? Math.random() * 10 : undefined,
                expanded: false
            });
        }
        return results;
    }
    _expandPath(pathIndex) {
        if (pathIndex >= 0 && pathIndex < this._pathResults.length) {
            this._pathResults[pathIndex].expanded = !this._pathResults[pathIndex].expanded;
            this._updateContent();
        }
    }
    async _exportPaths() {
        const uri = await vscode.window.showSaveDialog({
            defaultUri: vscode.Uri.file('geode-paths.json'),
            filters: { 'JSON': ['json'], 'CSV': ['csv'] }
        });
        if (uri) {
            const ext = uri.path.split('.').pop()?.toLowerCase();
            let content;
            if (ext === 'csv') {
                content = this._pathResultsToCsv();
            }
            else {
                content = JSON.stringify(this._pathResults, null, 2);
            }
            await vscode.workspace.fs.writeFile(uri, Buffer.from(content));
            vscode.window.showInformationMessage('Paths exported successfully');
        }
    }
    _pathResultsToCsv() {
        const lines = ['PathIndex,Length,Cost,NodeCount,RelationshipCount'];
        this._pathResults.forEach((path, i) => {
            lines.push(`${i + 1},${path.length},${path.cost ?? ''},${path.nodes.length},${path.relationships.length}`);
        });
        return lines.join('\n');
    }
    _generateQuery() {
        const params = this._searchParams;
        let query = '';
        const relPattern = params.relationshipTypes.length > 0
            ? `:${params.relationshipTypes.join('|')}`
            : '';
        switch (params.pathType) {
            case 'shortest':
                query = `MATCH p = shortestPath((a)-[${relPattern}*1..${params.maxDepth}]->(b))
WHERE a.id = '${params.sourceNode}' AND b.id = '${params.targetNode}'
RETURN p`;
                break;
            case 'all':
                query = `MATCH p = (a)-[${relPattern}*1..${params.maxDepth}]->(b)
WHERE a.id = '${params.sourceNode}' AND b.id = '${params.targetNode}'
RETURN p`;
                break;
            case 'weighted':
                query = `MATCH p = (a)-[${relPattern}*1..${params.maxDepth}]->(b)
WHERE a.id = '${params.sourceNode}' AND b.id = '${params.targetNode}'
WITH p, reduce(cost = 0, r IN relationships(p) | cost + coalesce(r.weight, 1)) AS totalCost
RETURN p, totalCost
ORDER BY totalCost
LIMIT 1`;
                break;
        }
        // Copy to clipboard and show
        vscode.env.clipboard.writeText(query);
        vscode.window.showInformationMessage('GQL query copied to clipboard');
    }
    _visualizePath(pathIndex) {
        // This would open the GraphViewPanel with just this path
        vscode.window.showInformationMessage(`Visualizing path ${pathIndex + 1}`);
    }
    _escapeHtml(text) {
        return text
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');
    }
    dispose() {
        PathExplorerPanel._instance = undefined;
        super.dispose();
    }
}
exports.PathExplorerPanel = PathExplorerPanel;
PathExplorerPanel.viewType = 'geode.pathExplorer';
//# sourceMappingURL=PathExplorerPanel.js.map