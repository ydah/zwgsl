const std = @import("std");
const ast = @import("../ast.zig");
const core_diagnostics = @import("../diagnostics.zig");
const lexer = @import("../lexer.zig");
const parser = @import("../parser.zig");
const token = @import("../token.zig");

const Action = struct {
    title: []const u8,
    start_line: u32,
    start_character: u32,
    end_line: u32,
    end_character: u32,
    new_text: []const u8,
};

const CasingFix = struct {
    type_name: []const u8,
    constructor_name: []const u8,
};

const casing_fixes = [_]CasingFix{
    .{ .type_name = "Vec2", .constructor_name = "vec2" },
    .{ .type_name = "Vec3", .constructor_name = "vec3" },
    .{ .type_name = "Vec4", .constructor_name = "vec4" },
    .{ .type_name = "IVec2", .constructor_name = "ivec2" },
    .{ .type_name = "IVec3", .constructor_name = "ivec3" },
    .{ .type_name = "IVec4", .constructor_name = "ivec4" },
    .{ .type_name = "UVec2", .constructor_name = "uvec2" },
    .{ .type_name = "UVec3", .constructor_name = "uvec3" },
    .{ .type_name = "UVec4", .constructor_name = "uvec4" },
    .{ .type_name = "BVec2", .constructor_name = "bvec2" },
    .{ .type_name = "BVec3", .constructor_name = "bvec3" },
    .{ .type_name = "BVec4", .constructor_name = "bvec4" },
    .{ .type_name = "Mat2", .constructor_name = "mat2" },
    .{ .type_name = "Mat3", .constructor_name = "mat3" },
    .{ .type_name = "Mat4", .constructor_name = "mat4" },
};

pub fn response(allocator: std.mem.Allocator, uri: []const u8, source: []const u8) ![]u8 {
    var actions: std.ArrayList(Action) = .empty;
    defer actions.deinit(allocator);

    if (missingPositionInputLine(allocator, source) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    }) |insert_line| {
        try actions.append(allocator, .{
            .title = "Add vertex position input",
            .start_line = insert_line,
            .start_character = 0,
            .end_line = insert_line,
            .end_character = 0,
            .new_text = "  input :position, Vec3, location: 0\n",
        });
    }

    try appendUnusedUniformActions(allocator, &actions, source);
    try appendCasingActions(allocator, &actions, source);

    return try writeActions(allocator, uri, actions.items);
}

fn appendUnusedUniformActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(Action),
    source: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var diagnostic_list = core_diagnostics.DiagnosticList.init(arena_allocator);
    const tokens = lexer.Lexer.tokenizeResolved(arena_allocator, source) catch return;
    var syntax_parser = parser.Parser.init(arena_allocator, source, tokens, &diagnostic_list);
    const program = syntax_parser.parseProgram() catch return;

    for (program.items) |item| {
        const uniform = switch (item) {
            .uniform => |value| value,
            else => continue,
        };
        if (sourceHasIdentifier(tokens, source, uniform.name)) continue;

        const range = deleteLineRange(source, uniform.position.line);
        try actions.append(allocator, .{
            .title = "Remove unused uniform",
            .start_line = range.start_line,
            .start_character = 0,
            .end_line = range.end_line,
            .end_character = range.end_character,
            .new_text = "",
        });
    }
}

fn appendCasingActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(Action),
    source: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = lexer.Lexer.tokenizeResolved(arena.allocator(), source) catch return;
    for (tokens, 0..) |tok, index| {
        if (tok.tag != .identifier) continue;

        const name = tok.lexeme(source);
        if (previousSignificantToken(tokens, index)) |previous| {
            if (isTypeContext(previous.tag)) {
                if (typeNameForConstructorName(name)) |replacement| {
                    try appendReplaceAction(
                        allocator,
                        actions,
                        tok,
                        "Use uppercase type name",
                        replacement,
                    );
                    continue;
                }
            }
        }

        if (nextSignificantToken(tokens, index)) |next| {
            if (next.tag == .lparen) {
                if (constructorNameForTypeName(name)) |replacement| {
                    try appendReplaceAction(
                        allocator,
                        actions,
                        tok,
                        "Use lowercase constructor name",
                        replacement,
                    );
                }
            }
        }
    }
}

fn appendReplaceAction(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(Action),
    tok: token.Token,
    title: []const u8,
    replacement: []const u8,
) !void {
    const start_line: u32 = if (tok.line > 0) tok.line - 1 else 0;
    const start_character: u32 = if (tok.column > 0) tok.column - 1 else 0;
    const width: u32 = @intCast(tok.end - tok.start);

    try actions.append(allocator, .{
        .title = title,
        .start_line = start_line,
        .start_character = start_character,
        .end_line = start_line,
        .end_character = start_character + width,
        .new_text = replacement,
    });
}

