"use strict";

const fs = require("node:fs");
const path = require("node:path");
const vscode = require("vscode");

let client;

const serverExecutableName = () => (process.platform === "win32" ? "zwgsl-lsp.exe" : "zwgsl-lsp");

const workspaceServerPath = () => {
  for (const folder of vscode.workspace.workspaceFolders ?? []) {
    const candidate = path.join(folder.uri.fsPath, "zig-out", "bin", serverExecutableName());
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
};

const configuredServerPath = () => {
  const configured = vscode.workspace.getConfiguration("zwgsl").get("serverPath", "");
  if (typeof configured === "string" && configured.trim().length > 0) {
    return configured.trim();
  }
  return workspaceServerPath() ?? serverExecutableName();
};

const activate = async (context) => {
  let languageClient;
  try {
    languageClient = require("vscode-languageclient/node");
  } catch {
    await vscode.window.showWarningMessage(
      "zwgsl extension dependencies are missing. Run npm install in editors/vscode.",
    );
    return;
  }

  const { LanguageClient, TransportKind } = languageClient;
  const command = configuredServerPath();
  const serverOptions = {
    command,
    transport: TransportKind.stdio,
  };
  const clientOptions = {
    documentSelector: [{ scheme: "file", language: "zwgsl" }],
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher("**/*.zw"),
    },
  };

  client = new LanguageClient("zwgsl", "zwgsl Language Server", serverOptions, clientOptions);
  context.subscriptions.push(client.start());
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration("zwgsl.serverPath")) {
        void vscode.window.showInformationMessage("Reload the window to restart zwgsl-lsp with the new path.");
      }
    }),
  );
};

const deactivate = () => {
  if (!client) return undefined;
  return client.stop();
};

module.exports = {
  activate,
  deactivate,
};
