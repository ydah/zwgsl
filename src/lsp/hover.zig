const std = @import("std");

pub fn response(allocator: std.mem.Allocator, source: []const u8, line: u32, character: u32) ![]u8 {
    const word = wordAt(source, line, character) orelse "zwgsl";
    return try std.fmt.allocPrint(
        allocator,
        "{{\"contents\":{{\"kind\":\"markdown\",\"value\":\"`{s}`\"}}}}",
        .{word},
    );
}

fn wordAt(source: []const u8, line: u32, character: u32) ?[]const u8 {
    const line_text = nthLine(source, line + 1) orelse return null;
    if (character >= line_text.len) return null;

    var start: usize = character;
    while (start > 0 and isWord(line_text[start - 1])) : (start -= 1) {}
    var end: usize = character;
    while (end < line_text.len and isWord(line_text[end])) : (end += 1) {}
    if (start == end) return null;
    return line_text[start..end];
}

fn nthLine(source: []const u8, target: u32) ?[]const u8 {
    var current: u32 = 1;
    var start: usize = 0;
    var index: usize = 0;
    while (index <= source.len) : (index += 1) {
        if (index == source.len or source[index] == '\n') {
            if (current == target) return source[start..index];
            current += 1;
            start = index + 1;
        }
    }
    return null;
}

fn isWord(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}
