const std = @import("std");
const zwgsl = @import("zwgsl");

test "C API exposes ABI version and default options" {
    try std.testing.expectEqual(@as(u32, 1), zwgsl.zwgsl_abi_version());

    const options = zwgsl.zwgsl_options_default();
    try std.testing.expectEqual(zwgsl.compiler.Target.glsl_es_300, options.target);
    try std.testing.expectEqual(@as(c_int, 0), options.emit_debug_comments);
    try std.testing.expectEqual(@as(c_int, 0), options.optimize_output);
}

test "C API compiles and frees WGSL output with defaulted options" {
    const source =
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\  def main
        \\    gl_Position = vec4(position, 1.0)
        \\  end
        \\end
    ;

    var options = zwgsl.zwgsl_options_default();
    options.target = .wgsl;

    var result = zwgsl.zwgsl_compile(source.ptr, source.len, options);
    try std.testing.expectEqual(@as(u32, 0), result.error_count);
    try std.testing.expect(result.vertex_source != null);

    zwgsl.zwgsl_free(&result);
    try std.testing.expect(result.vertex_source == null);
    try std.testing.expect(result.errors == null);
    try std.testing.expectEqual(@as(u32, 0), result.error_count);
}
