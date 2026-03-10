const std = @import("std");

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub fn writeMessage(writer: anytype, json: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{json.len});
    try writer.writeAll(json);
}

pub fn readMessage(allocator: std.mem.Allocator, reader: anytype) ![]u8 {
    var content_length: ?usize = null;

    while (true) {
        const line = try reader.takeDelimiterExclusive('\n');
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) break;

        if (std.ascii.startsWithIgnoreCase(trimmed, "Content-Length:")) {
            const value = std.mem.trim(u8, trimmed["Content-Length:".len..], " ");
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
    }

    const length = content_length orelse return error.InvalidHeader;
    return try reader.readAlloc(allocator, length);
}
