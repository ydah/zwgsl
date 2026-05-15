# Gotchas

This page lists practical constraints that can surprise shader authors coming
from Ruby, WGSL, or GLSL. It focuses on behavior that is intentionally part of
the current implementation.

## Ruby-Like, Not Ruby Runtime

zwgsl borrows surface syntax from Ruby, but it compiles to static shader code.
There is no dynamic dispatch, exception handling, runtime object model, or
escaping closure support on the GPU path.

Use Ruby-like flow for readability, but keep the mental model close to WGSL:
typed values, explicit resources, stage entry points, and static lowering.

## WGSL Is The Primary Target

WGSL has the broadest coverage and is the playground preview target. GLSL ES 3.0
is retained for render-stage output, but it is not a full mirror of the WGSL
backend.

- Compute shaders are WGSL-only.
- Some advanced type-system features are checked before backend lowering, but
  only have WGSL golden fixture coverage today.
- GLSL `version` and `precision` declarations do not affect WGSL output.

## Generated And Target Identifier Names

Names beginning with `_zwgsl` are reserved for compiler-generated WGSL helpers,
entry-point wrappers, and uniform wrapper structs. Source code that declares a
uniform, function, local binding, type, trait, field, variant, stage I/O, or
pattern binding with that prefix receives a semantic warning.

Names that collide with WGSL reserved words or target-side builtin type names,
such as `array`, `var`, `fn`, or `vec3f`, also receive a warning. Prefer names
that are valid and unambiguous in generated WGSL.

Prefer project-specific prefixes for host-facing names. Generated WGSL may still
contain `_zwgsl` names, but user source should avoid that namespace so future
compiler helpers can be added without colliding with shader code.

## Stage Interfaces Must Match

Vertex `varying` declarations become fragment inputs. Names, types, and explicit
locations need to line up between stages.

```ruby
vertex do
  varying :v_normal, Vec3, location: 0
end

fragment do
  varying :v_normal, Vec3, location: 0
end
```

The compiler validates missing varyings, mismatched varying types, and
location compatibility. If a varying uses an explicit location, both stage
declarations must specify the same value. When both locations are omitted,
zwgsl assigns them in declaration order. Keep related vertex and fragment
declarations close together in examples and fixtures so location drift is easy
to see.

## Uniform Binding Order Matters

WGSL resources are assigned to `@group(0)` in declaration order.

```ruby
uniform :camera, Mat4      # group 0, binding 0
uniform :base_color, Vec4  # group 0, binding 1
```

Changing global uniform order changes generated WGSL bindings. There is no
explicit `group` / `binding` source syntax yet, so host applications should keep
their bind group layout in sync with source order.

`Sampler2D` uniforms lower to a texture and sampler pair in WGSL, so they consume
two bindings. Numeric scalar and vector uniforms may be wrapped to satisfy WGSL
uniform layout rules.

## Stage Output Writes

Vertex varyings are clearest when written through `self`.

```ruby
self.v_normal = normal
```

Fragment outputs can be assigned directly because they are the stage result
values.

```ruby
frag_color = vec4(v_normal.normalize, 1.0)
```

This keeps vertex output writes visibly separate from local variables while
matching the current examples and language reference.

## Texture Sampling Has Source Limits

`Sampler2D` lowering is supported for uniforms, function parameters, and
immutable local aliases. Prefer passing sampler resources explicitly to helper
functions, or bind them as uniforms and sample them directly.

Complex resource indirection is intentionally avoided because the backend must
emit concrete WGSL texture and sampler handles.

## Implicit Returns Are For Expressions

Helper functions can return the final expression implicitly.

```ruby
def saturate(value: Float) -> Float
  clamp(value, 0.0, 1.0)
end
```

Stage `main` functions are usually assignment-oriented: write `gl_Position`,
varyings, fragment outputs, or compute results. That makes the generated entry
point shape predictable.

## Playground Preview Is Render-Oriented

The playground compiles compute shaders and shows generated WGSL, but the live
preview surface is built around render pipelines. Compute-only samples are useful
for checking language features and diagnostics, not for visual preview.

If WebGPU is unavailable, the playground still loads the editor, compiler, WGSL
output, and diagnostics. The canvas falls back to a static 2D surface until the
page runs in a browser with `navigator.gpu` enabled.
