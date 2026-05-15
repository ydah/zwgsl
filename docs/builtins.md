# Builtins

This page documents the builtin types and functions currently resolved by the
compiler. The list is intentionally about implemented behavior; it is not a full
WGSL or GLSL specification mirror.

## Types

| zwgsl type | WGSL shape | GLSL ES 3.0 shape | Notes |
| --- | --- | --- | --- |
| `Float` / `float` | `f32` | `float` | Default floating scalar. |
| `Int` / `int` | `i32` | `int` | Signed integer scalar. |
| `UInt` / `uint` | `u32` | `uint` | Unsigned integer scalar. |
| `Bool` / `bool` | `bool` | `bool` | Boolean scalar. |
| `Vec2`, `Vec3`, `Vec4` | `vec2f`, `vec3f`, `vec4f` | `vec2`, `vec3`, `vec4` | Floating vectors. |
| `IVec2`, `IVec3`, `IVec4` | `vec2i`, `vec3i`, `vec4i` | `ivec2`, `ivec3`, `ivec4` | Signed integer vectors. |
| `UVec2`, `UVec3`, `UVec4` | `vec2u`, `vec3u`, `vec4u` | `uvec2`, `uvec3`, `uvec4` | Unsigned integer vectors. |
| `BVec2`, `BVec3`, `BVec4` | `vec2<bool>`, `vec3<bool>`, `vec4<bool>` | `bvec2`, `bvec3`, `bvec4` | Boolean vectors. |
| `Mat2`, `Mat3`, `Mat4` | `mat2x2f`, `mat3x3f`, `mat4x4f` | `mat2`, `mat3`, `mat4` | Square floating matrices. |
| `Vec(N)` | fixed vector when resolved | no output coverage today | Dependent dimension form. |
| `Mat(M, N)` | fixed matrix when resolved | no output coverage today | Dependent dimension form. |
| `Sampler2D` | texture/sampler binding pair | `sampler2D` | WGSL lowering consumes two bindings. |
| `SamplerCube` | texture/sampler binding pair | `samplerCube` | Function/alias lowering is WGSL-focused. |
| `Sampler3D` | texture/sampler binding pair | `sampler3D` | Function/alias lowering is WGSL-focused. |
| `Symbol` / `symbol` | compile-time value | compile-time value | Useful in ADT and match-style flows. |

## Constructors

Scalar constructors accept one scalar argument.

```ruby
value = Float(1)
```

Vector constructors accept either one matching scalar splat or components whose
combined width matches the target vector.

```ruby
a = vec3(1.0)
b = vec3(vec2(1.0, 2.0), 3.0)
```

Matrix constructors accept one matching scalar, one matrix with the same
component type, or a full scalar list for the square matrix width.

```ruby
m = mat4(1.0)
```

Constructors are only callable as functions, not as receiver methods.

## Math Functions

| Function | Accepted arguments | Result | Method-call form |
| --- | --- | --- | --- |
| `normalize(x)` | vector | same vector type | Yes |
| `length(x)` | scalar or vector | `Float` | Yes |
| `distance(a, b)` | matching scalar or vector types | `Float` | Yes |
| `dot(a, b)` | matching vector types | `Float` | Yes |
| `cross(a, b)` | matching 3-component vector types | same vector type | Yes |
| `reflect(i, n)` | matching vector types | same vector type | Yes |
| `refract(i, n, eta)` | matching vector types plus `Float` eta | same vector type | Yes |
| `mix(a, b, t)` | matching `a`/`b`; `t` scalar or same type | same as `a` | Yes |
| `clamp(x, low, high)` | matching numeric types, or vector plus scalar bounds | same as `x` | Yes |
| `min(a, b)` / `max(a, b)` | matching numeric types, or vector plus scalar | same as `a` | Yes |
| `mod(a, b)` / `pow(a, b)` / `step(edge, x)` | matching numeric types, or vector plus scalar | same as first argument | Yes |
| `smoothstep(edge0, edge1, x)` | matching numeric types, or scalar edge with vector `x` | same as `x` | Yes |
| `atan(y_over_x)` | numeric type | same type | Yes |
| `atan(y, x)` | matching numeric types | same type | Yes |
| `transpose(m)` | matrix | same matrix type | Yes |

Unary numeric functions accept scalar and vector numeric types and return the
same type:

- `abs`
- `sign`
- `floor`
- `ceil`
- `fract`
- `sqrt`
- `exp`
- `log`
- `sin`
- `cos`
- `tan`
- `asin`
- `acos`

## Texture Functions

`texture(sampler, coord)` is supported as a free function only.

| Sampler | Coordinate | Result |
| --- | --- | --- |
| `Sampler2D` | `Vec2` | `Vec4` |
| `SamplerCube` | `Vec3` | `Vec4` |
| `Sampler3D` | `Vec3` | `Vec4` |

```ruby
color = texture(scene_tex, uv)
```

For WGSL, texture sampling lowers to `textureSample` with concrete texture and
sampler handles. See [Gotchas](gotchas.md#texture-sampling-has-source-limits)
for source-shape limits.

## Stage Builtins

Vertex stages write `gl_Position`.

Compute stages expose these WGSL-only values:

- `global_invocation_id`
- `local_invocation_id`
- `workgroup_id`
- `num_workgroups`
- `local_invocation_index`

These compute values are rejected outside compute stages.
