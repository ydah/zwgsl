const std = @import("std");

pub fn response(allocator: std.mem.Allocator, uri: []const u8, source: []const u8, line: u32, character: u32) ![]u8 {
    const word = wordAt(source, line, character) orelse return try allocator.dupe(u8, "null");
    if (findDefinition(source, word)) |definition_line| {
        return try std.fmt.allocPrint(
            allocator,
            "[{{\"uri\":{s},\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}]",
            .{ try jsonString(allocator, uri), definition_line, definition_line, word.len },
        );
    }
    return try allocator.dupe(u8, "null");
}

fn findDefinition(source: []const u8, word: []const u8) ?u32 {
    var iterator = std.mem.splitScalar(u8, source, '\n');
    var line: u32 = 0;
    while (iterator.next()) |item| : (line += 1) {
        if (std.mem.startsWith(u8, std.mem.trim(u8, item, " "), "def ")) {
            if (std.mem.indexOf(u8, item, word)) |_| return line;
        }
        if (std.mem.startsWith(u8, std.mem.trim(u8, item, " "), "let ")) {
            if (std.mem.indexOf(u8, item, word)) |_| return line;
        }
    }
    return null;
}

fn wordAt(source: []const u8, line: u32, character: u32) ?[]const u8 {
    var iterator = std.mem.splitScalar(u8, source, '\n');
    var current: u32 = 0;
    while (iterator.next()) |item| : (current += 1) {
        if (current != line) continue;
        if (character >= item.len) return null;
        var start: usize = character;
        while (start > 0 and isWord(item[start - 1])) : (start -= 1) {}
        var end: usize = character;
        while (end < item.len and isWord(item[end])) : (end += 1) {}
        if (start == end) return null;
        return item[start..end];
    }
    return null;
}

fn isWord(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
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
