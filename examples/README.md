# Examples

The examples are small, complete `.zw` programs that compile through the CLI and
are also available in the playground sample selector.

Open the [Playground](https://ydah.github.io/zwgsl/) and choose a sample from
the selector, or use the direct sample links below, to inspect the generated
WGSL and preview supported render shaders.

## Compile

```sh
zig build
zig-out/bin/zwgsl check examples/hello_triangle.zw
zig-out/bin/zwgsl compile --target wgsl examples/hello_triangle.zw
```

Use `--target glsl-es-300` for GLSL ES 3.0 output where the shader shape is
compatible with that backend.

## Samples

| Example | Demonstrates | Playground |
| --- | --- | --- |
| `hello_triangle.zw` | A minimal vertex and fragment pipeline with inputs, varyings, one matrix uniform, and a color output. | [Open](https://ydah.github.io/zwgsl/?sample=hello-triangle) |
| `phong.zw` | Stage interfaces, helper functions, method-chain lowering, and a simple lighting calculation. | [Open](https://ydah.github.io/zwgsl/?sample=phong) |
| `pbr.zw` | Utility functions, scalar uniforms, vector math, and a compact material-style fragment shader. | [Open](https://ydah.github.io/zwgsl/?sample=pbr) |
| `postprocess.zw` | Texture sampling with `Sampler2D`, UV varyings, and a fullscreen-style postprocess pass. | [Open](https://ydah.github.io/zwgsl/?sample=postprocess) |
| `utah_teapot.zw` | A larger animated SDF shader using `where` bindings, loops, helper functions, and generated uniform controls in the playground. | [Open](https://ydah.github.io/zwgsl/?sample=utah-teapot) |

The playground also includes focused feature fixtures such as dependent dimension
checking and ADT pattern matching. Those are sourced from `tests/fixtures/` so the
demo stays aligned with compiler coverage.
