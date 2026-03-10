const std = @import("std");
const analysis = @import("analysis.zig");
const token = @import("../token.zig");

const Piece = struct {
    line: u32,
    column: u32,
    len: u32,
    token_type: analysis.LspTokenType,
};

pub fn response(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var document = try analysis.Document.init(allocator, source);
    defer document.deinit();

    var pieces: std.ArrayList(Piece) = .empty;
    defer pieces.deinit(allocator);

    for (document.tokens, 0..) |tok, index| {
        if (!isSemanticToken(tok.tag)) continue;
        try pieces.append(allocator, .{
            .line = if (tok.line > 0) tok.line - 1 else 0,
            .column = if (tok.column > 0) tok.column - 1 else 0,
            .len = @intCast(tok.end - tok.start),
            .token_type = document.semanticClass(tok, index),
        });
    }
    for (document.comments) |comment| {
        try pieces.append(allocator, .{
            .line = comment.line,
            .column = comment.column,
            .len = comment.len,
            .token_type = .comment,
        });
    }

    std.sort.heap(Piece, pieces.items, {}, lessThanPiece);

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    try writer.writeAll("{\"data\":[");
    var previous_line: u32 = 0;
    var previous_column: u32 = 0;
    for (pieces.items, 0..) |piece, index| {
        const delta_line = piece.line - previous_line;
        const delta_start = if (delta_line == 0) piece.column - previous_column else piece.column;
        if (index != 0) try writer.writeByte(',');
        try writer.print(
            "{d},{d},{d},{d},0",
            .{ delta_line, delta_start, piece.len, @intFromEnum(piece.token_type) },
        );
        previous_line = piece.line;
        previous_column = piece.column;
    }
    try writer.writeAll("]}");
    return try buffer.toOwnedSlice(allocator);
}

fn isSemanticToken(tag: token.TokenTag) bool {
    return switch (tag) {
        .newline,
        .virtual_indent,
        .virtual_dedent,
        .virtual_semi,
        .eof,
        .invalid,
        => false,
        else => true,
    };
}

fn lessThanPiece(_: void, lhs: Piece, rhs: Piece) bool {
    if (lhs.line != rhs.line) return lhs.line < rhs.line;
    return lhs.column < rhs.column;
}
