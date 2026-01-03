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
exports.GraphViewPanel = void 0;
const vscode = __importStar(require("vscode"));
const BaseWebviewPanel_1 = require("./BaseWebviewPanel");
/**
 * Panel for interactive graph visualization.
 * Features:
 * - Force-directed and hierarchical layouts
 * - Node/edge selection and inspection
 * - Zoom and pan
 * - Node filtering by label
 * - Edge filtering by type
 * - Export to PNG/SVG
 */
class GraphViewPanel extends BaseWebviewPanel_1.BaseWebviewPanel {
    /**
     * Get or create the graph view panel singleton.
     */
    static createOrShow(options) {
        const column = options.viewColumn || vscode.ViewColumn.Two;
        // If we already have a panel, show it
        if (GraphViewPanel._instance) {
            GraphViewPanel._instance.reveal(column);
            return GraphViewPanel._instance;
        }
        // Create a new panel
        const panel = vscode.window.createWebviewPanel(GraphViewPanel.viewType, 'Graph Visualization', { viewColumn: column, preserveFocus: options.preserveFocus ?? true }, (0, BaseWebviewPanel_1.getWebviewOptions)(options.extensionUri));
        GraphViewPanel._instance = new GraphViewPanel(panel, options.extensionUri);
        return GraphViewPanel._instance;
    }
    constructor(panel, extensionUri) {
        super(panel, extensionUri);
        this._layout = 'force';
        this._query = '';
    }
    get title() {
        return 'Graph Visualization';
    }
    /**
     * Update the panel with new graph data.
     */
    setGraphData(data, query) {
        this._graphData = data;
        if (query) {
            this._query = query;
        }
        this._updateContent();
    }
    /**
     * Clear the graph data.
     */
    clearGraph() {
        this._graphData = undefined;
        this._query = '';
        this._updateContent();
    }
    /**
     * Set the layout type.
     */
    setLayout(layout) {
        this._layout = layout;
        this.postMessage({ type: 'setLayout', layout });
    }
    _handleMessage(message) {
        switch (message.type) {
            case 'nodeSelected':
                this._showNodeDetails(message.node);
                break;
            case 'edgeSelected':
                this._showEdgeDetails(message.edge);
                break;
            case 'exportPng':
                this._exportToPng(message.dataUrl);
                break;
            case 'exportSvg':
                this._exportToSvg(message.svg);
                break;
            case 'layoutChange':
                this._layout = message.layout;
                break;
        }
    }
    _showNodeDetails(node) {
        const props = node.properties ? JSON.stringify(node.properties, null, 2) : 'No properties';
        vscode.window.showInformationMessage(`Node ${node.id} [${node.labels?.join(', ') || 'no labels'}]: ${props.slice(0, 100)}...`);
    }
    _showEdgeDetails(edge) {
        const props = edge.properties ? JSON.stringify(edge.properties, null, 2) : 'No properties';
        vscode.window.showInformationMessage(`Edge ${edge.source} -[${edge.type || 'RELATES_TO'}]-> ${edge.target}: ${props.slice(0, 100)}...`);
    }
    async _exportToPng(dataUrl) {
        const uri = await vscode.window.showSaveDialog({
            defaultUri: vscode.Uri.file('graph.png'),
            filters: { 'PNG Image': ['png'] }
        });
        if (uri) {
            // Remove data URL prefix
            const base64Data = dataUrl.replace(/^data:image\/png;base64,/, '');
            const buffer = Buffer.from(base64Data, 'base64');
            await vscode.workspace.fs.writeFile(uri, buffer);
            vscode.window.showInformationMessage(`Graph exported to ${uri.fsPath}`);
        }
    }
    async _exportToSvg(svg) {
        const uri = await vscode.window.showSaveDialog({
            defaultUri: vscode.Uri.file('graph.svg'),
            filters: { 'SVG': ['svg'] }
        });
        if (uri) {
            await vscode.workspace.fs.writeFile(uri, Buffer.from(svg, 'utf8'));
            vscode.window.showInformationMessage(`Graph exported to ${uri.fsPath}`);
        }
    }
    getStylesheets() {
        return [
            this.getWebviewUri('src', 'webviews', 'graph', 'graph.css')
        ];
    }
    getScripts() {
        return [
            this.getWebviewUri('src', 'webviews', 'graph', 'graph.js')
        ];
    }
    getBodyContent() {
        if (!this._graphData) {
            return this._getEmptyState();
        }
        const { nodes, edges } = this._graphData;
        // Get unique labels and types for filters
        const labels = [...new Set(nodes.flatMap(n => n.labels || []))];
        const edgeTypes = [...new Set(edges.map(e => e.type || 'RELATES_TO'))];
        return `
            <div class="graph-container">
                <div class="graph-toolbar geode-toolbar">
                    <div class="graph-info">
                        <span class="geode-badge">${nodes.length} nodes</span>
                        <span class="geode-badge">${edges.length} edges</span>
                    </div>
                    <div class="geode-toolbar__spacer"></div>

                    <select class="geode-select" id="layoutSelect" onchange="changeLayout(this.value)">
                        <option value="force" ${this._layout === 'force' ? 'selected' : ''}>Force Layout</option>
                        <option value="hierarchical" ${this._layout === 'hierarchical' ? 'selected' : ''}>Hierarchical</option>
                        <option value="circular" ${this._layout === 'circular' ? 'selected' : ''}>Circular</option>
                        <option value="grid" ${this._layout === 'grid' ? 'selected' : ''}>Grid</option>
                    </select>

                    <button class="geode-button geode-button--small geode-button--icon" onclick="zoomIn()" data-tooltip="Zoom In">+</button>
                    <button class="geode-button geode-button--small geode-button--icon" onclick="zoomOut()" data-tooltip="Zoom Out">-</button>
                    <button class="geode-button geode-button--small geode-button--icon" onclick="fitToView()" data-tooltip="Fit">Fit</button>

                    <div class="geode-toolbar__divider"></div>

                    <button class="geode-button geode-button--small" onclick="exportPng()">PNG</button>
                    <button class="geode-button geode-button--small geode-button--secondary" onclick="exportSvg()">SVG</button>
                </div>

                ${labels.length > 0 || edgeTypes.length > 0 ? `
                <div class="graph-filters">
                    ${labels.length > 0 ? `
                    <div class="filter-group">
                        <span class="filter-label">Labels:</span>
                        ${labels.map(label => `
                            <label class="geode-checkbox">
                                <input type="checkbox" checked onchange="toggleLabel('${this._escapeHtml(label)}', this.checked)">
                                <span>${this._escapeHtml(label)}</span>
                            </label>
                        `).join('')}
                    </div>
                    ` : ''}
                    ${edgeTypes.length > 0 ? `
                    <div class="filter-group">
                        <span class="filter-label">Edge Types:</span>
                        ${edgeTypes.map(type => `
                            <label class="geode-checkbox">
                                <input type="checkbox" checked onchange="toggleEdgeType('${this._escapeHtml(type)}', this.checked)">
                                <span>${this._escapeHtml(type)}</span>
                            </label>
                        `).join('')}
                    </div>
                    ` : ''}
                </div>
                ` : ''}

                <div class="graph-canvas-container">
                    <canvas id="graphCanvas"></canvas>
                    <div id="tooltip" class="graph-tooltip" style="display: none;"></div>
                </div>

                <div id="nodeDetails" class="node-details" style="display: none;">
                    <h4 class="node-details__title">Node Details</h4>
                    <div class="node-details__content"></div>
                </div>
            </div>

            <script>
                // Pass graph data to the visualization script
                window.graphData = ${JSON.stringify(this._graphData)};
                window.initialLayout = '${this._layout}';
            </script>
        `;
    }
    _getEmptyState() {
        return `
            <div class="geode-empty">
                <div class="geode-empty__icon">
                    <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
                        <circle cx="12" cy="12" r="3"></circle>
                        <circle cx="4" cy="8" r="2"></circle>
                        <circle cx="4" cy="16" r="2"></circle>
                        <circle cx="20" cy="8" r="2"></circle>
                        <circle cx="20" cy="16" r="2"></circle>
                        <line x1="6" y1="8" x2="9" y2="10.5"></line>
                        <line x1="6" y1="16" x2="9" y2="13.5"></line>
                        <line x1="18" y1="8" x2="15" y2="10.5"></line>
                        <line x1="18" y1="16" x2="15" y2="13.5"></line>
                    </svg>
                </div>
                <h3 class="geode-empty__title">No Graph Data</h3>
                <p class="geode-empty__message">
                    Execute a query that returns nodes and relationships to see a visualization here.
                </p>
            </div>
        `;
    }
    _escapeHtml(text) {
        return text
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#039;');
    }
    dispose() {
        GraphViewPanel._instance = undefined;
        super.dispose();
    }
}
exports.GraphViewPanel = GraphViewPanel;
GraphViewPanel.viewType = 'geode.graphView';
//# sourceMappingURL=GraphViewPanel.js.map