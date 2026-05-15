# Feature Matrix

This matrix tracks implemented project capabilities across compiler targets and
tooling surfaces. It is intentionally about current behavior, not a roadmap.

Legend:

- Yes: implemented for that surface.
- Partial: implemented with target-specific limits.
- No: not currently supported for that surface.
- N/A: not applicable.

## Language And Compiler

| Feature | WGSL | GLSL ES 3.0 | LSP | Playground |
| --- | --- | --- | --- | --- |
| Ruby-like `def` / `do` / `end` blocks | Yes | Yes | Diagnostics, tokens | Yes |
| Layout-aware statement separation | Yes | Yes | Diagnostics | Yes |
| Function parameters and return annotations | Yes | Yes | Hover, completion | Yes |
| Implicit final-expression returns | Yes | Yes | Diagnostics | Yes |
| Method chains | Yes | Yes | Hover, completion | Yes |
| Postfix `if` / `unless` | Yes | Yes | Diagnostics | Yes |
| `let` immutable bindings | Yes | Yes | Diagnostics | Yes |
| Function-local `where` clauses | Yes | Yes | Diagnostics | Yes |
| Lambdas for local inference cases | Yes | Yes | Diagnostics | Yes |
| Structs | Yes | Yes | Hover, completion | Yes |
| Generic structs | Yes | Yes | Diagnostics | Yes |
| Phantom type parameters | Yes | Yes | Diagnostics | Yes |
| Algebraic data types | Yes | Yes | Diagnostics | Yes |
| Pattern matching | Yes | Yes | Diagnostics | Yes |
| Guarded match arms | Yes | Yes | Diagnostics | Yes |
| Non-exhaustive match diagnostics | Yes | Yes | Diagnostics | Yes |
| Traits and impls | Yes | Yes | Diagnostics | Yes |
| Trait-constrained functions | Yes | Yes | Diagnostics | Yes |
| Static trait method specialization | Yes | Yes | Hover, completion | Yes |
| `Vec(N)` dependent dimensions | Yes | No output coverage | Diagnostics | Yes |
| `Mat(M, N)` dependent dimensions | Yes | No output coverage | Diagnostics | Yes |
| Vector `each` loops | Yes | Yes | Diagnostics | Yes |
| `N.times` loops | Yes | Yes | Diagnostics | Yes |
| Debug comments in output | Yes | Yes | N/A | Via wasm API option only |
| Optimized output formatting | Yes | Yes | N/A | Via wasm API option only |

## Shader Stages And Resources

| Feature | WGSL | GLSL ES 3.0 | LSP | Playground |
| --- | --- | --- | --- | --- |
| Vertex stage | Yes | Yes | Diagnostics, tokens | Preview |
| Fragment stage | Yes | Yes | Diagnostics, tokens | Preview |
| Compute stage | Yes | No | Diagnostics, tokens | Compile output only |
| Vertex inputs with locations | Yes | Yes | Diagnostics | Preview attribute synthesis |
| Fragment outputs with locations | Yes | Yes | Diagnostics | Preview render target |
| Varying interface validation | Yes | Yes | Diagnostics | Yes |
| Global uniforms | Yes | Yes | Completion | Generated controls for supported numeric uniforms |
| Scalar/vector uniform layout wrapping | Yes | N/A | N/A | Yes |
| `Sampler2D` uniforms | Yes | Yes | Completion | Placeholder texture/sampler |
| Sampler parameters | Yes | Yes | Diagnostics | Yes |
| Immutable sampler aliases | Yes | N/A | Diagnostics | Yes |
| Compute builtins | Yes | No | Completion | Compile output only |
| Stage mixing validation | Yes | Yes | Diagnostics | Yes |

## Tooling

| Surface | Status |
| --- | --- |
| Native library | Static and shared `libzwgsl` artifacts are installed by `zig build`. |
| C API | `zwgsl_compile`, `zwgsl_free`, `zwgsl_version`, `zwgsl_abi_version`, and `zwgsl_options_default` are exposed in `include/zwgsl.h`. |
| CLI | `zwgsl compile` and `zwgsl check` are available as `zig-out/bin/zwgsl`. |
| LSP server | `zwgsl-lsp` supports diagnostics, hover, completion, goto-definition, document symbols, and semantic tokens. |
| Browser wasm | `zig build wasm` emits `zig-out/bin/zwgsl.wasm`. |
| Playground | Monaco editor, compiler-backed diagnostics, WGSL output, URL-addressable sample selector, and WebGPU preview. |
| CI | Zig formatting, Zig tests, native build, wasm build, and playground build run in GitHub Actions. |

## Target Compatibility Notes

- WGSL is the primary target and has coverage for render and compute shaders.
- GLSL ES 3.0 is a render-stage target; compute shaders are rejected for this
  target.
- Implemented builtin types and functions are listed in [Builtins](builtins.md).
- Some advanced type-system features are target-independent during semantic
  analysis but only have golden output coverage for WGSL fixtures today.
- Playground preview is render-pipeline oriented. Compute-only shaders compile,
  but they do not currently render a preview surface.

For authoring pitfalls around stage interfaces, uniform layout, sampler lowering,
and preview behavior, see [Gotchas](gotchas.md).
