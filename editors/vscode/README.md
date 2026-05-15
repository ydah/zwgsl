# zwgsl VS Code Extension

This is a minimal local VS Code extension for `.zw` files. It registers the
`zwgsl` language id, basic syntax highlighting, indentation rules, and starts
`zwgsl-lsp` over stdio.

## Run Locally

Build the language server from the repository root:

```sh
zig build -Doptimize=ReleaseFast
```

Install extension dependencies:

```sh
cd editors/vscode
npm install
```

Start an Extension Development Host with the repository root as the workspace:

```sh
code --extensionDevelopmentPath=editors/vscode .
```

The extension first looks for `zig-out/bin/zwgsl-lsp` in the open workspace. If
that does not exist, it falls back to `zwgsl-lsp` on `PATH`.

To use a specific server binary, set:

```json
{
  "zwgsl.serverPath": "/absolute/path/to/zwgsl-lsp"
}
```
