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

    const output = try zwgsl.compiler.compile(arena.allocator(), @embedFile("fixtures/basic_shader.gem"), .{});
    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
    try std.testing.expectEqualStrings(@embedFile("fixtures/basic_shader.vertex.glsl"), output.vertex_source.?);
    try std.testing.expectEqualStrings(@embedFile("fixtures/basic_shader.fragment.glsl"), output.fragment_source.?);
}

test "compiler lowers helper functions and method chains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const output = try zwgsl.compiler.compile(arena.allocator(), @embedFile("fixtures/method_chain.gem"), .{});
    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
    try std.testing.expectEqualStrings(@embedFile("fixtures/method_chain.vertex.glsl"), output.vertex_source.?);
    try std.testing.expectEqualStrings(@embedFile("fixtures/method_chain.fragment.glsl"), output.fragment_source.?);
}
