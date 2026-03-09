const std = @import("std");
const zwgsl = @import("zwgsl");

test "compiler emits WGSL for a basic vertex and fragment shader" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const output = try zwgsl.compiler.compile(arena.allocator(), @embedFile("fixtures/basic_shader.zwgsl"), .{
        .target = .wgsl,
    });

    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
    try std.testing.expect(output.vertex_source != null);
    try std.testing.expect(output.fragment_source != null);
    try std.testing.expect(output.compute_source == null);
    try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, "@vertex") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, "struct VertexInput") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, "@group(0) @binding(0) var<uniform> mvp: mat4x4f;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, "output.gl_Position = gl_Position;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.fragment_source.?, "@fragment") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.fragment_source.?, "struct FragmentOutput") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.fragment_source.?, "output.frag_color = frag_color;") != null);
}

test "compiler emits WGSL compute output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\compute do
        \\  def main
        \\    id: UVec3 = global_invocation_id
        \\  end
        \\end
    ;

    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{
        .target = .wgsl,
    });

    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
    try std.testing.expect(output.vertex_source == null);
    try std.testing.expect(output.fragment_source == null);
    try std.testing.expect(output.compute_source != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "@compute @workgroup_size(1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "@builtin(global_invocation_id)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.compute_source.?, "var id: vec3u = global_invocation_id;") != null);
}

test "compiler lowers sampler uniforms and texture sampling for WGSL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = try std.fs.cwd().readFileAlloc(arena.allocator(), "examples/postprocess.zwgsl", 1 << 20);
    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{
        .target = .wgsl,
    });

    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
    try std.testing.expect(output.fragment_source != null);
    try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, "@group(0) @binding(0) var scene_tex_texture: texture_2d<f32>;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, "@group(0) @binding(1) var scene_tex_sampler: sampler;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.fragment_source.?, "textureSample(scene_tex_texture, scene_tex_sampler, v_uv)") != null);
}

test "compiler rejects compute shaders for GLSL ES 3.00" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\compute do
        \\  def main
        \\    id: UVec3 = global_invocation_id
        \\  end
        \\end
    ;

    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{});
    try std.testing.expectEqual(@as(usize, 1), output.errors.len);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(output.errors[0].message), "does not support compute shaders") != null);
}

test "compiler rejects mixing compute with render stages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\vertex do
        \\  def main
        \\    gl_Position = vec4(1.0)
        \\  end
        \\end
        \\
        \\compute do
        \\  def main
        \\    id: UVec3 = global_invocation_id
        \\  end
        \\end
    ;

    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{
        .target = .wgsl,
    });
    try std.testing.expect(output.errors.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(output.errors[0].message), "cannot be combined") != null);
}
