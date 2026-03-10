const std = @import("std");
const analysis = @import("analysis.zig");

pub fn response(allocator: std.mem.Allocator, source: []const u8, line: u32, character: u32) ![]u8 {
    var document = try analysis.Document.init(allocator, source);
    defer document.deinit();

    const token_info = document.tokenAt(line, character) orelse
        document.tokenBeforeOrAt(line, character) orelse
        return try allocator.dupe(u8, "null");
    const word = switch (token_info.tok.tag) {
        .identifier => document.lexeme(token_info.tok),
        .symbol => document.lexeme(token_info.tok)[1..],
        else => if (analysis.keywordDoc(document.lexeme(token_info.tok))) |keyword|
            return try markdownResponse(allocator, keyword.detail, keyword.documentation)
        else
            return try allocator.dupe(u8, "null"),
    };

    if (analysis.keywordDoc(word)) |keyword| {
        return try markdownResponse(allocator, keyword.detail, keyword.documentation);
    }
    if (document.resolveDefinition(word, line, character)) |definition| {
        const detail = if (document.exprInfoAt(token_info.tok.line, token_info.tok.column)) |expr_info|
            expr_info.detail
        else
            definition.detail;
        return try markdownResponse(allocator, detail, definition.documentation orelse "");
    }
    if (analysis.builtinDoc(word)) |builtin_item| {
        return try markdownResponse(allocator, builtin_item.detail, builtin_item.documentation);
    }
    if (document.exprInfoAt(token_info.tok.line, token_info.tok.column)) |expr_info| {
        return try markdownResponse(allocator, expr_info.detail, "");
    }

    return try allocator.dupe(u8, "null");
}

fn markdownResponse(allocator: std.mem.Allocator, detail: []const u8, documentation: []const u8) ![]u8 {
    const escaped_detail = try jsonEscape(allocator, detail);
    defer allocator.free(escaped_detail);
    const escaped_docs = try jsonEscape(allocator, documentation);
    defer allocator.free(escaped_docs);

    if (documentation.len == 0) {
        return try std.fmt.allocPrint(
            allocator,
            "{{\"contents\":{{\"kind\":\"markdown\",\"value\":\"```zwgsl\\n{s}\\n```\"}}}}",
            .{escaped_detail},
        );
    }
    return try std.fmt.allocPrint(
        allocator,
        "{{\"contents\":{{\"kind\":\"markdown\",\"value\":\"```zwgsl\\n{s}\\n```\\n\\n{s}\"}}}}",
        .{ escaped_detail, escaped_docs },
    );
}

fn jsonEscape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    for (value) |ch| switch (ch) {
        '\\' => try buffer.appendSlice(allocator, "\\\\"),
        '"' => try buffer.appendSlice(allocator, "\\\""),
        '\n' => try buffer.appendSlice(allocator, "\\n"),
        '\r' => try buffer.appendSlice(allocator, "\\r"),
        '\t' => try buffer.appendSlice(allocator, "\\t"),
        else => try buffer.append(allocator, ch),
    };
    return try buffer.toOwnedSlice(allocator);
}
