# zwgsl

A Ruby-inspired shading language that compiles to WGSL (WebGPU) and GLSL ES 3.0.
Built with Zig for fast compilation, a small runtime surface, and tooling that can
ship as a native library, an LSP server, or a browser wasm module.

## Why zwgsl?

GPU shading languages are powerful, but the authoring experience is usually rigid:
braces everywhere, repetitive type annotations, and weak structure for reusable
shader logic. `zwgsl` keeps shader code close to Ruby-style flow and expression
syntax while still targeting modern GPU backends.

- `end` blocks instead of braces
- layout-aware indentation and implicit statement separators
- method chains, postfix conditionals, and implicit returns
- `let` bindings, `where` clauses, `type`, `match`, `trait`, and `impl`
- WGSL-first output with a retained GLSL ES 3.0 path

## Features

- Ruby-like syntax with `def`, `do`, `end`, symbols, method calls, and postfix `if` / `unless`
- Indentation-sensitive layout resolver that inserts virtual indent / dedent / statement separators
- `let` bindings and function-local `where` clauses
- HM-style local type inference with let-generalization
- Algebraic data types and constructor registration
- Pattern matching with constructor, wildcard, binding, literal, and guarded arms
- Dependent dimension matching for `Vec(N)`, `Mat(M, N)`, and tensor-style type applications
- Generic structs, constructor inference, and phantom-type-safe annotations
- `trait` / `impl` support with compile-time specialization for WGSL emission
- Multi-stage WGSL pipeline: `AST -> HIR -> MIR -> WGSL`
- Source-aware LSP support: diagnostics, hover, completion, goto-definition, semantic tokens
- Browser playground with Monaco, wasm compilation, and worker-backed diagnostics
- C API surface for embedding the compiler in other tools

## Quick Example

`zwgsl` source:

```ruby
version "300 es"
precision :fragment, :highp

uniform :model_matrix, Mat4
uniform :view_matrix, Mat4
uniform :projection_matrix, Mat4
uniform :light_pos, Vec3
uniform :base_color, Vec4

def phong_strength(normal: Vec3, light_dir: Vec3) -> Float
  max(dot(normal.normalize, light_dir.normalize), 0.0)
end

vertex do
  input :position, Vec3, location: 0
  input :normal, Vec3, location: 1
  varying :v_normal, Vec3
  varying :v_world_pos, Vec3

  def main
    world_pos = model_matrix * vec4(position, 1.0)
    self.v_normal = mat3(model_matrix) * normal
    self.v_world_pos = world_pos.xyz
    gl_Position = projection_matrix * view_matrix * world_pos
  end
end

fragment do
  varying :v_normal, Vec3
  varying :v_world_pos, Vec3
  output :frag_color, Vec4, location: 0

  def main
    light_dir = light_pos - v_world_pos
    light = phong_strength(v_normal, light_dir)
    frag_color = vec4(base_color.rgb * (0.2 + 0.8 * light), base_color.a)
  end
end
```

Compiled WGSL vertex output:

```wgsl
struct VertexInput {
    @location(0) position: vec3f,
    @location(1) normal: vec3f,
};

struct VertexOutput {
    @builtin(position) gl_Position: vec4f,
    @location(0) v_normal: vec3f,
    @location(1) v_world_pos: vec3f,
};

@group(0) @binding(0) var<uniform> model_matrix: mat4x4f;
@group(0) @binding(1) var<uniform> view_matrix: mat4x4f;
@group(0) @binding(2) var<uniform> projection_matrix: mat4x4f;
@group(0) @binding(3) var<uniform> light_pos: vec3f;
@group(0) @binding(4) var<uniform> base_color: vec4f;

var<private> gl_Position: vec4f;
var<private> position: vec3f;
var<private> normal: vec3f;
var<private> v_normal: vec3f;
var<private> v_world_pos: vec3f;

fn phong_strength(normal: vec3f, light_dir: vec3f) -> f32 {
    return max(dot(normalize(normal), normalize(light_dir)), 0.0);
}

fn __zwgsl_vertex_main() {
    var world_pos: vec4f = model_matrix * vec4f(position, 1.0);
    v_normal = mat3x3f(model_matrix) * normal;
    v_world_pos = world_pos.xyz;
    gl_Position = projection_matrix * view_matrix * world_pos;
}

@vertex
fn main(input: VertexInput) -> VertexOutput {
    position = input.position;
    normal = input.normal;
    __zwgsl_vertex_main();
    var output: VertexOutput;
    output.gl_Position = gl_Position;
    output.v_normal = v_normal;
    output.v_world_pos = v_world_pos;
    return output;
}
```

Compiled WGSL fragment output:

```wgsl
struct FragmentInput {
    @location(0) v_normal: vec3f,
    @location(1) v_world_pos: vec3f,
};

struct FragmentOutput {
    @location(0) frag_color: vec4f,
};

@group(0) @binding(0) var<uniform> model_matrix: mat4x4f;
@group(0) @binding(1) var<uniform> view_matrix: mat4x4f;
@group(0) @binding(2) var<uniform> projection_matrix: mat4x4f;
@group(0) @binding(3) var<uniform> light_pos: vec3f;
@group(0) @binding(4) var<uniform> base_color: vec4f;

var<private> v_normal: vec3f;
var<private> v_world_pos: vec3f;
var<private> frag_color: vec4f;

fn phong_strength(normal: vec3f, light_dir: vec3f) -> f32 {
    return max(dot(normalize(normal), normalize(light_dir)), 0.0);
}

fn __zwgsl_fragment_main() {
    var light_dir: vec3f = light_pos - v_world_pos;
    var light: f32 = phong_strength(v_normal, light_dir);
    frag_color = vec4f(base_color.rgb * (0.2 + 0.8 * light), base_color.a);
}

@fragment
fn main(input: FragmentInput) -> FragmentOutput {
    v_normal = input.v_normal;
    v_world_pos = input.v_world_pos;
    __zwgsl_fragment_main();
    var output: FragmentOutput;
    output.frag_color = frag_color;
    return output;
}
```

