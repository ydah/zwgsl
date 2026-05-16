const std = @import("std");

pub const Options = struct {
    indent_size: usize = 2,
    final_newline: bool = true,
};

pub fn format(allocator: std.mem.Allocator, source: []const u8, options: Options) ![]u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, source.len + 1);
    errdefer buffer.deinit(allocator);

    var indent: usize = 0;
    var previous_blank = false;
    var start: usize = 0;
    while (start < source.len) {
        const end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
        const raw_line = source[start..end];
        const line = std.mem.trim(u8, raw_line, " \t\r");

        if (line.len == 0) {
            if (!previous_blank and buffer.items.len > 0) {
                try buffer.append(allocator, '\n');
                previous_blank = true;
            }
        } else {
            previous_blank = false;
            if (dedentsBefore(line) and indent > 0) indent -= 1;
            try appendIndent(allocator, &buffer, indent * options.indent_size);
            try buffer.appendSlice(allocator, line);
            try buffer.append(allocator, '\n');
            if (indentsAfter(line)) indent += 1;
        }

        if (end == source.len) break;
        start = end + 1;
    }

    if (!options.final_newline and buffer.items.len > 0 and buffer.items[buffer.items.len - 1] == '\n') {
        _ = buffer.pop();
    }
    return try buffer.toOwnedSlice(allocator);
}

fn appendIndent(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), count: usize) !void {
    for (0..count) |_| try buffer.append(allocator, ' ');
}

fn dedentsBefore(line: []const u8) bool {
    return hasLeadingWord(line, "end") or
        hasLeadingWord(line, "else") or
        hasLeadingWord(line, "elsif") or
        hasLeadingWord(line, "when") or
        hasLeadingWord(line, "where");
}

fn indentsAfter(line: []const u8) bool {
    if (hasLeadingWord(line, "end")) return false;
    if (hasTrailingWord(line, "end")) return false;
    return hasLeadingWord(line, "def") or
        hasLeadingWord(line, "type") or
        hasLeadingWord(line, "trait") or
        hasLeadingWord(line, "impl") or
        hasLeadingWord(line, "match") or
        hasLeadingWord(line, "if") or
        hasLeadingWord(line, "unless") or
        hasLeadingWord(line, "else") or
        hasLeadingWord(line, "elsif") or
        hasLeadingWord(line, "when") or
        hasLeadingWord(line, "where") or
        hasBlockDo(line);
}

fn hasBlockDo(line: []const u8) bool {
    if (hasTrailingWord(line, "do")) return true;
    return std.mem.indexOf(u8, line, " do |") != null;
}

fn hasLeadingWord(line: []const u8, word: []const u8) bool {
    if (!std.mem.startsWith(u8, line, word)) return false;
    if (line.len == word.len) return true;
    return isWordBoundary(line[word.len]);
}

fn hasTrailingWord(line: []const u8, word: []const u8) bool {
    if (!std.mem.endsWith(u8, line, word)) return false;
    const start = line.len - word.len;
    if (start == 0) return true;
    return isWordBoundary(line[start - 1]);
}

fn isWordBoundary(byte: u8) bool {
    return !std.ascii.isAlphanumeric(byte) and byte != '_';
}
