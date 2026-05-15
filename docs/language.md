# zwgsl Language Reference

This document describes the implemented zwgsl surface syntax at a practical
level. The README remains the project overview; this reference is for users who
want to write or review shaders without reading compiler internals.

## Design Model

zwgsl is Ruby-inspired syntax for statically compiled shader programs. It is not
a Ruby runtime and does not provide dynamic dispatch, exceptions, runtime
objects, or closures that escape into GPU execution.

Core rules:

- Blocks use `do` / `end` or `def` / `end`.
- Layout resolution inserts statement separators from indentation and newlines.
- The compiler performs static semantic checks before emitting WGSL or GLSL.
- Functions and trait methods are compiled into target shader code.
- WGSL is the primary backend; GLSL ES 3.0 is retained as a render-stage backend.

See [Gotchas](gotchas.md) for target-specific constraints and
[Design Notes](design-notes.md) for the language boundaries behind these rules.

## Top-Level Items

### Version And Precision

```ruby
version "300 es"
precision :fragment, :highp
```

`version` and `precision` are mainly relevant to GLSL ES output. WGSL output
does not use GLSL version or precision declarations.

### Uniforms

```ruby
uniform :mvp, Mat4
uniform :base_color, Vec4
uniform :scene_tex, Sampler2D
```

Uniforms are declared globally and are visible to shader stages and helper
functions. WGSL output assigns `@group(0)` bindings in declaration order.
Sampler uniforms are lowered to texture/sampler binding pairs in WGSL.

### Structs

```ruby
struct Light
  color: Vec3
  intensity: Float
end

struct TaggedColor(Space)
  value: Vec3
end
```

Structs may be generic. Generic parameters can also be used as phantom tags for
type-level distinctions that do not necessarily become runtime data.

### Algebraic Data Types

```ruby
type Shape
  Circle(radius: Float)
  Rect(width: Float, height: Float)
  Point
end
```

ADT constructors are registered as values. Pattern matching can inspect
constructors and bind constructor fields.

### Functions

```ruby
def lambert(normal: Vec3, light_dir: Vec3) -> Float
  max(dot(normal.normalize, light_dir.normalize), 0.0)
end
```

Function bodies return the final expression implicitly when a return type is
declared. Assignment-oriented stage `main` functions usually write to stage
outputs instead.

Function-local `where` clauses define helper bindings after the body:

```ruby
def shade(normal: Vec3) -> Float
  ambient + diffuse
where
  diffuse = max(dot(normal, light_dir), 0.0)
  ambient = 0.1
  light_dir = normalize(vec3(1.0, 1.0, 1.0))
end
```

### Traits And Impls

```ruby
trait Numeric
  def add(other: Self) -> Self end
end

impl Numeric for Float
  def add(other: Self) -> Self
    self + other
  end
end

def choose(a: T, b: T) -> T where T: Numeric
  a.add(b)
end
```

Traits are statically resolved and specialized at compile time. They are useful
for reusable shader utilities without runtime dispatch.

## Shader Stages

### Vertex

```ruby
vertex do
  input :position, Vec3, location: 0
  varying :v_pos, Vec3

  def main
    self.v_pos = position
    gl_Position = vec4(position, 1.0)
  end
end
```

Vertex stages can declare `input` attributes and `varying` outputs. Assigning
through `self.varying_name` makes stage output writes explicit.

### Fragment

```ruby
fragment do
  varying :v_pos, Vec3
  output :frag_color, Vec4, location: 0

  def main
    frag_color = vec4(v_pos, 1.0)
  end
end
```

Fragment stages can declare matching `varying` inputs and explicit `output`
locations. The compiler validates stage interface compatibility.

### Compute

```ruby
compute do
  def main
    id: UVec3 = global_invocation_id
  end
end
```

Compute shaders are emitted for WGSL only. Built-in compute values include
`global_invocation_id`, `local_invocation_id`, `workgroup_id`,
`num_workgroups`, and `local_invocation_index`.

## Statements And Expressions

### Bindings And Assignment

```ruby
let immutable_color: Vec3 = vec3(1.0, 0.0, 0.0)
total: Float = 0.0
total += 1.0
```

`let` bindings are immutable. Typed assignment introduces mutable locals.

### Conditionals

```ruby
frag_color = vec4(1.0) if debug
discard unless alpha > 0.01
```

Postfix `if` and `unless` are supported for compact shader guard code.

### Loops

```ruby
3.times do |i|
  total += values[i]
end

position.each do |component|
  total += component
end
```

`times` loops and vector `each` loops are supported in the compiler pipeline.

### Match

```ruby
def area(shape: Shape) -> Float
  match shape
  when Circle(radius)
    3.14159 * radius * radius
  when Rect(width, height)
    width * height
  when _
    0.0
  end
end
```

Patterns include constructors, bindings, literals, symbols, and `_` wildcard.
Arms can have guards:

```ruby
match value
when positive if value > 0.0
  value
when _
  0.0
end
```

The semantic checker reports non-exhaustive ADT matches.

## Types

Common built-in names include:

| zwgsl | WGSL-style meaning | GLSL-style meaning |
| --- | --- | --- |
| `Bool` | `bool` | `bool` |
| `Float` | `f32` | `float` |
| `Int` | `i32` | `int` |
| `UInt` | `u32` | `uint` |
| `Vec2`, `Vec3`, `Vec4` | `vec2f`, `vec3f`, `vec4f` | `vec2`, `vec3`, `vec4` |
| `IVec2`, `IVec3`, `IVec4` | signed integer vectors | signed integer vectors |
| `UVec2`, `UVec3`, `UVec4` | unsigned integer vectors | unsigned integer vectors |
| `Mat3`, `Mat4` | float matrices | float matrices |
| `Sampler2D` | texture/sampler pair | `sampler2D` |

Dependent dimension forms are supported for fixed-size vector and matrix
matching:

```ruby
def same_dim(a: Vec(N), b: Vec(N)) -> Float
  dot(a, b)
end

transform: Mat(4, 4) = mat4(1.0)
value: Vec(4) = vec4(1.0)
```

## Target Notes

- WGSL supports vertex, fragment, and compute output.
- GLSL ES 3.0 supports vertex and fragment output.
- GLSL ES 3.0 does not support compute shaders in this compiler.
- WGSL scalar and short-vector uniforms may be wrapped to satisfy layout rules.
- `Sampler2D` lowering differs by target: WGSL emits separate texture and
  sampler bindings, while GLSL ES emits `sampler2D`.
