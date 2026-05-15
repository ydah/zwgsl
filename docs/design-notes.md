# Design Notes

zwgsl is intentionally small in runtime surface and broad in authoring support.
These notes explain the boundaries behind that tradeoff.

## Design Principles

- Ruby-like syntax should make shader code easier to scan, not turn Ruby into a
  GPU runtime.
- Semantics should stay shader-safe: static types, explicit resources, and
  compile-time specialization.
- WGSL is the primary output target. GLSL ES 3.0 support is valuable, but it must
  not force the language away from WebGPU.
- Tooling matters as much as syntax. CLI, LSP, docs, examples, and playground
  behavior should all describe the same implemented language.

## Why Not Just WGSL?

WGSL is a good target language, but it is intentionally low-level for authoring.
zwgsl adds a higher-level authoring layer while keeping generated output close to
ordinary shader code.

```ruby
def lambert(normal: Vec3, light_dir: Vec3) -> Float
  max(dot(normal.normalize, light_dir.normalize), 0.0)
end
```

The important additions are local type inference, method-chain syntax, reusable
traits and helpers, ADTs with pattern matching, and stage DSL declarations. The
compiler still emits concrete WGSL entry points and resources.

## Why Not Rust Or A General GPU DSL?

zwgsl is focused on shader authoring rather than general GPU programming. It
does not try to expose ownership, host-device memory management, kernel launch
APIs, or a full application language.

The goal is a compact language that shader authors can read quickly, embed in
tools, and inspect through generated WGSL or GLSL.

## Comparison Snapshot

| Choice | Strength | Tradeoff |
| --- | --- | --- |
| WGSL | Direct WebGPU target with browser validation and clear resource semantics. | More ceremony for reusable helpers, stage wiring, and authoring ergonomics. |
| GLSL ES 3.0 | Familiar render-shader syntax with wide historical usage. | Not a compute target here, and WebGPU still needs WGSL-oriented resource semantics. |
| Rust-style GPU DSLs | Strong host-language integration and general GPU programming models. | More concepts than zwgsl needs for compact shader authoring and generated-source inspection. |
| zwgsl | Ruby-like syntax, local inference, traits, ADTs, LSP, playground, and WGSL-first output. | A focused shader language, not a replacement for every backend feature or host GPU API. |

## Inference Is Local On Purpose

The type checker supports HM-style local inference and let-generalization, but
zwgsl keeps stage/resource boundaries explicit. This avoids surprising generated
interfaces and keeps LSP diagnostics tied to source declarations.

Explicit annotations are still preferred for public shader boundaries:
uniforms, inputs, outputs, varyings, and exported-style helper signatures.

## Traits Are Static Dispatch

`trait` and `impl` are a reuse mechanism for shader utilities. They are resolved
and specialized at compile time, then lowered into target shader functions.

There is no runtime vtable or dynamic receiver lookup. This keeps generated
shader code predictable and compatible with GPU execution.

## Non-Goals

- Running Ruby code on the GPU.
- Providing a render engine, scene graph, material system, or host graphics API.
- Hiding shader resource layout from host applications.
- Guaranteeing every WGSL feature has GLSL ES 3.0 output.
- Replacing backend validators or browser pipeline validation.

## Compatibility Strategy

When a feature can be target-independent, zwgsl should check it before backend
lowering. When a feature is target-specific, docs, diagnostics, and the feature
matrix should say so directly.

This keeps the language honest: users can see which capabilities are stable
across targets and which ones are WGSL-first.
