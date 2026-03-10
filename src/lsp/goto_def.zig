const std = @import("std");
const analysis = @import("analysis.zig");

pub fn response(allocator: std.mem.Allocator, uri: []const u8, source: []const u8, line: u32, character: u32) ![]u8 {
    var document = try analysis.Document.init(allocator, source);
    defer document.deinit();

    const token_info = document.tokenAt(line, character) orelse
        document.tokenBeforeOrAt(line, character) orelse
        return try allocator.dupe(u8, "null");
    const name = switch (token_info.tok.tag) {
        .identifier => document.lexeme(token_info.tok),
        .symbol => document.lexeme(token_info.tok)[1..],
        else => return try allocator.dupe(u8, "null"),
    };
    const definition = document.resolveDefinition(name, line, character) orelse return try allocator.dupe(u8, "null");
    if (definition.line == 0) return try allocator.dupe(u8, "null");

    const escaped_uri = try jsonString(allocator, uri);
    defer allocator.free(escaped_uri);

    return try std.fmt.allocPrint(
        allocator,
        "[{{\"uri\":{s},\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}]",
        .{
            escaped_uri,
            definition.line - 1,
            if (definition.column > 0) definition.column - 1 else 0,
            definition.line - 1,
            if (definition.end_column > 0) definition.end_column - 1 else 0,
        },
    );
}

fn jsonString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    try writeJsonString(buffer.writer(allocator), value);
    return try buffer.toOwnedSlice(allocator);
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
