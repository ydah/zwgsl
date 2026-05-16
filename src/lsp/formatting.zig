const std = @import("std");
const formatter = @import("../formatter.zig");

pub fn response(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const formatted = try formatter.format(allocator, source, .{});
    defer allocator.free(formatted);

    if (std.mem.eql(u8, source, formatted)) {
        return try allocator.dupe(u8, "[]");
    }

    const end = documentEnd(source);
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    try writer.print(
        "[{{\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"newText\":",
        .{ end.line, end.character },
    );
    try writeJsonString(writer, formatted);
    try writer.writeAll("}]");
    return try buffer.toOwnedSlice(allocator);
}

const Position = struct {
    line: u32 = 0,
    character: u32 = 0,
};

fn documentEnd(source: []const u8) Position {
    var position: Position = .{};
    var index: usize = 0;
    while (index < source.len) {
        if (source[index] == '\n') {
            position.line += 1;
            position.character = 0;
            index += 1;
            continue;
        }

        const scalar = utf8ScalarAt(source, index) orelse {
            position.character += 1;
            index += 1;
            continue;
        };
        position.character += scalar.utf16_units;
        index += scalar.byte_len;
    }
    return position;
}

const Utf8Scalar = struct {
    byte_len: usize,
    utf16_units: u32,
};

fn utf8ScalarAt(source: []const u8, index: usize) ?Utf8Scalar {
    const first = source[index];
    if (first < 0x80) return .{ .byte_len = 1, .utf16_units = 1 };

    const byte_len = std.unicode.utf8ByteSequenceLength(first) catch return null;
    const end = index + @as(usize, byte_len);
    if (end > source.len) return null;
    const codepoint = std.unicode.utf8Decode(source[index..end]) catch return null;
    return .{
        .byte_len = @as(usize, byte_len),
        .utf16_units = if (codepoint > 0xFFFF) 2 else 1,
    };
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
