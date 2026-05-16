# C API

The C API exposes the native compiler through `include/zwgsl.h`. It is intended
for host tools, build systems, and editor integrations that want to compile
source without shelling out to the CLI.

## Build Artifacts

`zig build` installs:

- `zig-out/include/zwgsl.h`
- `zig-out/lib/libzwgsl.a`
- a platform shared library such as `zig-out/lib/libzwgsl.dylib`

## Versioning

Use `zwgsl_version()` for the package semantic version and
`zwgsl_abi_version()` for the C ABI version.

```c
printf("zwgsl %s ABI %u\n", zwgsl_version(), zwgsl_abi_version());
```

The header also defines `ZWGSL_ABI_VERSION` so callers can check the ABI version
at compile time.

## Options

Start with `zwgsl_options_default()` and override only the fields you need.

```c
ZwgslOptions options = zwgsl_options_default();
options.target = ZWGSL_TARGET_WGSL;
options.emit_debug_comments = 1;
```

Fields:

| Field | Default | Meaning |
| --- | --- | --- |
| `target` | `ZWGSL_TARGET_GLSL_ES_300` | Selects GLSL ES 3.0 or WGSL output. |
| `emit_debug_comments` | `0` | Includes source-oriented and lowering comments in generated output when supported. |
| `optimize_output` | `0` | Emits more compact generated output when supported. |

Set `target` to `ZWGSL_TARGET_WGSL` for WebGPU output.

## Compile And Free

```c
#include <stdio.h>
#include <string.h>
#include "zwgsl.h"

int main(void) {
    const char* source =
        "vertex do\n"
        "  input :position, Vec3, location: 0\n"
        "  def main\n"
        "    gl_Position = vec4(position, 1.0)\n"
        "  end\n"
        "end\n";

    ZwgslOptions options = zwgsl_options_default();
    options.target = ZWGSL_TARGET_WGSL;

    ZwgslResult result = zwgsl_compile(source, strlen(source), options);
    int ok = result.error_count == 0;

    if (ok && result.vertex_source != NULL) {
        puts(result.vertex_source);
    }

    for (uint32_t i = 0; i < result.error_count; i += 1) {
        const ZwgslError* error = &result.errors[i];
        fprintf(stderr, "%u:%u: %s\n", error->line + 1, error->column + 1, error->message);
    }

    zwgsl_free(&result);
    return ok ? 0 : 1;
}
```

`zwgsl_compile` copies generated output and diagnostics into storage owned by
the returned `ZwgslResult`. Call `zwgsl_free(&result)` exactly once when done.
After freeing, the result is reset to an empty state.

Do not keep pointers from `vertex_source`, `fragment_source`, `compute_source`,
or `errors` after calling `zwgsl_free`.

## C++ Use

The header is wrapped in `extern "C"` when included from C++, so it can be used
directly.

```cpp
#include "zwgsl.h"

ZwgslOptions options = zwgsl_options_default();
options.target = ZWGSL_TARGET_WGSL;
```

Wrap `ZwgslResult` in an RAII type in larger C++ integrations so `zwgsl_free`
is always called.

## Error Kinds

`ZwgslErrorKind` values:

- `ZWGSL_OK`
- `ZWGSL_ERROR_SYNTAX`
- `ZWGSL_ERROR_TYPE`
- `ZWGSL_ERROR_SEMANTIC`
- `ZWGSL_ERROR_INTERNAL`

Line and column values are zero-based. Add one when displaying diagnostics to
users.
