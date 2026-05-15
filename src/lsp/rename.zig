const std = @import("std");
const analysis = @import("analysis.zig");
const token = @import("../token.zig");

const Edit = struct {
    start_line: u32,
    start_character: u32,
    end_line: u32,
    end_character: u32,
};

pub fn response(
    allocator: std.mem.Allocator,
    uri: []const u8,
    source: []const u8,
    line: u32,
    character: u32,
    new_name: []const u8,
) ![]u8 {
    if (!isValidIdentifier(new_name)) return try allocator.dupe(u8, "null");

    var document = try analysis.Document.init(allocator, source);
    defer document.deinit();

    const selected = document.tokenAt(line, character) orelse return try allocator.dupe(u8, "null");
    const name = renameName(&document, selected) orelse return try allocator.dupe(u8, "null");
    const target = document.resolveDefinition(name, line, character) orelse return try allocator.dupe(u8, "null");
    if (target.line == 0 and target.column == 0) return try allocator.dupe(u8, "null");

    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(allocator);

    for (document.tokens, 0..) |tok, index| {
        const candidate = renameName(&document, .{ .index = index, .tok = tok }) orelse continue;
        if (!std.mem.eql(u8, candidate, name)) continue;

        if (tokenDefines(&document, target, index, tok, candidate)) {
            try edits.append(allocator, editRange(tok));
            continue;
        }

        const start_line, const start_character = editStart(tok);
        const resolved = document.resolveDefinition(candidate, start_line, start_character) orelse continue;
        if (!sameDefinition(target, resolved)) continue;

        try edits.append(allocator, editRange(tok));
    }

    if (edits.items.len == 0) return try allocator.dupe(u8, "null");
    return try writeWorkspaceEdit(allocator, uri, edits.items, new_name);
}

fn renameName(document: *const analysis.Document, item: analysis.TokenRef) ?[]const u8 {
    switch (item.tok.tag) {
        .identifier => return document.lexeme(item.tok),
        .symbol => {
            if (!isDeclarationSymbol(document, item.index)) return null;
            const value = document.lexeme(item.tok);
            if (value.len <= 1) return null;
            return value[1..];
        },
        else => return null,
    }
}

fn isDeclarationSymbol(document: *const analysis.Document, index: usize) bool {
    const previous = document.previousSignificantToken(index) orelse return false;
    return switch (previous.tok.tag) {
        .kw_uniform, .kw_input, .kw_output, .kw_varying => true,
        else => false,
    };
}

fn editStart(tok: token.Token) struct { u32, u32 } {
    const line = if (tok.line > 0) tok.line - 1 else 0;
    const character = if (tok.tag == .symbol)
        tok.column
    else if (tok.column > 0)
        tok.column - 1
    else
        0;
    return .{ line, character };
}

fn editRange(tok: token.Token) Edit {
    const start_line, const start_character = editStart(tok);
    const width: u32 = if (tok.tag == .symbol)
        @intCast(tok.end - tok.start - 1)
    else
        @intCast(tok.end - tok.start);
    return .{
        .start_line = start_line,
        .start_character = start_character,
        .end_line = start_line,
        .end_character = start_character + width,
    };
}

fn sameDefinition(a: analysis.Definition, b: analysis.Definition) bool {
    return a.kind == b.kind and
        a.line == b.line and
        a.column == b.column and
        a.end_column == b.end_column and
        std.mem.eql(u8, a.name, b.name);
}

fn tokenDefines(
    document: *const analysis.Document,
    definition: analysis.Definition,
    index: usize,
    tok: token.Token,
    name: []const u8,
) bool {
    if (!std.mem.eql(u8, definition.name, name)) return false;
    if (tok.tag == .symbol) {
        const keyword = document.previousSignificantToken(index) orelse return false;
        return definition.line == keyword.tok.line and
            definition.column == keyword.tok.column;
    }
    return definition.line == tok.line and
        definition.column == tok.column and
        std.mem.eql(u8, definition.name, name);
}

fn isValidIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!isIdentifierStart(name[0])) return false;
    for (name[1..]) |ch| {
        if (!isIdentifierContinue(ch)) return false;
    }
    return token.keywordTag(name) == null;
}

fn isIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentifierContinue(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn writeWorkspaceEdit(
    allocator: std.mem.Allocator,
    uri: []const u8,
    edits: []const Edit,
    new_name: []const u8,
) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    try writer.writeAll("{\"changes\":{");
    try writeJsonString(writer, uri);
    try writer.writeAll(":[");
    for (edits, 0..) |edit, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"range\":{\"start\":{\"line\":");
        try writer.print("{d}", .{edit.start_line});
        try writer.writeAll(",\"character\":");
        try writer.print("{d}", .{edit.start_character});
        try writer.writeAll("},\"end\":{\"line\":");
        try writer.print("{d}", .{edit.end_line});
        try writer.writeAll(",\"character\":");
        try writer.print("{d}", .{edit.end_character});
        try writer.writeAll("}},\"newText\":");
        try writeJsonString(writer, new_name);
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
