const std = @import("std");
const zwgsl = @import("zwgsl");

fn compileFixture(source: []const u8) !zwgsl.compiler.CompileOutput {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{});
    return output;
}

test "compiler emits expected GLSL for the basic fixture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const output = try zwgsl.compiler.compile(arena.allocator(), @embedFile("fixtures/basic_shader.zw"), .{});
    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
    try std.testing.expectEqualStrings(@embedFile("fixtures/basic_shader.vertex.glsl"), output.vertex_source.?);
    try std.testing.expectEqualStrings(@embedFile("fixtures/basic_shader.fragment.glsl"), output.fragment_source.?);
}

test "compiler lowers helper functions and method chains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const output = try zwgsl.compiler.compile(arena.allocator(), @embedFile("fixtures/method_chain.zw"), .{});
    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
    try std.testing.expectEqualStrings(@embedFile("fixtures/method_chain.vertex.glsl"), output.vertex_source.?);
    try std.testing.expectEqualStrings(@embedFile("fixtures/method_chain.fragment.glsl"), output.fragment_source.?);
}

test "compiler emits debug comments with source lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const output = try zwgsl.compiler.compile(arena.allocator(), @embedFile("fixtures/basic_shader.zw"), .{
        .emit_debug_comments = 1,
    });
    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
    try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, "// zwgsl:11: def main") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, "// zwgsl:12: self.v_pos = position") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.fragment_source.?, "// zwgsl:21: def main") != null);
}

test "compiler optimizes output formatting when requested" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const baseline = try zwgsl.compiler.compile(arena.allocator(), @embedFile("fixtures/basic_shader.zw"), .{});
    const optimized = try zwgsl.compiler.compile(arena.allocator(), @embedFile("fixtures/basic_shader.zw"), .{
        .optimize_output = 1,
    });

    try std.testing.expectEqual(@as(usize, 0), baseline.errors.len);
    try std.testing.expectEqual(@as(usize, 0), optimized.errors.len);
    try std.testing.expect(optimized.vertex_source.?.len < baseline.vertex_source.?.len);
    try std.testing.expect(std.mem.indexOf(u8, optimized.vertex_source.?, "\n\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, optimized.vertex_source.?, "\n    ") == null);
}

test "compiler lowers vector each loops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\vertex do
        \\  input :position, Vec3, location: 0
        \\  varying :v_sum, Float
        \\  def main
        \\    total: Float = 0.0
        \\    position.each do |component|
        \\      total += component
        \\    end
        \\    self.v_sum = total
        \\    gl_Position = vec4(position, 1.0)
        \\  end
        \\end
        \\
        \\fragment do
        \\  varying :v_sum, Float
        \\  output :frag_color, Vec4, location: 0
        \\  def main
        \\    frag_color = vec4(v_sum)
        \\  end
        \\end
    ;

    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{});
    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
    try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, "total += position[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, "total += position[1];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.vertex_source.?, "total += position[2];") != null);
}
