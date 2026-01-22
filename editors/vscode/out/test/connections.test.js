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
const assert = __importStar(require("assert"));
const child_process_1 = require("child_process");
const fs = __importStar(require("fs"));
function createDefaultProfile() {
    return {
        id: 'default-local',
        name: 'Local Development',
        host: 'localhost',
        port: 3141,
        useTls: true,
        insecure: true,
        timeout: 5000,
        queryTimeout: 30000,
        isDefault: true
    };
}
// Mock VS Code types for unit testing without full VS Code extension host
class MockSecrets {
    constructor() {
        this._data = new Map();
    }
    async get(key) {
        return this._data.get(key);
    }
    async store(key, value) {
        this._data.set(key, value);
    }
    async delete(key) {
        this._data.delete(key);
    }
}
class MockGlobalState {
    constructor() {
        this._data = new Map();
    }
    get(key, defaultValue) {
        return this._data.get(key) ?? defaultValue;
    }
    async update(key, value) {
        this._data.set(key, value);
    }
}
class MockOutputChannel {
    constructor() {
        this.lines = [];
    }
    appendLine(line) {
        this.lines.push(line);
    }
    getOutput() {
        return [...this.lines];
    }
    clear() {
        this.lines = [];
    }
}
describe('Connection Manager Tests', () => {
    describe('createDefaultProfile', () => {
        it('creates profile with correct defaults', () => {
            const profile = createDefaultProfile();
            assert.strictEqual(profile.id, 'default-local');
            assert.strictEqual(profile.name, 'Local Development');
            assert.strictEqual(profile.host, 'localhost');
            assert.strictEqual(profile.port, 3141);
            assert.strictEqual(profile.useTls, true);
            assert.strictEqual(profile.insecure, true);
            assert.strictEqual(profile.timeout, 5000);
            assert.strictEqual(profile.queryTimeout, 30000);
            assert.strictEqual(profile.isDefault, true);
        });
    });
    describe('ConnectionProfile interface', () => {
        it('can create a minimal profile', () => {
            const profile = {
                id: 'test-1',
                name: 'Test Connection',
                host: '192.168.1.100',
                port: 3142,
                useTls: true,
                insecure: false,
                timeout: 10000,
                queryTimeout: 60000,
                isDefault: false
            };
            assert.strictEqual(profile.host, '192.168.1.100');
            assert.strictEqual(profile.port, 3142);
        });
        it('can create a profile with authentication', () => {
            const profile = {
                id: 'test-2',
                name: 'Authenticated Connection',
                host: 'db.example.com',
                port: 3141,
                database: 'production',
                username: 'admin',
                useTls: true,
                insecure: false,
                timeout: 5000,
                queryTimeout: 30000,
                isDefault: false
            };
            assert.strictEqual(profile.database, 'production');
            assert.strictEqual(profile.username, 'admin');
        });
        it('can create a profile with TLS certificates', () => {
            const profile = {
                id: 'test-3',
                name: 'TLS Connection',
                host: 'secure.example.com',
                port: 3141,
                useTls: true,
                insecure: false,
                certPath: '/path/to/client.crt',
                keyPath: '/path/to/client.key',
                caPath: '/path/to/ca.crt',
                timeout: 5000,
                queryTimeout: 30000,
                isDefault: false
            };
            assert.strictEqual(profile.certPath, '/path/to/client.crt');
            assert.strictEqual(profile.keyPath, '/path/to/client.key');
            assert.strictEqual(profile.caPath, '/path/to/ca.crt');
        });
    });
    describe('CLI Argument Building', () => {
        // Simulate the buildConnectionArgs logic for testing
        function buildConnectionArgs(profile) {
            const args = [];
            args.push('--server', `${profile.host}:${profile.port}`);
            if (profile.insecure) {
                args.push('--insecure');
            }
            if (profile.timeout) {
                args.push('--timeout', Math.ceil(profile.timeout / 1000).toString());
            }
            if (profile.username) {
                args.push('-U', profile.username);
            }
            return args;
        }
        function buildConnectionArgsWithPassword(profile, password) {
            const args = buildConnectionArgs(profile);
            if (password) {
                args.push('-P', password);
            }
            return args;
        }
        it('builds basic connection args', () => {
            const profile = createDefaultProfile();
            const args = buildConnectionArgs(profile);
            assert.ok(args.includes('--server'));
            assert.ok(args.includes('localhost:3141'));
            assert.ok(args.includes('--insecure'));
            assert.ok(args.includes('--timeout'));
        });
        it('includes timeout in seconds', () => {
            const profile = {
                ...createDefaultProfile(),
                timeout: 10000 // 10 seconds in ms
            };
            const args = buildConnectionArgs(profile);
            const timeoutIdx = args.indexOf('--timeout');
            assert.ok(timeoutIdx >= 0);
            assert.strictEqual(args[timeoutIdx + 1], '10');
        });
        it('includes username when specified', () => {
            const profile = {
                ...createDefaultProfile(),
                username: 'testuser'
            };
            const args = buildConnectionArgs(profile);
            assert.ok(args.includes('-U'));
            assert.ok(args.includes('testuser'));
        });
        it('includes password when specified', () => {
            const profile = {
                ...createDefaultProfile(),
                username: 'testuser'
            };
            const args = buildConnectionArgsWithPassword(profile, 'secret123');
            assert.ok(args.includes('-P'));
            assert.ok(args.includes('secret123'));
        });
        it('does not include password flag when password is undefined', () => {
            const profile = createDefaultProfile();
            const args = buildConnectionArgsWithPassword(profile, undefined);
            assert.ok(!args.includes('-P'));
        });
        it('does not include insecure flag when useTls is true and insecure is false', () => {
            const profile = {
                ...createDefaultProfile(),
                useTls: true,
                insecure: false
            };
            const args = buildConnectionArgs(profile);
            assert.ok(!args.includes('--insecure'));
        });
    });
    describe('DSN Building', () => {
        function buildDsn(profile, password) {
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
        it('builds basic DSN for localhost', () => {
            const profile = createDefaultProfile();
            const dsn = buildDsn(profile);
            assert.ok(dsn.startsWith('geodes://'));
            assert.ok(dsn.includes('localhost'));
            assert.ok(dsn.includes('insecure=true'));
        });
        it('includes port only when non-default', () => {
            const profile = {
                ...createDefaultProfile(),
                port: 3142
            };
            const dsn = buildDsn(profile);
            assert.ok(dsn.includes(':3142'));
        });
        it('omits port for default 3141', () => {
            const profile = createDefaultProfile();
            const dsn = buildDsn(profile);
            // Should not have :3141 after localhost
            assert.ok(!dsn.includes('localhost:3141'));
        });
        it('includes username and password', () => {
            const profile = {
                ...createDefaultProfile(),
                username: 'admin',
                insecure: false
            };
            const dsn = buildDsn(profile, 'secret');
            assert.ok(dsn.includes('admin:secret@'));
        });
        it('encodes special characters in username', () => {
            const profile = {
                ...createDefaultProfile(),
                username: 'user@domain.com',
                insecure: false
            };
            const dsn = buildDsn(profile);
            assert.ok(dsn.includes(encodeURIComponent('user@domain.com')));
        });
        it('includes database name', () => {
            const profile = {
                ...createDefaultProfile(),
                database: 'mydb',
                insecure: false
            };
            const dsn = buildDsn(profile);
            assert.ok(dsn.includes('/mydb'));
        });
        it('uses geode:// for non-TLS connections', () => {
            const profile = {
                ...createDefaultProfile(),
                useTls: false,
                insecure: false
            };
            const dsn = buildDsn(profile);
            assert.ok(dsn.startsWith('geode://'));
            assert.ok(!dsn.startsWith('geodes://'));
        });
    });
    describe('Mock SecretStorage', () => {
        it('can store and retrieve secrets', async () => {
            const secrets = new MockSecrets();
            await secrets.store('test-key', 'test-value');
            const value = await secrets.get('test-key');
            assert.strictEqual(value, 'test-value');
        });
        it('returns undefined for missing keys', async () => {
            const secrets = new MockSecrets();
            const value = await secrets.get('nonexistent');
            assert.strictEqual(value, undefined);
        });
        it('can delete secrets', async () => {
            const secrets = new MockSecrets();
            await secrets.store('test-key', 'test-value');
            await secrets.delete('test-key');
            const value = await secrets.get('test-key');
            assert.strictEqual(value, undefined);
        });
    });
    describe('Mock GlobalState', () => {
        it('can store and retrieve values', async () => {
            const state = new MockGlobalState();
            await state.update('connections', [{ id: '1', name: 'Test' }]);
            const value = state.get('connections', []);
            assert.strictEqual(value.length, 1);
            assert.strictEqual(value[0].name, 'Test');
        });
        it('returns default for missing keys', () => {
            const state = new MockGlobalState();
            const value = state.get('missing', 'default');
            assert.strictEqual(value, 'default');
        });
    });
});
describe('CLI Integration Tests', () => {
    // Path relative to the vscode extension directory
    const geodeBinary = '../../zig-out/bin/geode';
    function isServerRunning() {
        try {
            (0, child_process_1.execFileSync)(geodeBinary, [
                'query', '--server', '127.0.0.1:3141', '--insecure', '--timeout', '2', 'RETURN 1'
            ], { encoding: 'utf8', stdio: 'pipe' });
            return true;
        }
        catch {
            return false;
        }
    }
    it('geode binary exists', () => {
        assert.ok(fs.existsSync(geodeBinary), 'Geode binary should exist');
    });
    it('geode query --help works', () => {
        try {
            (0, child_process_1.execFileSync)(geodeBinary, ['query', '--help'], { encoding: 'utf8', stdio: 'pipe' });
        }
        catch (error) {
            // Help might exit with non-zero code
            const err = error;
            const output = (err.stdout || '') + (err.stderr || '');
            assert.ok(output.includes('--server') || output.includes('Execute a GQL query'));
            return;
        }
        // If it succeeds, the binary works
        assert.ok(true);
    });
    it('geode query with insecure flag is accepted', () => {
        // This test verifies the CLI accepts our arguments
        // It may fail with connection timeout if no server is running
        try {
            (0, child_process_1.execFileSync)(geodeBinary, [
                'query', '--server', '127.0.0.1:3141', '--insecure', '--timeout', '1', 'RETURN 1'
            ], { encoding: 'utf8', stdio: 'pipe' });
        }
        catch (error) {
            // Expected if no server running - we're testing argument parsing
            const err = error;
            const stderr = err.stderr || err.message || '';
            // Should be timeout, not argument error
            assert.ok(stderr.includes('timeout') || stderr.includes('connection'), 'Should fail with timeout, not argument error');
        }
    });
    it('geode query with -U flag is accepted', () => {
        try {
            (0, child_process_1.execFileSync)(geodeBinary, [
                'query', '--server', '127.0.0.1:3141', '--insecure', '--timeout', '1',
                '-U', 'testuser', 'RETURN 1'
            ], { encoding: 'utf8', stdio: 'pipe' });
        }
        catch (error) {
            const err = error;
            const stderr = err.stderr || err.message || '';
            assert.ok(stderr.includes('timeout') || stderr.includes('connection') || stderr.includes('auth'), 'Should fail with timeout or auth error, not argument error');
        }
    });
    it('geode query via stdin with dash works', function () {
        if (!isServerRunning()) {
            this.skip();
            return;
        }
        // Test that queries can be sent via stdin using '-'
        const query = 'RETURN 42 AS answer';
        const output = (0, child_process_1.execFileSync)(geodeBinary, [
            'query', '--server', '127.0.0.1:3141', '--insecure', '-'
        ], { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], input: query });
        assert.ok(output.includes('42') || output.includes('"answer"'));
    });
    // Conditional test - only runs if server is up
    it('geode query executes successfully when server is running', function () {
        if (!isServerRunning()) {
            this.skip();
            return;
        }
        const output = (0, child_process_1.execFileSync)(geodeBinary, [
            'query', '--server', '127.0.0.1:3141', '--insecure', 'RETURN 1 AS x'
        ], { encoding: 'utf8', stdio: 'pipe' });
        assert.ok(output.includes('"x"') || output.includes('"rows"'));
    });
});
//# sourceMappingURL=connections.test.js.map