fn writeActions(
    allocator: std.mem.Allocator,
    uri: []const u8,
    actions: []const Action,
) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    try writer.writeByte('[');
    for (actions, 0..) |action, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"title\":");
        try writeJsonString(writer, action.title);
        try writer.writeAll(",\"kind\":\"quickfix\",\"edit\":{\"changes\":{");
        try writeJsonString(writer, uri);
        try writer.writeAll(":[{\"range\":{\"start\":{\"line\":");
        try writer.print("{d}", .{action.start_line});
        try writer.writeAll(",\"character\":");
        try writer.print("{d}", .{action.start_character});
        try writer.writeAll("},\"end\":{\"line\":");
        try writer.print("{d}", .{action.end_line});
        try writer.writeAll(",\"character\":");
        try writer.print("{d}", .{action.end_character});
        try writer.writeAll("}},\"newText\":");
        try writeJsonString(writer, action.new_text);
        try writer.writeAll("}]}}}");
    }
    try writer.writeByte(']');

    return try buffer.toOwnedSlice(allocator);
}

fn previousSignificantToken(tokens: []const token.Token, index: usize) ?token.Token {
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        if (isSignificantToken(tokens[cursor])) return tokens[cursor];
    }
    return null;
}

fn nextSignificantToken(tokens: []const token.Token, index: usize) ?token.Token {
    var cursor = index + 1;
    while (cursor < tokens.len) : (cursor += 1) {
        if (isSignificantToken(tokens[cursor])) return tokens[cursor];
    }
    return null;
}

fn isSignificantToken(tok: token.Token) bool {
    return switch (tok.tag) {
        .comment, .newline, .virtual_indent, .virtual_dedent, .virtual_semi, .eof => false,
        else => true,
    };
}

fn isTypeContext(tag: token.TokenTag) bool {
    return switch (tag) {
        .colon, .comma, .arrow => true,
        else => false,
    };
}

fn typeNameForConstructorName(name: []const u8) ?[]const u8 {
    for (casing_fixes) |fix| {
        if (std.mem.eql(u8, name, fix.constructor_name)) return fix.type_name;
    }
    return null;
}

fn constructorNameForTypeName(name: []const u8) ?[]const u8 {
    for (casing_fixes) |fix| {
        if (std.mem.eql(u8, name, fix.type_name)) return fix.constructor_name;
    }
    return null;
}

fn sourceHasIdentifier(tokens: []const token.Token, source: []const u8, name: []const u8) bool {
    for (tokens) |tok| {
        if (tok.tag != .identifier) continue;
        if (std.mem.eql(u8, tok.lexeme(source), name)) return true;
    }
    return false;
}

fn deleteLineRange(source: []const u8, one_based_line: u32) struct {
    start_line: u32,
    end_line: u32,
    end_character: u32,
} {
    const line = if (one_based_line > 0) one_based_line - 1 else 0;
    var current_line: u32 = 0;
    var line_start: usize = 0;

    while (line_start < source.len and current_line < line) : (current_line += 1) {
        line_start = lineEndOffset(source, line_start) orelse source.len;
        if (line_start < source.len and source[line_start] == '\n') line_start += 1;
    }

    const line_end = lineEndOffset(source, line_start) orelse source.len;
    if (line_end < source.len and source[line_end] == '\n') {
        return .{
            .start_line = line,
            .end_line = line + 1,
            .end_character = 0,
        };
    }

    return .{
        .start_line = line,
        .end_line = line,
        .end_character = @intCast(line_end - line_start),
    };
}

fn lineEndOffset(source: []const u8, start: usize) ?usize {
    return std.mem.indexOfScalarPos(u8, source, start, '\n');
}

fn missingPositionInputLine(allocator: std.mem.Allocator, source: []const u8) !?u32 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var diagnostic_list = core_diagnostics.DiagnosticList.init(arena_allocator);
    const tokens = lexer.Lexer.tokenizeResolved(arena_allocator, source) catch return null;
    var syntax_parser = parser.Parser.init(arena_allocator, source, tokens, &diagnostic_list);
    const program = syntax_parser.parseProgram() catch return null;

    for (program.items) |item| {
        if (item != .shader_block or item.shader_block.stage != .vertex) continue;
        if (vertexDeclaresInput(item.shader_block, "position")) return null;
        if (!sourceUsesName(source, "position")) return null;
        return item.shader_block.position.line;
    }

    return null;
}

fn vertexDeclaresInput(block: *ast.ShaderBlock, name: []const u8) bool {
    for (block.items) |item| {
        if (item == .input and std.mem.eql(u8, item.input.name, name)) return true;
    }
    return false;
}

fn sourceUsesName(source: []const u8, name: []const u8) bool {
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, source, index, name)) |found| {
        const end = found + name.len;
        const left_ok = found == 0 or !isIdentifierContinue(source[found - 1]);
        const right_ok = end == source.len or !isIdentifierContinue(source[end]);
        if (left_ok and right_ok) return true;
        index = end;
    }
    return false;
}

fn isIdentifierContinue(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
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
