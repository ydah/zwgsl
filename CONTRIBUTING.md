# Contributing

Thanks for helping improve zwgsl. This project is still small enough that
focused, well-tested changes are much easier to review than broad rewrites.

## Development Requirements

- Zig 0.15.x. CI currently uses Zig 0.15.2.
- Node.js 24 for the playground.
- npm for `playground/package-lock.json` based installs.

## Local Setup

```sh
zig build
zig build test

cd playground
npm ci
npm run build
```

`zig build` installs the native library, `zwgsl-lsp`, and the `zwgsl` CLI under
`zig-out`. `npm run build` rebuilds the wasm compiler before running Vite.

## Quality Checks

Run the checks that match the surface you changed:

```sh
zig fmt --check build.zig build.zig.zon src tests
zig build test
zig build
zig build wasm
```

For playground changes:

```sh
cd playground
npm ci
npm run build
```

For VS Code extension changes:

```sh
node --check editors/vscode/extension.js
```

CI runs Zig formatting, Zig tests, native build, wasm build, dependency install,
and playground build.

## Testing Guidance

- Add semantic negative tests when diagnostics or type checking changes.
- Add golden fixtures when generated WGSL or GLSL output changes.
- Update README example tests when changing README shader snippets.
- Keep fixture updates intentional and review the generated output before
  accepting it.
- For playground behavior, prefer compiler-backed fixtures or TypeScript checks
  before adding manual UI-only changes.

## Documentation Guidance

Update documentation when behavior or user-facing commands change:

- `docs/language.md` for implemented syntax and semantics.
- `docs/builtins.md` for builtin types, functions, and stage values.
- `docs/feature-matrix.md` for target and tooling support.
- `docs/gotchas.md` for target-specific constraints.
- `docs/c-api.md` and `include/zwgsl.h` together for C API changes.
- `examples/README.md` when adding or changing examples.

Avoid documenting planned behavior as implemented behavior. Use
`ROADMAP.md` for future work.

## Pull Request Shape

- Keep changes scoped to one concern when practical.
- Include tests or explain why the change is documentation-only.
- Note any target-specific limits, especially WGSL-only or GLSL ES 3.0 gaps.
- Do not commit generated build output from `zig-out` or playground build
  artifacts.
- Report security-sensitive issues through `SECURITY.md` instead of public
  issue details.
