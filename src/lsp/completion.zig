const std = @import("std");
const analysis = @import("analysis.zig");

pub fn response(allocator: std.mem.Allocator, source: []const u8, line: u32, character: u32) ![]u8 {
    var document = try analysis.Document.init(allocator, source);
    defer document.deinit();

    const items = try document.completionItems(line, character);
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    try writer.writeByte('[');
    for (items, 0..) |item, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"label\":");
        try writeJsonString(writer, item.label);
        try writer.print(",\"kind\":{d}", .{item.kind});
        if (item.detail) |detail| {
            try writer.writeAll(",\"detail\":");
            try writeJsonString(writer, detail);
        }
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
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
