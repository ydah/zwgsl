# zwgsl

`zwgsl` is a Zig library that compiles a small shader DSL into GPU shader source code.
Today, the implemented backend targets GLSL ES 3.00 and produces separate vertex and fragment shader outputs.

The project exposes:

- A Zig API for embedding the compiler directly
- A C API for integration from non-Zig codebases
- Examples and tests that document the supported language surface

## Status

- Zig version: `0.15.0` or newer
- Current stable output target: `GLSL ES 3.00`
- Planned but not yet implemented: `WGSL`
- No standalone CLI is included yet

If `target = .wgsl` or `ZWGSL_TARGET_WGSL` is requested, the compiler currently returns an error indicating that the WGSL backend is not implemented.

## What The Compiler Does

The pipeline is organized as:

1. Lexing
2. Parsing
3. Semantic analysis
4. IR construction
5. GLSL emission

At the API level, compilation returns:

- `vertex_source`
- `fragment_source`
- Structured diagnostics with line and column information

## Repository Layout

```text
.
|-- build.zig
|-- build.zig.zon
|-- include/
|   `-- zwgsl.h
|-- src/
|   |-- lib.zig
|   |-- compiler.zig
|   |-- lexer.zig
|   |-- parser.zig
|   |-- sema.zig
|   |-- ir_builder.zig
|   |-- glsl_emitter.zig
|   `-- ...
|-- examples/
|   `-- *.zwgsl
`-- tests/
    `-- *_test.zig
```

## Build And Test

Build the library artifacts:

```sh
zig build
```

This installs the generated outputs under `zig-out/`, including:

- `zig-out/lib/libzwgsl.a`
- `zig-out/lib/libzwgsl.dylib` (on macOS)
- `zig-out/include/zwgsl.h`

Run the full test suite:

```sh
zig build test
```

## Zig Integration

After adding `zwgsl` to your `build.zig.zon`, import it as a module and call the compiler directly:

```zig
const std = @import("std");
const zwgsl = @import("zwgsl");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const source =
        \\version "300 es"
        \\precision :fragment, :highp
        \\
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\  def main
        \\    gl_Position = vec4(position, 1.0)
        \\  end
        \\end
        \\
        \\fragment do
        \\  output :frag_color, Vec4, location: 0
        \\  def main
        \\    frag_color = vec4(1.0)
        \\  end
        \\end
    ;

    const result = try zwgsl.compiler.compile(arena.allocator(), source, .{
        .target = .glsl_es_300,
        .emit_debug_comments = 0,
        .optimize_output = 0,
    });

    if (result.errors.len != 0) {
        for (result.errors) |err| {
            std.debug.print("{d}:{d}: {s}\n", .{ err.line, err.column, std.mem.span(err.message) });
        }
        return;
    }

    std.debug.print("vertex:\n{s}\n", .{result.vertex_source.?});
    std.debug.print("fragment:\n{s}\n", .{result.fragment_source.?});
}
```

## C Integration

Build the library, include `zwgsl.h`, then call the exported C API:

```c
#include <stdio.h>
#include <string.h>
#include "zwgsl.h"

int main(void) {
    const char* source =
        "version \"300 es\"\n"
        "precision :fragment, :highp\n"
        "\n"
        "vertex do\n"
        "  input :position, Vec3, location: 0\n"
        "  def main\n"
        "    gl_Position = vec4(position, 1.0)\n"
        "  end\n"
        "end\n"
        "\n"
        "fragment do\n"
        "  output :frag_color, Vec4, location: 0\n"
        "  def main\n"
        "    frag_color = vec4(1.0)\n"
        "  end\n"
        "end\n";

    ZwgslOptions options = {
        .target = ZWGSL_TARGET_GLSL_ES_300,
        .emit_debug_comments = 0,
        .optimize_output = 0,
    };

    ZwgslResult result = zwgsl_compile(source, strlen(source), options);

    if (result.error_count > 0) {
        for (uint32_t i = 0; i < result.error_count; ++i) {
            const ZwgslError err = result.errors[i];
            fprintf(stderr, "%u:%u: %s\n", err.line, err.column, err.message);
        }
        zwgsl_free(&result);
        return 1;
    }

    puts(result.vertex_source);
    puts(result.fragment_source);
    zwgsl_free(&result);
    return 0;
}
```

The C API surface is:

- `zwgsl_compile`
- `zwgsl_free`
- `zwgsl_version`

## Language Snapshot

Example source from `examples/hello_triangle.zwgsl`:

```text
version "300 es"
precision :fragment, :highp

uniform :mvp, Mat4

vertex do
  input :position, Vec3, location: 0
  input :color, Vec3, location: 1
  varying :v_color, Vec3

  def main
    self.v_color = color
    gl_Position = mvp * vec4(position, 1.0)
  end
end

fragment do
  varying :v_color, Vec3
  output :frag_color, Vec4, location: 0

  def main
    frag_color = vec4(v_color, 1.0)
  end
end
```

This produces GLSL ES 3.00 shader source for both stages.

## Current Limitations

- Only the GLSL ES 3.00 backend is implemented
- The compiler expects source that fits the currently supported DSL and semantic rules covered by the test suite
- `optimize_output` is part of the public options struct, but there is no optimization pass wired in yet
- The project currently focuses on vertex and fragment shaders

## Development Notes

- Examples under `examples/` are expected to compile in integration tests
- Golden GLSL outputs live in `tests/fixtures/`
- The public C ABI is defined in `include/zwgsl.h`
- The Zig module entry point is `src/lib.zig`

## License

Released under the MIT License. See `LICENSE` for details.