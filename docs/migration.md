# Migration From WGSL And GLSL

This guide maps common WGSL and GLSL authoring patterns to zwgsl. It is a manual
migration guide, not an automatic converter.

## Migration Strategy

1. Keep the shader shape first: stages, inputs, varyings, outputs, uniforms, and
   texture resources.
2. Port helper functions next, using zwgsl type names and final-expression
   returns where they stay clear.
3. Replace repeated shader utility patterns with helper functions, `where`
   bindings, or traits only after the direct port compiles.
4. Compile to WGSL first, then check GLSL ES 3.0 only if the shader is a render
   pipeline and avoids WGSL-only features such as compute.

## Type Names

| WGSL | GLSL ES 3.0 | zwgsl |
| --- | --- | --- |
| `f32` | `float` | `Float` |
| `i32` | `int` | `Int` |
| `u32` | `uint` | `UInt` |
| `bool` | `bool` | `Bool` |
| `vec2f` | `vec2` | `Vec2` |
| `vec3f` | `vec3` | `Vec3` |
| `vec4f` | `vec4` | `Vec4` |
| `vec2i` | `ivec2` | `IVec2` |
| `vec3i` | `ivec3` | `IVec3` |
| `vec4i` | `ivec4` | `IVec4` |
| `vec2u` | `uvec2` | `UVec2` |
| `vec3u` | `uvec3` | `UVec3` |
| `vec4u` | `uvec4` | `UVec4` |
| `mat4x4f` | `mat4` | `Mat4` |
| texture + sampler pair | `sampler2D` | `Sampler2D` |

See [Builtins](builtins.md) for the complete implemented type/function list.

## Resources

WGSL:

```wgsl
@group(0) @binding(0) var<uniform> mvp: mat4x4f;
@group(0) @binding(1) var scene_tex_texture: texture_2d<f32>;
@group(0) @binding(2) var scene_tex_sampler: sampler;
```

GLSL:

```glsl
uniform mat4 mvp;
uniform sampler2D scene_tex;
```

zwgsl:

```ruby
uniform :mvp, Mat4
uniform :scene_tex, Sampler2D
```

WGSL bindings are assigned from declaration order. `Sampler2D` consumes a
texture binding and a sampler binding in WGSL output.

## Stage Interfaces

GLSL:

```glsl
layout(location = 0) in vec3 position;
out vec2 v_uv;

void main() {
    v_uv = position.xy;
    gl_Position = vec4(position, 1.0);
}
```

zwgsl:

```ruby
vertex do
  input :position, Vec3, location: 0
  varying :v_uv, Vec2

  def main
    self.v_uv = position.xy
    gl_Position = vec4(position, 1.0)
  end
end
```

Use `self.varying_name = ...` for vertex varying writes. Fragment outputs are
ordinary stage outputs:

```ruby
fragment do
  varying :v_uv, Vec2
  output :frag_color, Vec4, location: 0

  def main
    frag_color = vec4(v_uv, 0.0, 1.0)
  end
end
```

The compiler validates stage interface names, types, and explicit locations.

## Helper Functions

WGSL:

```wgsl
fn saturate(x: f32) -> f32 {
    return clamp(x, 0.0, 1.0);
}
```

GLSL:

```glsl
float saturate(float x) {
    return clamp(x, 0.0, 1.0);
}
```

zwgsl:

```ruby
def saturate(x: Float) -> Float
  clamp(x, 0.0, 1.0)
end
```

The final expression is returned implicitly when the function has a return type.

## Method Chains

Many builtin calls can be written as free functions or receiver methods.

```ruby
light = max(dot(normal.normalize, light_dir.normalize), 0.0)
```

This lowers to normal builtin calls in generated WGSL/GLSL.

## Texture Sampling

GLSL:

```glsl
vec4 color = texture(scene_tex, uv);
```

WGSL:

```wgsl
let color = textureSample(scene_tex_texture, scene_tex_sampler, uv);
```

zwgsl:

```ruby
color = texture(scene_tex, uv)
```

Texture calls must resolve to a sampler uniform, sampler parameter, or immutable
local alias for WGSL output.

## Compute Shaders

WGSL compute entry points can be represented as `compute do` blocks:

```ruby
compute do
  def main
    id: UVec3 = global_invocation_id
  end
end
```

Compute shaders are WGSL-only. GLSL ES 3.0 output rejects compute stages.

## Things To Keep Explicit

- Keep stage boundaries explicit with `vertex`, `fragment`, and `compute`.
- Keep public resource and interface types annotated.
- Keep uniform declaration order stable when host bind group layouts depend on
  generated WGSL bindings.
- Keep GLSL compatibility in mind only for render-stage shaders.

## Useful Checks

```sh
zig-out/bin/zwgsl check shader.zw
zig-out/bin/zwgsl compile --target wgsl shader.zw
zig-out/bin/zwgsl compile --target glsl-es-300 shader.zw
```

For target-specific limits, see [Feature Matrix](feature-matrix.md) and
[Gotchas](gotchas.md).
