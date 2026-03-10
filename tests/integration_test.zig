const std = @import("std");
const zwgsl = @import("zwgsl");

fn expectCompilesPath(path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = try std.fs.cwd().readFileAlloc(arena.allocator(), path, 1 << 20);
    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{});
    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
    try std.testing.expect(output.vertex_source != null);
    try std.testing.expect(output.fragment_source != null);
    try std.testing.expect(std.mem.startsWith(u8, output.vertex_source.?, "#version 300 es"));
    try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, "void main()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.fragment_source.?, "void main()") != null);
}

fn expectCompilesPathToWgsl(path: []const u8, vertex_snippets: []const []const u8, fragment_snippets: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = try std.fs.cwd().readFileAlloc(arena.allocator(), path, 1 << 20);
    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{
        .target = .wgsl,
    });

    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
    try std.testing.expect(output.vertex_source != null);
    try std.testing.expect(output.fragment_source != null);

    for (vertex_snippets) |snippet| {
        try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, snippet) != null);
    }

    for (fragment_snippets) |snippet| {
        try std.testing.expect(std.mem.indexOf(u8, output.fragment_source.?, snippet) != null);
    }
}

test "hello triangle example compiles" {
    try expectCompilesPath("examples/hello_triangle.zw");
}

test "phong example compiles" {
    try expectCompilesPath("examples/phong.zw");
}

test "pbr example compiles" {
    try expectCompilesPath("examples/pbr.zw");
}

test "postprocess example compiles" {
    try expectCompilesPath("examples/postprocess.zw");
}

test "utah teapot example compiles" {
    try expectCompilesPath("examples/utah_teapot.zw");
}

test "hello triangle example compiles to WGSL" {
    try expectCompilesPathToWgsl("examples/hello_triangle.zw", &.{
        "@group(0) @binding(0) var<uniform> mvp: mat4x4f;",
        "gl_Position = mvp * vec4f(position, 1.0);",
    }, &.{
        "frag_color = vec4f(v_color, 1.0);",
    });
}

test "phong example compiles to WGSL" {
    try expectCompilesPathToWgsl("examples/phong.zw", &.{
        "fn phong_strength(normal: vec3f, light_dir: vec3f) -> f32",
        "v_normal = mat3x3f(model_matrix) * normal;",
        "gl_Position = projection_matrix * view_matrix * world_pos;",
    }, &.{
        "let light: f32 = phong_strength(v_normal, light_dir);",
        "frag_color = vec4f(base_color.rgb * (0.2 + 0.8 * light), base_color.a);",
    });
}

test "pbr example compiles to WGSL" {
    try expectCompilesPathToWgsl("examples/pbr.zw", &.{
        "struct _zwgsl_uniform_metallic",
        "struct _zwgsl_uniform_roughness",
        "gl_Position = mvp * vec4f(position, 1.0);",
    }, &.{
        "let energy: f32 = mix(0.04, 1.0, metallic.value);",
        "let color: vec3f = albedo * (energy * (1.0 - roughness.value) * n_dot_up);",
    });
}

test "postprocess example compiles to WGSL" {
    try expectCompilesPathToWgsl("examples/postprocess.zw", &.{
        "@group(0) @binding(0) var scene_tex_texture: texture_2d<f32>;",
        "@group(0) @binding(1) var scene_tex_sampler: sampler;",
    }, &.{
        "let color: vec4f = textureSample(scene_tex_texture, scene_tex_sampler, v_uv);",
        "frag_color = vec4f(color.rgb, 1.0);",
    });
}

test "utah teapot example compiles to WGSL" {
    try expectCompilesPathToWgsl("examples/utah_teapot.zw", &.{
        "struct _zwgsl_uniform_time",
        "struct _zwgsl_uniform_resolution",
        "gl_Position = vec4f(position, 1.0);",
    }, &.{
        "fn scene_distance(p: vec3f) -> f32",
        "let color: vec3f = shade(v_uv);",
        "frag_color = vec4f(color, 1.0);",
    });
}
