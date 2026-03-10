const std = @import("std");
const zwgsl = @import("zwgsl");

fn expectCompilesSnippet(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const output = try zwgsl.compiler.compile(arena.allocator(), source, .{
        .target = .wgsl,
    });
    try std.testing.expectEqual(@as(usize, 0), output.errors.len);
}

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
    }
    if (fragment_path) |path| {
        const expected = try std.fs.cwd().readFileAlloc(arena.allocator(), path, 1 << 20);
        try std.testing.expectEqualStrings(expected, output.fragment_source.?);
    }
    if (compute_path) |path| {
        const expected = try std.fs.cwd().readFileAlloc(arena.allocator(), path, 1 << 20);
        try std.testing.expectEqualStrings(expected, output.compute_source.?);
    }
}

test "README quick example compiles through the documented WGSL pipeline" {
    try expectWgslFixture(
        "tests/fixtures/phong.zw",
        "tests/fixtures/phong.vertex.wgsl",
        "tests/fixtures/phong.fragment.wgsl",
        null,
    );
}

test "README pattern matching example compiles" {
    try expectWgslFixture(
        "tests/fixtures/match_shape.zw",
        null,
        null,
        "tests/fixtures/match_shape.compute.wgsl",
    );
}

test "README dependent dimension example compiles" {
    try expectWgslFixture(
        "tests/fixtures/dependent_dim.zw",
        null,
        null,
        "tests/fixtures/dependent_dim.compute.wgsl",
    );
}

test "README trait specialization example compiles" {
    const source =
        \\trait Numeric
        \\  def add(other: Self) -> Self end
        \\  def mul(other: Self) -> Self end
        \\end
        \\
        \\impl Numeric for Float
        \\  def add(other: Self) -> Self
        \\    self + other
        \\  end
        \\
        \\  def mul(other: Self) -> Self
        \\    self * other
        \\  end
        \\end
        \\
        \\def lerp(a: T, b: T, t: Float) -> T where T: Numeric
        \\  a.mul(1.0 - t).add(b.mul(t))
        \\end
        \\
        \\compute do
        \\  def main
        \\    value: Float = lerp(1.0, 2.0, 0.5)
        \\  end
        \\end
    ;

    try expectCompilesSnippet(source);
}
