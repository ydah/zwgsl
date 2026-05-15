# Architecture

zwgsl keeps parsing, semantic analysis, target-independent lowering, and backend
emission as separate steps. The goal is to make diagnostics and tooling share as
much compiler behavior as possible while still letting WGSL and GLSL use
different output pipelines.

## Pipeline

```text
Source (.zw)
  -> Lexer
  -> Layout Resolver
  -> Parser
  -> AST
  -> Semantic Analysis
  -> Typed Program
  -> HIR -> MIR -> WGSL
  -> IR         -> GLSL ES 3.0
```

## Frontend

The frontend is shared by CLI, C API, LSP, tests, and wasm.

| Stage | Main files | Responsibility |
| --- | --- | --- |
| Lexer | `src/lexer.zig`, `src/token.zig` | Tokenizes raw source and interns identifiers through `StringPool`. |
| Layout resolver | `src/layout.zig` | Inserts virtual indentation, dedentation, and statement separator tokens. |
| Parser | `src/parser.zig`, `src/ast.zig` | Builds the source-positioned AST. |
| Semantic analysis | `src/sema.zig`, `src/hm.zig`, `src/unify.zig`, `src/typeclass.zig` | Resolves declarations, types, inference, traits, stage rules, and diagnostics. |

Semantic analysis produces a `TypedProgram`. Backend builders should consume the
typed program instead of reparsing source or duplicating semantic checks.

## WGSL Path

WGSL uses the newer multi-stage path:

```text
TypedProgram -> HIR -> MIR -> WGSL
```

| Stage | Main files | Responsibility |
| --- | --- | --- |
| HIR | `src/hir.zig`, `src/hir_builder.zig` | Collects uniforms, structs, specialized helper functions, ADT lowering, and per-stage entry points. |
| MIR | `src/mir.zig`, `src/mir_builder.zig` | Lowers HIR into entry-point-aware control flow, generated bindings, and SSA-style values where possible. |
| WGSL emitter | `src/wgsl_emitter.zig` | Emits WGSL structs, bindings, entry points, helpers, texture lowering, and optional debug comments. |

Resource binding assignment lives in MIR lowering. Sampler uniforms become
separate texture and sampler bindings there, so WGSL emission can work from a
concrete resource list.

## GLSL ES 3.0 Path

GLSL uses the retained render-stage path:

```text
TypedProgram -> IR -> GLSL ES 3.0
```

| Stage | Main files | Responsibility |
| --- | --- | --- |
| IR | `src/ir.zig`, `src/ir_builder.zig` | Builds the GLSL-oriented representation from the typed program. |
| GLSL emitter | `src/glsl_emitter.zig` | Emits GLSL ES 3.0 render-stage output and optional debug comments. |

Compute shaders are rejected before GLSL lowering because GLSL ES 3.0 does not
provide compute shader support.

## Diagnostics

Diagnostics are collected through `src/diagnostics.zig` during parsing and
semantic analysis, then converted to C API errors in `src/compiler.zig`.

Backend-specific failures should report source locations when the lowered
representation carries them. If a diagnostic needs source ownership, prefer
propagating line/column metadata through HIR/MIR instead of reparsing source in
the backend.

## Tooling Surfaces

| Surface | Entry point | Notes |
| --- | --- | --- |
| CLI | `src/cli_main.zig` | Calls the compiler API for `compile` and `check`. |
| C API / wasm | `src/lib.zig` | Exposes native ABI functions and wasm exports over the same compiler API. |
| LSP | `src/lsp/*`, `src/lsp_main.zig` | Reuses lexer/parser/sema for diagnostics and analysis helpers for hover, completion, definition, symbols, and semantic tokens. |
| Playground | `playground/` | Uses the wasm exports and Monaco integration. |
| Tests | `tests/test_runner.zig` | Aggregates focused parser, sema, emitter, LSP, wasm, fixture, and API tests. |

## Change Guidance

- Add syntax in the lexer/parser first, then semantic checks, then lowering.
- Add target-independent checks in `sema.zig` when possible.
- Add WGSL-only behavior in HIR/MIR/WGSL path and document it in the feature
  matrix or gotchas.
- Add fixture tests for generated output and negative tests for diagnostics when
  behavior is user-visible.
