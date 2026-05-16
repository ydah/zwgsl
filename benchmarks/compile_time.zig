const std = @import("std");
const zwgsl = @import("zwgsl");

const cases = [_][]const u8{
    "examples/hello_triangle.zw",
    "examples/phong.zw",
    "examples/pbr.zw",
    "examples/postprocess.zw",
    "examples/utah_teapot.zw",
    "tests/fixtures/dependent_dim.zw",
    "tests/fixtures/match_shape.zw",
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    try stdout.writeAll("case,target,bytes,micros,diagnostics\n");
    for (cases) |path| {
        try runCase(allocator, stdout, path, .wgsl);
        try runCase(allocator, stdout, path, .glsl_es_300);
    }
}

fn runCase(
    allocator: std.mem.Allocator,
    writer: anytype,
    path: []const u8,
    target: zwgsl.compiler.Target,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = try std.fs.cwd().readFileAlloc(arena, path, 4 * 1024 * 1024);
    const started = std.time.nanoTimestamp();
    const output = try zwgsl.compiler.compile(arena, source, .{ .target = target });
    const elapsed_ns = std.time.nanoTimestamp() - started;

    try writer.print("{s},{s},{d},{d},{d}\n", .{
        path,
        targetName(target),
        source.len,
        @divTrunc(elapsed_ns, 1000),
        output.errors.len,
    });
}

fn targetName(target: zwgsl.compiler.Target) []const u8 {
    return switch (target) {
        .glsl_es_300 => "glsl-es-300",
        .wgsl => "wgsl",
    };
}
