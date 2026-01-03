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
exports.PerformanceMetricsPanel = void 0;
// CANARY: REQ=REQ-VSCODE-METRICS-001; FEATURE="PerformanceMetricsPanel"; ASPECT=Implementation; STATUS=IMPL; OWNER=vscode; UPDATED=2026-01-03
const vscode = __importStar(require("vscode"));
const BaseWebviewPanel_1 = require("./BaseWebviewPanel");
/**
 * Real-time Performance Metrics Dashboard
 * Displays query performance, connection stats, and system health metrics.
 */
class PerformanceMetricsPanel extends BaseWebviewPanel_1.BaseWebviewPanel {
    constructor(panel, extensionUri) {
        super(panel, extensionUri);
        this._metrics = this._getDefaultMetrics();
        this._isConnected = false;
    }
    static createOrShow(options) {
        const column = options.viewColumn || vscode.ViewColumn.Two;
        if (PerformanceMetricsPanel._instance) {
            PerformanceMetricsPanel._instance.reveal(column);
            return PerformanceMetricsPanel._instance;
        }
        const panel = vscode.window.createWebviewPanel(PerformanceMetricsPanel.viewType, 'Geode Performance Metrics', column, (0, BaseWebviewPanel_1.getWebviewOptions)(options.extensionUri));
        PerformanceMetricsPanel._instance = new PerformanceMetricsPanel(panel, options.extensionUri);
        return PerformanceMetricsPanel._instance;
    }
    get title() {
        return 'Geode Performance Metrics';
    }
    _handleMessage(message) {
        switch (message.type) {
            case 'refresh':
                this._fetchMetrics();
                break;
            case 'startAutoRefresh':
                this._startAutoRefresh(message.interval || 5000);
                break;
            case 'stopAutoRefresh':
                this._stopAutoRefresh();
                break;
            case 'export':
                this._exportMetrics();
                break;
        }
    }
    getStylesheets() {
        return [this.getWebviewUri('src', 'webviews', 'metrics', 'metrics.css')];
    }
    getScripts() {
        return [this.getWebviewUri('src', 'webviews', 'metrics', 'metrics.js')];
    }
    getBodyContent() {
        return `
        <div class="metrics-header">
            <h1>Performance Metrics</h1>
            <div class="header-controls">
                <span class="connection-status ${this._isConnected ? 'connected' : 'disconnected'}">
                    ${this._isConnected ? '● Connected' : '○ Disconnected'}
                </span>
                <button class="btn btn-primary" onclick="postToExtension('refresh')">
                    ↻ Refresh
                </button>
                <button class="btn btn-secondary" id="autoRefreshBtn" onclick="toggleAutoRefresh()">
                    ▶ Auto-Refresh
                </button>
                <button class="btn btn-secondary" onclick="postToExtension('export')">
                    ⬇ Export
                </button>
            </div>
        </div>

        <div class="metrics-grid">
            <!-- Query Performance -->
            <div class="metric-card">
                <h3>Query Performance</h3>
                <div class="metric-row">
                    <span class="metric-label">Queries/sec</span>
                    <span class="metric-value" id="queriesPerSec">${this._metrics.queriesPerSec.toFixed(1)}</span>
                </div>
                <div class="metric-row">
                    <span class="metric-label">Avg Latency</span>
                    <span class="metric-value" id="avgLatency">${this._metrics.avgLatencyMs.toFixed(2)} ms</span>
                </div>
                <div class="metric-row">
                    <span class="metric-label">P95 Latency</span>
                    <span class="metric-value" id="p95Latency">${this._metrics.p95LatencyMs.toFixed(2)} ms</span>
                </div>
                <div class="metric-row">
                    <span class="metric-label">P99 Latency</span>
                    <span class="metric-value" id="p99Latency">${this._metrics.p99LatencyMs.toFixed(2)} ms</span>
                </div>
                <div class="metric-chart" id="latencyChart"></div>
            </div>

            <!-- Connection Stats -->
            <div class="metric-card">
                <h3>Connections</h3>
                <div class="metric-row">
                    <span class="metric-label">Active</span>
                    <span class="metric-value" id="activeConns">${this._metrics.activeConnections}</span>
                </div>
                <div class="metric-row">
                    <span class="metric-label">Idle</span>
                    <span class="metric-value" id="idleConns">${this._metrics.idleConnections}</span>
                </div>
                <div class="metric-row">
                    <span class="metric-label">Total</span>
                    <span class="metric-value" id="totalConns">${this._metrics.totalConnections}</span>
                </div>
                <div class="metric-row">
                    <span class="metric-label">Peak</span>
                    <span class="metric-value" id="peakConns">${this._metrics.peakConnections}</span>
                </div>
            </div>

            <!-- Memory Usage -->
            <div class="metric-card">
                <h3>Memory</h3>
                <div class="metric-row">
                    <span class="metric-label">Heap Used</span>
                    <span class="metric-value" id="heapUsed">${this._formatBytes(this._metrics.heapUsedBytes)}</span>
                </div>
                <div class="metric-row">
                    <span class="metric-label">Heap Total</span>
                    <span class="metric-value" id="heapTotal">${this._formatBytes(this._metrics.heapTotalBytes)}</span>
                </div>
                <div class="metric-row">
                    <span class="metric-label">Buffer Pool</span>
                    <span class="metric-value" id="bufferPool">${this._formatBytes(this._metrics.bufferPoolBytes)}</span>
                </div>
                <div class="progress-bar">
                    <div class="progress-fill" style="width: ${(this._metrics.heapUsedBytes / this._metrics.heapTotalBytes * 100).toFixed(1)}%"></div>
                </div>
            </div>

            <!-- Storage Stats -->
            <div class="metric-card">
                <h3>Storage</h3>
                <div class="metric-row">
                    <span class="metric-label">Data Size</span>
                    <span class="metric-value" id="dataSize">${this._formatBytes(this._metrics.dataSizeBytes)}</span>
                </div>
                <div class="metric-row">
                    <span class="metric-label">Index Size</span>
                    <span class="metric-value" id="indexSize">${this._formatBytes(this._metrics.indexSizeBytes)}</span>
                </div>
                <div class="metric-row">
                    <span class="metric-label">WAL Size</span>
                    <span class="metric-value" id="walSize">${this._formatBytes(this._metrics.walSizeBytes)}</span>
                </div>
                <div class="metric-row">
                    <span class="metric-label">Cache Hit Rate</span>
                    <span class="metric-value" id="cacheHitRate">${(this._metrics.cacheHitRate * 100).toFixed(1)}%</span>
                </div>
            </div>

            <!-- Graph Statistics -->
            <div class="metric-card">
                <h3>Graph Statistics</h3>
                <div class="metric-row">
                    <span class="metric-label">Total Nodes</span>
                    <span class="metric-value" id="totalNodes">${this._formatNumber(this._metrics.totalNodes)}</span>
                </div>
                <div class="metric-row">
                    <span class="metric-label">Total Edges</span>
                    <span class="metric-value" id="totalEdges">${this._formatNumber(this._metrics.totalEdges)}</span>
                </div>
                <div class="metric-row">
                    <span class="metric-label">Node Labels</span>
                    <span class="metric-value" id="nodeLabels">${this._metrics.nodeLabels}</span>
                </div>
                <div class="metric-row">
                    <span class="metric-label">Edge Types</span>
                    <span class="metric-value" id="edgeTypes">${this._metrics.edgeTypes}</span>
                </div>
            </div>

            <!-- Transaction Stats -->
            <div class="metric-card">
                <h3>Transactions</h3>
                <div class="metric-row">
                    <span class="metric-label">Active TXs</span>
                    <span class="metric-value" id="activeTxs">${this._metrics.activeTransactions}</span>
                </div>
                <div class="metric-row">
                    <span class="metric-label">Commits/sec</span>
                    <span class="metric-value" id="commitsPerSec">${this._metrics.commitsPerSec.toFixed(1)}</span>
                </div>
                <div class="metric-row">
                    <span class="metric-label">Rollbacks/sec</span>
                    <span class="metric-value" id="rollbacksPerSec">${this._metrics.rollbacksPerSec.toFixed(1)}</span>
                </div>
                <div class="metric-row">
                    <span class="metric-label">Lock Waits</span>
                    <span class="metric-value" id="lockWaits">${this._metrics.lockWaits}</span>
                </div>
            </div>
        </div>

        <!-- Recent Queries Table -->
        <div class="metric-card full-width">
            <h3>Recent Slow Queries</h3>
            <table class="data-table">
                <thead>
                    <tr>
                        <th>Time</th>
                        <th>Duration</th>
                        <th>Query</th>
                        <th>Rows</th>
                    </tr>
                </thead>
                <tbody id="slowQueriesTable">
                    ${this._renderSlowQueries()}
                </tbody>
            </table>
        </div>

        <!-- Latency Histogram -->
        <div class="metric-card full-width">
            <h3>Latency Distribution</h3>
            <div class="histogram" id="latencyHistogram">
                ${this._renderHistogram()}
            </div>
        </div>
        `;
    }
    _renderSlowQueries() {
        if (this._metrics.slowQueries.length === 0) {
            return '<tr><td colspan="4" class="no-data">No slow queries recorded</td></tr>';
        }
        return this._metrics.slowQueries.map(q => `
            <tr>
                <td>${new Date(q.timestamp).toLocaleTimeString()}</td>
                <td>${q.durationMs.toFixed(2)} ms</td>
                <td class="query-text">${this._escapeHtml(q.query.substring(0, 100))}${q.query.length > 100 ? '...' : ''}</td>
                <td>${q.rowsReturned}</td>
            </tr>
        `).join('');
    }
    _renderHistogram() {
        const buckets = this._metrics.latencyBuckets;
        const maxCount = Math.max(...buckets.map(b => b.count), 1);
        return buckets.map(bucket => `
            <div class="histogram-bar" style="height: ${(bucket.count / maxCount * 100).toFixed(1)}%" title="${bucket.label}: ${bucket.count}">
                <span class="bar-label">${bucket.label}</span>
            </div>
        `).join('');
    }
    _getDefaultMetrics() {
        return {
            queriesPerSec: 0,
            avgLatencyMs: 0,
            p95LatencyMs: 0,
            p99LatencyMs: 0,
            activeConnections: 0,
            idleConnections: 0,
            totalConnections: 0,
            peakConnections: 0,
            heapUsedBytes: 0,
            heapTotalBytes: 1,
            bufferPoolBytes: 0,
            dataSizeBytes: 0,
            indexSizeBytes: 0,
            walSizeBytes: 0,
            cacheHitRate: 0,
            totalNodes: 0,
            totalEdges: 0,
            nodeLabels: 0,
            edgeTypes: 0,
            activeTransactions: 0,
            commitsPerSec: 0,
            rollbacksPerSec: 0,
            lockWaits: 0,
            slowQueries: [],
            latencyBuckets: [
                { label: '<1ms', count: 0 },
                { label: '1-5ms', count: 0 },
                { label: '5-10ms', count: 0 },
                { label: '10-50ms', count: 0 },
                { label: '50-100ms', count: 0 },
                { label: '>100ms', count: 0 }
            ]
        };
    }
    async _fetchMetrics() {
        // In production, this would fetch from the Geode server
        // For now, generate sample data
        this._metrics = {
            queriesPerSec: Math.random() * 1000,
            avgLatencyMs: Math.random() * 10,
            p95LatencyMs: Math.random() * 50,
            p99LatencyMs: Math.random() * 100,
            activeConnections: Math.floor(Math.random() * 50),
            idleConnections: Math.floor(Math.random() * 20),
            totalConnections: Math.floor(Math.random() * 100),
            peakConnections: Math.floor(Math.random() * 150),
            heapUsedBytes: Math.floor(Math.random() * 500 * 1024 * 1024),
            heapTotalBytes: 1024 * 1024 * 1024,
            bufferPoolBytes: Math.floor(Math.random() * 100 * 1024 * 1024),
            dataSizeBytes: Math.floor(Math.random() * 10 * 1024 * 1024 * 1024),
            indexSizeBytes: Math.floor(Math.random() * 2 * 1024 * 1024 * 1024),
            walSizeBytes: Math.floor(Math.random() * 500 * 1024 * 1024),
            cacheHitRate: Math.random() * 0.3 + 0.7,
            totalNodes: Math.floor(Math.random() * 1000000),
            totalEdges: Math.floor(Math.random() * 5000000),
            nodeLabels: Math.floor(Math.random() * 20),
            edgeTypes: Math.floor(Math.random() * 15),
            activeTransactions: Math.floor(Math.random() * 10),
            commitsPerSec: Math.random() * 500,
            rollbacksPerSec: Math.random() * 10,
            lockWaits: Math.floor(Math.random() * 5),
            slowQueries: this._generateSampleSlowQueries(),
            latencyBuckets: [
                { label: '<1ms', count: Math.floor(Math.random() * 1000) },
                { label: '1-5ms', count: Math.floor(Math.random() * 500) },
                { label: '5-10ms', count: Math.floor(Math.random() * 200) },
                { label: '10-50ms', count: Math.floor(Math.random() * 100) },
                { label: '50-100ms', count: Math.floor(Math.random() * 50) },
                { label: '>100ms', count: Math.floor(Math.random() * 20) }
            ]
        };
        this._isConnected = true;
        this._updateContent();
    }
    _generateSampleSlowQueries() {
        const queries = [
            'MATCH (n:User)-[:FOLLOWS*1..5]->(m:User) RETURN n, m LIMIT 1000',
            'MATCH (a)-[r]->(b) WHERE a.created > datetime() - duration("P7D") RETURN count(*)',
            'CALL algo.pageRank.stream() YIELD nodeId, score RETURN nodeId, score ORDER BY score DESC LIMIT 100'
        ];
        return queries.slice(0, Math.floor(Math.random() * 3) + 1).map((q, i) => ({
            timestamp: Date.now() - i * 60000,
            query: q,
            durationMs: Math.random() * 500 + 100,
            rowsReturned: Math.floor(Math.random() * 1000)
        }));
    }
    _startAutoRefresh(interval) {
        this._stopAutoRefresh();
        this._refreshInterval = setInterval(() => this._fetchMetrics(), interval);
        this._fetchMetrics();
    }
    _stopAutoRefresh() {
        if (this._refreshInterval) {
            clearInterval(this._refreshInterval);
            this._refreshInterval = undefined;
        }
    }
    async _exportMetrics() {
        const uri = await vscode.window.showSaveDialog({
            defaultUri: vscode.Uri.file('geode-metrics.json'),
            filters: { 'JSON': ['json'] }
        });
        if (uri) {
            const content = JSON.stringify(this._metrics, null, 2);
            await vscode.workspace.fs.writeFile(uri, Buffer.from(content));
            vscode.window.showInformationMessage('Metrics exported successfully');
        }
    }
    _formatBytes(bytes) {
        const units = ['B', 'KB', 'MB', 'GB', 'TB'];
        let i = 0;
        while (bytes >= 1024 && i < units.length - 1) {
            bytes /= 1024;
            i++;
        }
        return `${bytes.toFixed(1)} ${units[i]}`;
    }
    _formatNumber(num) {
        if (num >= 1e9)
            return `${(num / 1e9).toFixed(1)}B`;
        if (num >= 1e6)
            return `${(num / 1e6).toFixed(1)}M`;
        if (num >= 1e3)
            return `${(num / 1e3).toFixed(1)}K`;
        return num.toString();
    }
    _escapeHtml(text) {
        return text
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');
    }
    dispose() {
        this._stopAutoRefresh();
        PerformanceMetricsPanel._instance = undefined;
        super.dispose();
    }
}
exports.PerformanceMetricsPanel = PerformanceMetricsPanel;
PerformanceMetricsPanel.viewType = 'geode.performanceMetrics';
//# sourceMappingURL=PerformanceMetricsPanel.js.map