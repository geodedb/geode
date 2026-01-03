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
exports.BaseWebviewPanel = void 0;
exports.getWebviewOptions = getWebviewOptions;
const vscode = __importStar(require("vscode"));
/**
 * Base class for Geode webview panels.
 * Provides:
 * - VSCode theme integration
 * - Secure content security policy
 * - Message passing infrastructure
 * - Resource loading helpers
 */
class BaseWebviewPanel {
    constructor(panel, extensionUri) {
        this._disposables = [];
        this._panel = panel;
        this._extensionUri = extensionUri;
        // Set initial HTML content
        this._updateContent();
        // Listen for when the panel is disposed
        this._panel.onDidDispose(() => this.dispose(), null, this._disposables);
        // Listen for view state changes
        this._panel.onDidChangeViewState(() => {
            if (this._panel.visible) {
                this._updateContent();
            }
        }, null, this._disposables);
        // Handle messages from the webview
        this._panel.webview.onDidReceiveMessage((message) => this._handleMessage(message), null, this._disposables);
        // Listen for theme changes
        vscode.window.onDidChangeActiveColorTheme(() => this._updateContent(), null, this._disposables);
    }
    /**
     * Update the webview content.
     */
    _updateContent() {
        this._panel.webview.html = this._getHtmlForWebview();
    }
    /**
     * Get any additional scripts to include.
     * Returns an array of script URIs.
     */
    getScripts() {
        return [];
    }
    /**
     * Get any additional stylesheets to include.
     * Returns an array of stylesheet URIs.
     */
    getStylesheets() {
        return [];
    }
    /**
     * Send a message to the webview.
     */
    postMessage(message) {
        return this._panel.webview.postMessage(message);
    }
    /**
     * Get a URI for a webview resource.
     */
    getWebviewUri(...pathSegments) {
        return this._panel.webview.asWebviewUri(vscode.Uri.joinPath(this._extensionUri, ...pathSegments));
    }
    /**
     * Generate the full HTML for the webview.
     */
    _getHtmlForWebview() {
        const webview = this._panel.webview;
        // Get URIs for shared resources
        const themeStyleUri = this.getWebviewUri('src', 'webviews', 'shared', 'theme.css');
        const componentsStyleUri = this.getWebviewUri('src', 'webviews', 'shared', 'components.css');
        // Get additional resources from subclass
        const additionalStyles = this.getStylesheets()
            .map(uri => `<link href="${uri}" rel="stylesheet">`)
            .join('\n        ');
        const additionalScripts = this.getScripts()
            .map(uri => `<script src="${uri}"></script>`)
            .join('\n        ');
        // Use a nonce to only allow specific scripts to run
        const nonce = this._getNonce();
        // Get current theme kind for CSS class
        const themeKind = vscode.window.activeColorTheme.kind;
        const themeClass = themeKind === vscode.ColorThemeKind.Dark ? 'vscode-dark'
            : themeKind === vscode.ColorThemeKind.HighContrast ? 'vscode-high-contrast'
                : themeKind === vscode.ColorThemeKind.HighContrastLight ? 'vscode-high-contrast-light'
                    : 'vscode-light';
        return `<!DOCTYPE html>
<html lang="en" class="${themeClass}">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src ${webview.cspSource} 'unsafe-inline'; script-src 'nonce-${nonce}'; img-src ${webview.cspSource} https: data:; font-src ${webview.cspSource};">
    <title>${this.title}</title>
    <link href="${themeStyleUri}" rel="stylesheet">
    <link href="${componentsStyleUri}" rel="stylesheet">
    ${additionalStyles}
</head>
<body>
    <div class="geode-panel">
        ${this.getBodyContent()}
    </div>
    <script nonce="${nonce}">
        const vscode = acquireVsCodeApi();

        // Expose postMessage helper
        window.postToExtension = function(type, data) {
            vscode.postMessage({ type, ...data });
        };

        // State management helpers
        window.getState = function() {
            return vscode.getState() || {};
        };

        window.setState = function(state) {
            vscode.setState(state);
        };
    </script>
    ${additionalScripts}
</body>
</html>`;
    }
    /**
     * Generate a random nonce for CSP.
     */
    _getNonce() {
        let text = '';
        const possible = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
        for (let i = 0; i < 32; i++) {
            text += possible.charAt(Math.floor(Math.random() * possible.length));
        }
        return text;
    }
    /**
     * Reveal the panel.
     */
    reveal(column) {
        this._panel.reveal(column);
    }
    /**
     * Dispose of the panel.
     */
    dispose() {
        // Clean up resources
        this._panel.dispose();
        while (this._disposables.length) {
            const disposable = this._disposables.pop();
            if (disposable) {
                disposable.dispose();
            }
        }
    }
}
exports.BaseWebviewPanel = BaseWebviewPanel;
BaseWebviewPanel.viewType = 'geode.webviewPanel';
/**
 * Helper function to create common webview options.
 */
function getWebviewOptions(extensionUri) {
    return {
        enableScripts: true,
        localResourceRoots: [
            vscode.Uri.joinPath(extensionUri, 'src', 'webviews'),
            vscode.Uri.joinPath(extensionUri, 'media'),
            vscode.Uri.joinPath(extensionUri, 'out')
        ]
    };
}
//# sourceMappingURL=BaseWebviewPanel.js.map