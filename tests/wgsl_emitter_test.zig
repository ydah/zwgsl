const std = @import("std");
const zwgsl = @import("zwgsl");

fn expectWgslFixture(source_path: []const u8, vertex_path: ?[]const u8, fragment_path: ?[]const u8, compute_path: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = try std.fs.cwd().readFileAlloc(arena.allocator(), source_path, 1 << 20);
    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{
        .target = .wgsl,
    });

    try std.testing.expectEqual(@as(usize, 0), output.errors.len);

    if (vertex_path) |path| {
        const expected = try std.fs.cwd().readFileAlloc(arena.allocator(), path, 1 << 20);
        try std.testing.expectEqualStrings(expected, output.vertex_source.?);
    } else {
        try std.testing.expect(output.vertex_source == null);
    }

    if (fragment_path) |path| {
        const expected = try std.fs.cwd().readFileAlloc(arena.allocator(), path, 1 << 20);
        try std.testing.expectEqualStrings(expected, output.fragment_source.?);
    } else {
        try std.testing.expect(output.fragment_source == null);
    }

    if (compute_path) |path| {
        const expected = try std.fs.cwd().readFileAlloc(arena.allocator(), path, 1 << 20);
        try std.testing.expectEqualStrings(expected, output.compute_source.?);
    } else {
        try std.testing.expect(output.compute_source == null);
    }
}

test "compiler emits WGSL for a basic vertex and fragment shader" {
    try expectWgslFixture(
        "tests/fixtures/basic_shader.zw",
        "tests/fixtures/basic_shader.vertex.wgsl",
        "tests/fixtures/basic_shader.fragment.wgsl",
        null,
    );
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
    try expectWgslFixture(
        "examples/postprocess.zw",
        "tests/fixtures/postprocess.vertex.wgsl",
        "tests/fixtures/postprocess.fragment.wgsl",
        null,
    );
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
