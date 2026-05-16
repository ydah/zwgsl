const std = @import("std");
const zwgsl = @import("zwgsl");

test "source map collector reads generated debug comments" {
    const generated =
        \\// zwgsl:lowering: wgsl vertex entry main -> _zwgsl_vertex_main
        \\// zwgsl:11:3: def main
        \\fn _zwgsl_vertex_main() {
        \\    // zwgsl:12:5: self.v_pos = position
        \\    v_pos = position;
        \\}
    ;

    const entries = try zwgsl.source_map.collect(std.testing.allocator, "vertex", generated);
    defer std.testing.allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("vertex", entries[0].stage);
    try std.testing.expectEqual(@as(u32, 2), entries[0].generated_line);
    try std.testing.expectEqual(@as(u32, 11), entries[0].source_line);
    try std.testing.expectEqual(@as(u32, 3), entries[0].source_column.?);
    try std.testing.expectEqualStrings("def main", entries[0].source_text.?);
    try std.testing.expectEqual(@as(u32, 4), entries[1].generated_line);
}

test "source map writer emits JSON mappings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const output = try zwgsl.compiler.compile(arena.allocator(), @embedFile("fixtures/basic_shader.zw"), .{
        .target = .wgsl,
        .emit_debug_comments = 1,
    });
    try std.testing.expectEqual(@as(usize, 0), output.errors.len);

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(std.testing.allocator);

    try zwgsl.source_map.writeJson(json.writer(std.testing.allocator), output, .all);

    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"version\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"stage\":\"vertex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"sourceLine\":11") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"source\":\"def main\"") != null);
}