## Advanced Examples

Pattern matching over ADTs:

```ruby
type Shape
  Circle(radius: Float)
  Rect(width: Float, height: Float)
  Point
end

def area(shape: Shape) -> Float
  match shape
  when Circle(radius)
    3.14159 * radius * radius
  when Rect(width, height)
    width * height
  when Point
    0.0
  end
end

compute do
  def main
    value: Float = area(Circle(2.0))
  end
end
```

Dependent dimensions that lower to fixed-size WGSL types:

```ruby
compute do
  def main
    transform: Mat(4, 4) = mat4(1.0)
    value: Vec(4) = vec4(1.0)
    energy: Float = dot(value, value)
  end
end
```

Trait-constrained specialization:

```ruby
trait Numeric
  def add(other: Self) -> Self end
  def mul(other: Self) -> Self end
end

impl Numeric for Float
  def add(other: Self) -> Self
    self + other
  end

  def mul(other: Self) -> Self
    self * other
  end
end

def lerp(a: T, b: T, t: Float) -> T where T: Numeric
  a.mul(1.0 - t).add(b.mul(t))
end

compute do
  def main
    value: Float = lerp(1.0, 2.0, 0.5)
  end
end
```

## Installation

### From Source

Requires Zig 0.13.x or newer.

```sh
git clone https://github.com/yourname/zwgsl
cd zwgsl
zig build -Doptimize=ReleaseFast
```

### Test Suite

```sh
zig build test
```

### Browser Wasm Build

```sh
zig build wasm
```

That installs `zig-out/bin/zwgsl.wasm`, which the playground syncs into
`playground/public/zwgsl.wasm`.

## Artifacts

`zig build` installs:

- `zig-out/lib/libzwgsl.a`
- `zig-out/lib/libzwgsl.dylib` or the platform equivalent shared library
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
    if (result.vertex_source != NULL) {
        puts(result.vertex_source);
    }
    if (result.fragment_source != NULL) {
        puts(result.fragment_source);
    }
    if (result.compute_source != NULL) {
        puts(result.compute_source);
    }
}

zwgsl_free(&result);
```

## LSP

The server entry point is `zwgsl-lsp`, implemented under `src/lsp/`.
Current editor-facing features:

- full-sync `didOpen` / `didChange` / `didClose`
- diagnostics from compiler errors and warnings
- hover with source-aware type / declaration info
- completion for locals, declarations, builtins, fields, and methods
- goto-definition for values, functions, and type declarations
- semantic tokens for keywords, functions, variables, types, numbers, strings, comments, operators, and properties

## Playground

The playground lives under `playground/` and uses Monaco plus the real wasm compiler build.

```sh
cd playground
npm install
npm run dev
```

Current capabilities:

- Monaco language registration for `zwgsl`
- live WGSL compilation through `zwgsl.wasm`
- worker-backed diagnostics, hover, completion, and goto-definition
- WebGPU preview surface with animated `iTime` / `iResolution` uniforms and generated controls
- `npm run sync-wasm` to refresh the wasm payload from `zig-out/bin/zwgsl.wasm`

## Architecture

```text
Source (.zw)
  │
  ▼
Lexer -> Layout Resolver -> Parser -> AST
                                    │
                                    ▼
                            HM Inference + Sema
                                    │
                                    ▼
                                Typed AST
                               /        \
                              /          \
                           HIR            IR
                            │             │
                            ▼             ▼
                           MIR       GLSL Emitter
                            │             │
                            ▼             ▼
                      WGSL Emitter      GLSL ES 3.0
```

## Project Status

| Area | Status |
| --- | --- |
| Lexer + layout resolver | Implemented |
| Parser + source positions | Implemented |
| `let` / `where` | Implemented |
| HM-style local inference | Implemented for local bindings and let-generalization |
| ADTs + pattern matching | Implemented |
| Dependent dimensions | Implemented for `Vec(N)` / `Mat(M, N)` matching and WGSL type lowering |
| Generic structs + phantom tags | Implemented |
| `trait` / `impl` specialization | Implemented as compile-time static dispatch |
| WGSL pipeline | Implemented as `AST -> HIR -> MIR -> WGSL` |
| GLSL ES 3.0 backend | Implemented |
| LSP | Implemented |
| Playground | Implemented |

## Repository Layout

```text
src/
  ast.zig
  compiler.zig
  hir.zig
  hir_builder.zig
  ir.zig
  ir_builder.zig
  layout.zig
  lsp/
  mir.zig
  mir_builder.zig
  parser.zig
  sema.zig
  typeclass.zig
  wgsl_emitter.zig
tests/
  fixtures/
examples/
playground/
include/
```

## License

MIT
