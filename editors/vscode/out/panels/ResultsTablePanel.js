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
exports.ResultsTablePanel = void 0;
const vscode = __importStar(require("vscode"));
const BaseWebviewPanel_1 = require("./BaseWebviewPanel");
/**
 * Panel for displaying query results in a table format.
 * Features:
 * - Sortable columns
 * - Resizable columns
 * - Row selection
 * - Export to CSV/JSON
 * - Pagination for large result sets
 */
class ResultsTablePanel extends BaseWebviewPanel_1.BaseWebviewPanel {
    /**
     * Get or create the results table panel singleton.
     */
    static createOrShow(options) {
        const column = options.viewColumn || vscode.ViewColumn.Two;
        // If we already have a panel, show it
        if (ResultsTablePanel._instance) {
            ResultsTablePanel._instance.reveal(column);
            return ResultsTablePanel._instance;
        }
        // Create a new panel
        const panel = vscode.window.createWebviewPanel(ResultsTablePanel.viewType, 'Query Results', { viewColumn: column, preserveFocus: options.preserveFocus ?? true }, (0, BaseWebviewPanel_1.getWebviewOptions)(options.extensionUri));
        ResultsTablePanel._instance = new ResultsTablePanel(panel, options.extensionUri);
        return ResultsTablePanel._instance;
    }
    constructor(panel, extensionUri) {
        super(panel, extensionUri);
        this._query = '';
    }
    get title() {
        return 'Query Results';
    }
    /**
     * Update the panel with new query results.
     */
    setResults(results, query) {
        this._results = results;
        if (query) {
            this._query = query;
        }
        this._updateContent();
    }
    /**
     * Clear the results.
     */
    clearResults() {
        this._results = undefined;
        this._query = '';
        this._updateContent();
    }
    _handleMessage(message) {
        switch (message.type) {
            case 'exportCsv':
                this._exportToCsv();
                break;
            case 'exportJson':
                this._exportToJson();
                break;
            case 'copyCell':
                if (typeof message.value === 'string') {
                    vscode.env.clipboard.writeText(message.value);
                    vscode.window.showInformationMessage('Cell value copied to clipboard');
                }
                break;
            case 'copyRow':
                if (message.row !== undefined) {
                    const row = this._results?.rows[message.row];
                    if (row) {
                        vscode.env.clipboard.writeText(JSON.stringify(row, null, 2));
                        vscode.window.showInformationMessage('Row copied to clipboard');
                    }
                }
                break;
            case 'sort':
                // Sorting is handled client-side
                break;
        }
    }
    async _exportToCsv() {
        if (!this._results)
            return;
        const uri = await vscode.window.showSaveDialog({
            defaultUri: vscode.Uri.file('query_results.csv'),
            filters: { 'CSV': ['csv'] }
        });
        if (uri) {
            const csv = this._toCsv();
            await vscode.workspace.fs.writeFile(uri, Buffer.from(csv, 'utf8'));
            vscode.window.showInformationMessage(`Results exported to ${uri.fsPath}`);
        }
    }
    async _exportToJson() {
        if (!this._results)
            return;
        const uri = await vscode.window.showSaveDialog({
            defaultUri: vscode.Uri.file('query_results.json'),
            filters: { 'JSON': ['json'] }
        });
        if (uri) {
            const json = JSON.stringify(this._results.rows, null, 2);
            await vscode.workspace.fs.writeFile(uri, Buffer.from(json, 'utf8'));
            vscode.window.showInformationMessage(`Results exported to ${uri.fsPath}`);
        }
    }
    _toCsv() {
        if (!this._results)
            return '';
        const { columns, rows } = this._results;
        const lines = [];
        // Header
        lines.push(columns.map(c => this._escapeCsvValue(c)).join(','));
        // Data rows
        for (const row of rows) {
            const values = columns.map(col => {
                const val = row[col];
                return this._escapeCsvValue(this._formatValue(val));
            });
            lines.push(values.join(','));
        }
        return lines.join('\n');
    }
    _escapeCsvValue(value) {
        if (value.includes(',') || value.includes('"') || value.includes('\n')) {
            return `"${value.replace(/"/g, '""')}"`;
        }
        return value;
    }
    _formatValue(value) {
        if (value === null || value === undefined) {
            return 'null';
        }
        if (typeof value === 'object') {
            return JSON.stringify(value);
        }
        return String(value);
    }
    getStylesheets() {
        return [
            this.getWebviewUri('src', 'webviews', 'table', 'table.css')
        ];
    }
    getScripts() {
        return [
            this.getWebviewUri('src', 'webviews', 'table', 'table.js')
        ];
    }
    getBodyContent() {
        if (!this._results) {
            return this._getEmptyState();
        }
        const { columns, rows, executionTime, rowCount } = this._results;
        return `
            <div class="results-container">
                <div class="results-toolbar geode-toolbar">
                    <div class="results-info">
                        <span class="results-count">${rowCount ?? rows.length} rows</span>
                        ${executionTime !== undefined ? `<span class="execution-time">${executionTime.toFixed(2)}ms</span>` : ''}
                    </div>
                    <div class="geode-toolbar__spacer"></div>
                    <button class="geode-button geode-button--small" onclick="exportCsv()">
                        Export CSV
                    </button>
                    <button class="geode-button geode-button--small geode-button--secondary" onclick="exportJson()">
                        Export JSON
                    </button>
                </div>

                ${this._query ? `
                <div class="query-display">
                    <code>${this._escapeHtml(this._query)}</code>
                </div>
                ` : ''}

                <div class="table-wrapper">
                    <table class="geode-table results-table" id="resultsTable">
                        <thead>
                            <tr>
                                ${columns.map((col, i) => `
                                    <th class="sortable" data-column="${i}" onclick="sortColumn(${i})">
                                        ${this._escapeHtml(col)}
                                    </th>
                                `).join('')}
                            </tr>
                        </thead>
                        <tbody>
                            ${rows.map((row, rowIndex) => `
                                <tr data-row="${rowIndex}">
                                    ${columns.map(col => `
                                        <td class="cell" onclick="selectCell(this)" ondblclick="copyCell(this)">
                                            ${this._formatCellHtml(row[col])}
                                        </td>
                                    `).join('')}
                                </tr>
                            `).join('')}
                        </tbody>
                    </table>
                </div>
            </div>
        `;
    }
    _getEmptyState() {
        return `
            <div class="geode-empty">
                <div class="geode-empty__icon">
                    <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
                        <rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect>
                        <line x1="3" y1="9" x2="21" y2="9"></line>
                        <line x1="9" y1="21" x2="9" y2="9"></line>
                    </svg>
                </div>
                <h3 class="geode-empty__title">No Query Results</h3>
                <p class="geode-empty__message">
                    Execute a query to see results here.
                </p>
            </div>
        `;
    }
    _formatCellHtml(value) {
        if (value === null || value === undefined) {
            return '<span class="null-value">null</span>';
        }
        if (typeof value === 'boolean') {
            return `<span class="bool-value">${value}</span>`;
        }
        if (typeof value === 'number') {
            return `<span class="number-value">${value}</span>`;
        }
        if (typeof value === 'object') {
            if (Array.isArray(value)) {
                return `<span class="array-value" title="${this._escapeHtml(JSON.stringify(value))}">[${value.length} items]</span>`;
            }
            return `<span class="object-value" title="${this._escapeHtml(JSON.stringify(value))}">{...}</span>`;
        }
        const strValue = String(value);
        if (strValue.length > 100) {
            return `<span class="truncated-value" title="${this._escapeHtml(strValue)}">${this._escapeHtml(strValue.slice(0, 100))}...</span>`;
        }
        return this._escapeHtml(strValue);
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
        ResultsTablePanel._instance = undefined;
        super.dispose();
    }
}
exports.ResultsTablePanel = ResultsTablePanel;
ResultsTablePanel.viewType = 'geode.resultsTable';
//# sourceMappingURL=ResultsTablePanel.js.map