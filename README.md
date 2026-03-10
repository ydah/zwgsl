# zwgsl

A Ruby-inspired shading language that compiles to WGSL and GLSL ES 3.00.
Built with Zig, with an indentation-aware lexer, HM-flavored local inference,
ADT syntax, `match`, dependent dimension type matching, a minimal LSP server,
and a browser playground scaffold.

## Why zwgsl?

Shader languages are powerful, but they are rarely pleasant to read or write.
`zwgsl` keeps shader code close to Ruby-style control flow:

- `end` blocks instead of braces
- layout-aware indentation and implicit statement separators
- method chains and postfix conditionals
- `let` bindings and `where` clauses
- algebraic `type` definitions and `match` expressions

## Feature Snapshot

- Ruby-like syntax with `def`, `do`, `end`, symbols, postfix `if` / `unless`
- Layout resolver that inserts virtual indent / dedent / statement separators
- `let` bindings, immutable locals, and function-level `where` clauses
- Local HM inference for lambda-heavy `let` bindings
- Algebraic data type declarations and constructor registration
- `match` parsing and semantic checking, including constructor patterns and non-exhaustive warnings
- Dependent-dimension-aware type matching for signatures such as `Vec(N)` and `Mat(M, N)`
- Generic struct parsing and generic function signature matching
- WGSL emission path staged through `HIR -> MIR` wrapper modules
- GLSL ES 3.00 and WGSL backends
- Standalone LSP server target: `zwgsl-lsp`
- Vite + Monaco playground scaffold under [`playground/`](./playground)

## Example

```ruby
uniform :mvp, Mat4

vertex do
  input :position, Vec3, location: 0

  def main
    gl_Position = mvp * vec4(position, 1.0)
  end
end

fragment do
  output :frag_color, Vec4, location: 0

  def main
    frag_color = vec4(0.9, 0.5, 0.2, 1.0)
  end
end
```

## Build

Build libraries and the LSP server:

```sh
zig build
```

Run the test suite:

```sh
zig build test
```

Build the freestanding wasm-targeted library artifact:

```sh
zig build wasm
```

## Artifacts

`zig build` installs:

- `zig-out/lib/libzwgsl.a`
- `zig-out/lib/libzwgsl.dylib` or platform equivalent
- `zig-out/include/zwgsl.h`
- `zig-out/bin/zwgsl-lsp`

## C API

```c
#include "zwgsl.h"

ZwgslOptions options = {
    .target = ZWGSL_TARGET_WGSL,
};

ZwgslResult result = zwgsl_compile(source, source_len, options);
if (result.error_count == 0) {
    puts(result.vertex_source);
}
zwgsl_free(&result);
```

## LSP

The server entry point lives at [`src/lsp/server.zig`](./src/lsp/server.zig).
The current implementation supports:

- `initialize`
- `shutdown`
- full-sync `didOpen` / `didChange` / `didClose`
- basic `hover`
- basic `completion`
- basic `definition`
- basic `semanticTokens/full`
- publish-diagnostics notifications based on compiler errors

## Playground

The playground scaffold lives under [`playground/`](./playground).

```sh
cd playground
npm install
npm run dev
```

It currently provides:

- Monaco editor bootstrapping
- WGSL output panel
- WebGPU preview canvas
- worker-based diagnostics hook
- wasm loader placeholder at `playground/public/zwgsl.wasm`

## Status

| Area | Status |
| --- | --- |
| Lexer + layout | Implemented |
| Parser | Implemented |
| HM local inference | Implemented for local lambdas / let-polymorphism |
| ADT + match typing | Implemented |
| Dependent dimension matching | Implemented for signature / call matching |
| Generic struct parsing | Implemented |
| Trait / impl basis | Minimal parser + constraint registry |
| WGSL HIR / MIR staging | Thin wrapper layers in place |
| LSP server | Minimal implementation |
| Playground | Scaffold in place |

## Repository Layout

```text
src/
  ast.zig
  compiler.zig
  hir.zig
  hir_builder.zig
  ir.zig
  ir_builder.zig
  lsp/
  mir.zig
  mir_builder.zig
  parser.zig
  sema.zig
  typeclass.zig
  wgsl_emitter.zig
tests/
examples/
playground/
include/
```

## License

MIT
