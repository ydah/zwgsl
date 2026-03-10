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
