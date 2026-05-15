# Editor Setup

`zwgsl-lsp` is a stdio language server for `.zw` files. Build it before wiring
it into an editor:

```sh
zig build -Doptimize=ReleaseFast
```

The executable is installed at `zig-out/bin/zwgsl-lsp`. Use an absolute path in
editor configuration if the editor is not launched from the repository root.

## File Type

Use `zwgsl` as the editor language id and `.zw` as the file extension.

GitHub syntax highlighting is mapped through `.gitattributes` to Ruby while a
native Linguist grammar does not exist. This is only a readability fallback; the
compiler and LSP still treat the language as zwgsl.

## Neovim

This snippet uses Neovim's built-in LSP client:

```lua
vim.filetype.add({
  extension = {
    zw = "zwgsl",
  },
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = "zwgsl",
  callback = function(args)
    local root = vim.fs.root(args.buf, { "build.zig", ".git" }) or vim.fn.getcwd()

    vim.lsp.start({
      name = "zwgsl",
      cmd = { root .. "/zig-out/bin/zwgsl-lsp" },
      root_dir = root,
    })
  end,
})
```

## Helix

Add this to `languages.toml`, replacing the command with an absolute path if
needed:

```toml
[language-server.zwgsl]
command = "/absolute/path/to/zwgsl/zig-out/bin/zwgsl-lsp"

[[language]]
name = "zwgsl"
scope = "source.zwgsl"
file-types = ["zw"]
language-servers = ["zwgsl"]
```

## VS Code

The repository includes a minimal local extension under `editors/vscode`. It
provides `.zw` file association, basic syntax highlighting, indentation rules,
and LSP startup over stdio.

Build the server, then install the extension dependencies:

```sh
zig build -Doptimize=ReleaseFast
cd editors/vscode
npm install
```

Start an Extension Development Host with the repository root as the workspace:

```sh
code --extensionDevelopmentPath=editors/vscode .
```

The extension first looks for `zig-out/bin/zwgsl-lsp` in the open workspace. If
that does not exist, it falls back to `zwgsl-lsp` on `PATH`.

To point at a specific server binary, set:

```json
{
  "zwgsl.serverPath": "/absolute/path/to/zwgsl-lsp"
}
```

## Zed

Zed needs a language extension before it can attach an LSP server to a new file
type. Use these values in that extension:

```text
language id: zwgsl
file suffix: zw
server command: /absolute/path/to/zwgsl/zig-out/bin/zwgsl-lsp
transport: stdio
```

## Supported Features

Current editor-facing capabilities are:

- incremental document sync with full-change compatibility
- diagnostics from compiler errors and warnings
- hover for builtins, declarations, and inferred types
- completion for locals, declarations, stage builtins, constructors, fields, and methods
- signature help for functions, constructors, and supported builtins
- code actions for common stage declaration, unused uniform, and type/constructor casing fixes
- goto-definition for values, functions, and type declarations
- document symbols for editor outlines
- rename for resolved document-local symbols
- semantic tokens for syntax coloring
