const std = @import("std");
const ast = @import("../ast.zig");
const core_diagnostics = @import("../diagnostics.zig");
const lexer = @import("../lexer.zig");
const parser = @import("../parser.zig");

pub fn response(allocator: std.mem.Allocator, uri: []const u8, source: []const u8) ![]u8 {
    const insert_line = missingPositionInputLine(allocator, source) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
    if (insert_line == null) return try allocator.dupe(u8, "[]");

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    try writer.writeAll("[{\"title\":\"Add vertex position input\",\"kind\":\"quickfix\",\"edit\":{\"changes\":{");
    try writeJsonString(writer, uri);
    try writer.writeAll(":[{\"range\":{\"start\":{\"line\":");
    try writer.print("{d}", .{insert_line.?});
    try writer.writeAll(",\"character\":0},\"end\":{\"line\":");
    try writer.print("{d}", .{insert_line.?});
    try writer.writeAll(",\"character\":0}},\"newText\":\"  input :position, Vec3, location: 0\\n\"}]}}}]");

    return try buffer.toOwnedSlice(allocator);
}

fn missingPositionInputLine(allocator: std.mem.Allocator, source: []const u8) !?u32 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var diagnostic_list = core_diagnostics.DiagnosticList.init(arena_allocator);
    const tokens = lexer.Lexer.tokenizeResolved(arena_allocator, source) catch return null;
    var syntax_parser = parser.Parser.init(arena_allocator, source, tokens, &diagnostic_list);
    const program = syntax_parser.parseProgram() catch return null;

    for (program.items) |item| {
        if (item != .shader_block or item.shader_block.stage != .vertex) continue;
        if (vertexDeclaresInput(item.shader_block, "position")) return null;
        if (!sourceUsesName(source, "position")) return null;
        return item.shader_block.position.line;
    }

    return null;
}

fn vertexDeclaresInput(block: *ast.ShaderBlock, name: []const u8) bool {
    for (block.items) |item| {
        if (item == .input and std.mem.eql(u8, item.input.name, name)) return true;
    }
    return false;
}

fn sourceUsesName(source: []const u8, name: []const u8) bool {
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, source, index, name)) |found| {
        const end = found + name.len;
        const left_ok = found == 0 or !isIdentifierContinue(source[found - 1]);
        const right_ok = end == source.len or !isIdentifierContinue(source[end]);
        if (left_ok and right_ok) return true;
        index = end;
    }
    return false;
}

fn isIdentifierContinue(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| switch (ch) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(ch),
    };
    try writer.writeByte('"');
}
