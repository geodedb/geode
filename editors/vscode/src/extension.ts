import * as vscode from 'vscode';
import * as path from 'path';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    TransportKind
} from 'vscode-languageclient/node';

let client: LanguageClient;

export function activate(context: vscode.ExtensionContext) {
    const config = vscode.workspace.getConfiguration('geode.lsp');
    const serverPath = config.get<string>('path', 'geode');
    const serverArgs = config.get<string[]>('args', ['lsp']);

    // Server options - run geode lsp
    const serverOptions: ServerOptions = {
        command: serverPath,
        args: serverArgs,
        transport: TransportKind.stdio
    };

    // Client options
    const clientOptions: LanguageClientOptions = {
        documentSelector: [
            { scheme: 'file', language: 'gql' },
            { scheme: 'file', language: 'cypher' },
            { scheme: 'file', pattern: '**/*.gql' },
            { scheme: 'file', pattern: '**/*.gcypher' },
            { scheme: 'file', pattern: '**/*.cypher' },
            { scheme: 'file', pattern: '**/*.pgql' }
        ],
        synchronize: {
            fileEvents: vscode.workspace.createFileSystemWatcher('**/*.{gql,gcypher,cypher,pgql}')
        },
        outputChannelName: 'Geode GQL Language Server'
    };

    // Create and start the client
    client = new LanguageClient(
        'geode-gql',
        'Geode GQL Language Server',
        serverOptions,
        clientOptions
    );

    // Start the client (also starts the server)
    client.start();

    // Register status bar item
    const statusBarItem = vscode.window.createStatusBarItem(
        vscode.StatusBarAlignment.Right,
        100
    );
    statusBarItem.text = '$(database) Geode GQL';
    statusBarItem.tooltip = 'Geode GQL Language Server';
    statusBarItem.show();
    context.subscriptions.push(statusBarItem);

    console.log('Geode GQL extension activated');
}

export function deactivate(): Thenable<void> | undefined {
    if (!client) {
        return undefined;
    }
    return client.stop();
}
