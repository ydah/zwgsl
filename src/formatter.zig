const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const string_pool = @import("string_pool.zig");

pub const Options = struct {
    indent_size: usize = 2,
    final_newline: bool = true,
};

pub const FormatError = error{
    FormattedSourceInvalid,
};

pub fn formatChecked(allocator: std.mem.Allocator, source: []const u8, options: Options) ![]u8 {
    const formatted = try format(allocator, source, options);
    errdefer allocator.free(formatted);

    if (!try syntaxValid(allocator, formatted)) return FormatError.FormattedSourceInvalid;
    return formatted;
}

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
            const syntax = syntaxPortion(line);
            if (dedentsBefore(syntax) and indent > 0) indent -= 1;
            try appendIndent(allocator, &buffer, indent * options.indent_size);
            try buffer.appendSlice(allocator, line);
            try buffer.append(allocator, '\n');
            if (indentsAfter(syntax)) indent += 1;
        }

        if (end == source.len) break;
        start = end + 1;
    }

    if (!options.final_newline and buffer.items.len > 0 and buffer.items[buffer.items.len - 1] == '\n') {
        _ = buffer.pop();
    }
    return try buffer.toOwnedSlice(allocator);
}

fn syntaxValid(allocator: std.mem.Allocator, source: []const u8) !bool {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var pool = string_pool.StringPool.init(arena);
    defer pool.deinit();

    const tokens = try lexer.Lexer.tokenizeResolvedWithPool(arena, &pool, source);
    var diagnostic_list = diagnostics.DiagnosticList.init(arena);
    defer diagnostic_list.deinit();

    var syntax_parser = parser.Parser.initWithPool(arena, &pool, source, tokens, &diagnostic_list);
    _ = try syntax_parser.parseProgram();
    return diagnostic_list.items.items.len == 0;
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

fn syntaxPortion(line: []const u8) []const u8 {
    var in_string = false;
    var escaped = false;
    for (line, 0..) |byte, index| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }

        if (byte == '"') {
            in_string = true;
            continue;
        }
        if (byte == '#') return std.mem.trim(u8, line[0..index], " \t\r");
    }
    return line;
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
