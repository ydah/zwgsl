const std = @import("std");
const analysis = @import("analysis.zig");

pub fn publish(allocator: std.mem.Allocator, uri: []const u8, source: []const u8) ![]u8 {
    var document = try analysis.Document.init(allocator, source);
    defer document.deinit();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    try writer.print(
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{{\"uri\":",
        .{},
    );
    try writeJsonString(writer, uri);
    try writer.writeAll(",\"diagnostics\":[");

    for (document.diagnostics, 0..) |diagnostic, index| {
        if (index != 0) try writer.writeByte(',');
        const severity: u32 = switch (diagnostic.kind) {
            .@"error" => 1,
            .warning => 2,
        };
        try writer.print(
            "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":{d},\"message\":",
            .{
                if (diagnostic.line > 0) diagnostic.line - 1 else 0,
                if (diagnostic.column > 0) diagnostic.column - 1 else 0,
                if (diagnostic.line > 0) diagnostic.line - 1 else 0,
                if (diagnostic.column > 0) diagnostic.column else 0,
                severity,
            },
        );
        try writeJsonString(writer, diagnostic.message);
        try writer.writeByte('}');
    }

    try writer.writeAll("]}}");
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
