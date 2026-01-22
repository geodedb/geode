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
exports.ConnectionManager = void 0;
exports.createDefaultProfile = createDefaultProfile;
const vscode = __importStar(require("vscode"));
/**
 * Default connection profile for localhost development
 */
function createDefaultProfile() {
    return {
        id: 'default-local',
        name: 'Local Development',
        host: 'localhost',
        port: 3141,
        useTls: true,
        insecure: true, // Skip cert verification for local dev
        timeout: 5000,
        queryTimeout: 30000,
        isDefault: true
    };
}
/**
 * Manages Geode database connections with secure credential storage
 *
 * Security considerations:
 * - Passwords are stored in VS Code's SecretStorage (local only, never synced)
 * - Connection profiles are stored in globalState (syncs but no secrets)
 * - No passwords in project files or workspace settings
 */
class ConnectionManager {
    constructor(context, outputChannel) {
        this.context = context;
        this.outputChannel = outputChannel;
        this.connections = new Map();
        this.activeConnectionId = null;
        this._onDidChangeConnections = new vscode.EventEmitter();
        this._onDidChangeActiveConnection = new vscode.EventEmitter();
        this.onDidChangeConnections = this._onDidChangeConnections.event;
        this.onDidChangeActiveConnection = this._onDidChangeActiveConnection.event;
    }
    /**
     * Initialize the connection manager, loading saved connections
     */
    async initialize() {
        await this.loadConnections();
        // Ensure default connection exists
        if (this.connections.size === 0) {
            const defaultProfile = createDefaultProfile();
            await this.saveConnection(defaultProfile);
        }
        // Restore active connection
        this.activeConnectionId = this.context.globalState.get(ConnectionManager.ACTIVE_CONNECTION_KEY) ?? null;
        this.outputChannel.appendLine(`Connection manager initialized with ${this.connections.size} connection(s)`);
    }
    /**
     * Get all saved connection profiles
     */
    getConnections() {
        return Array.from(this.connections.values());
    }
    /**
     * Get a specific connection profile by ID
     */
    getConnection(id) {
        return this.connections.get(id);
    }
    /**
     * Get the currently active connection
     */
    getActiveConnection() {
        if (!this.activeConnectionId) {
            return null;
        }
        return this.connections.get(this.activeConnectionId) ?? null;
    }
    /**
     * Get the default connection profile
     */
    getDefaultConnection() {
        return Array.from(this.connections.values()).find(c => c.isDefault);
    }
    /**
     * Save or update a connection profile
     * Password is stored separately in SecretStorage
     */
    async saveConnection(profile, password) {
        // If this is marked as default, clear default from others
        if (profile.isDefault) {
            for (const conn of this.connections.values()) {
                if (conn.id !== profile.id && conn.isDefault) {
                    conn.isDefault = false;
                }
            }
        }
        this.connections.set(profile.id, profile);
        await this.persistConnections();
        // Store password securely if provided
        if (password !== undefined) {
            await this.setPassword(profile.id, password);
        }
        this._onDidChangeConnections.fire();
        this.outputChannel.appendLine(`Connection saved: ${profile.name}`);
    }
    /**
     * Delete a connection profile
     */
    async deleteConnection(id) {
        const profile = this.connections.get(id);
        if (!profile) {
            return;
        }
        this.connections.delete(id);
        await this.persistConnections();
        // Remove stored password
        await this.context.secrets.delete(ConnectionManager.PASSWORD_PREFIX + id);
        // Clear active connection if it was deleted
        if (this.activeConnectionId === id) {
            this.activeConnectionId = null;
            await this.context.globalState.update(ConnectionManager.ACTIVE_CONNECTION_KEY, null);
            this._onDidChangeActiveConnection.fire(null);
        }
        this._onDidChangeConnections.fire();
        this.outputChannel.appendLine(`Connection deleted: ${profile.name}`);
    }
    /**
     * Set the active connection
     */
    async setActiveConnection(id) {
        this.activeConnectionId = id;
        await this.context.globalState.update(ConnectionManager.ACTIVE_CONNECTION_KEY, id);
        const profile = id ? this.connections.get(id) ?? null : null;
        this._onDidChangeActiveConnection.fire(profile);
        if (profile) {
            this.outputChannel.appendLine(`Active connection set to: ${profile.name}`);
        }
        else {
            this.outputChannel.appendLine('Active connection cleared');
        }
    }
    /**
     * Get the password for a connection (from SecretStorage)
     */
    async getPassword(connectionId) {
        return this.context.secrets.get(ConnectionManager.PASSWORD_PREFIX + connectionId);
    }
    /**
     * Set the password for a connection (in SecretStorage)
     */
    async setPassword(connectionId, password) {
        if (password) {
            await this.context.secrets.store(ConnectionManager.PASSWORD_PREFIX + connectionId, password);
        }
        else {
            await this.context.secrets.delete(ConnectionManager.PASSWORD_PREFIX + connectionId);
        }
    }
    /**
     * Build the connection arguments for the geode CLI
     *
     * Supported CLI flags:
     *   --server <addr:port>   Server address
     *   --insecure             Skip TLS certificate verification
     *   --timeout <secs>       Connection timeout in seconds
     *   -U, --user <username>  Authenticate as user
     *   -P, --password <pass>  Authentication password
     */
    buildConnectionArgs(profile) {
        const args = [];
        args.push('--server', `${profile.host}:${profile.port}`);
        if (profile.insecure) {
            args.push('--insecure');
        }
        if (profile.timeout) {
            // Convert ms to seconds
            args.push('--timeout', Math.ceil(profile.timeout / 1000).toString());
        }
        if (profile.username) {
            args.push('-U', profile.username);
        }
        return args;
    }
    /**
     * Build connection arguments including password
     * Password is passed via -P flag
     */
    buildConnectionArgsWithPassword(profile, password) {
        const args = this.buildConnectionArgs(profile);
        if (password) {
            args.push('-P', password);
        }
        return args;
    }
    /**
     * Build the DSN string for the connection
     */
    buildDsn(profile, password) {
        let dsn = profile.useTls ? 'geodes://' : 'geode://';
        if (profile.username) {
            dsn += encodeURIComponent(profile.username);
            if (password) {
                dsn += ':' + encodeURIComponent(password);
            }
            dsn += '@';
        }
        dsn += profile.host;
        if (profile.port !== 3141) {
            dsn += ':' + profile.port;
        }
        if (profile.database) {
            dsn += '/' + encodeURIComponent(profile.database);
        }
        // Add query parameters
        const params = [];
        if (profile.insecure) {
            params.push('insecure=true');
        }
        if (profile.timeout !== 5000) {
            params.push(`timeout=${profile.timeout}`);
        }
        if (params.length > 0) {
            dsn += '?' + params.join('&');
        }
        return dsn;
    }
    /**
     * Generate a unique ID for a new connection
     */
    generateId() {
        return `conn-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
    }
    async loadConnections() {
        const stored = this.context.globalState.get(ConnectionManager.CONNECTIONS_KEY, []);
        this.connections.clear();
        for (const profile of stored) {
            this.connections.set(profile.id, profile);
        }
    }
    async persistConnections() {
        const profiles = Array.from(this.connections.values());
        await this.context.globalState.update(ConnectionManager.CONNECTIONS_KEY, profiles);
    }
    dispose() {
        this._onDidChangeConnections.dispose();
        this._onDidChangeActiveConnection.dispose();
    }
}
exports.ConnectionManager = ConnectionManager;
ConnectionManager.CONNECTIONS_KEY = 'geode.connections';
ConnectionManager.ACTIVE_CONNECTION_KEY = 'geode.activeConnection';
ConnectionManager.PASSWORD_PREFIX = 'geode.password.';
//# sourceMappingURL=ConnectionManager.js.map