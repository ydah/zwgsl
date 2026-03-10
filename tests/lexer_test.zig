const std = @import("std");
const zwgsl = @import("zwgsl");

fn expectTags(source: []const u8, expected: []const zwgsl.token.TokenTag) !void {
    const allocator = std.testing.allocator;
    const tokens = try zwgsl.lexer.Lexer.tokenize(allocator, source);
    defer allocator.free(tokens);

    try std.testing.expectEqual(expected.len, tokens.len);
    for (expected, tokens) |expected_tag, actual| {
        try std.testing.expectEqual(expected_tag, actual.tag);
    }
}

fn expectResolvedTags(source: []const u8, expected: []const zwgsl.token.TokenTag) !void {
    const allocator = std.testing.allocator;
    const tokens = try zwgsl.lexer.Lexer.tokenizeResolved(allocator, source);
    defer allocator.free(tokens);

    try std.testing.expectEqual(expected.len, tokens.len);
    for (expected, tokens) |expected_tag, actual| {
        try std.testing.expectEqual(expected_tag, actual.tag);
    }
}

test "lexer handles empty source" {
    try expectTags("", &.{.eof});
}

test "lexer emits keywords" {
    try expectTags("def main end", &.{ .kw_def, .identifier, .kw_end, .eof });
}

test "lexer emits uniform declaration tokens" {
    try expectTags("uniform :position, Vec3", &.{ .kw_uniform, .symbol, .comma, .identifier, .eof });
}

test "lexer distinguishes integer and float literals" {
    try expectTags("3.14\n42", &.{ .float_literal, .newline, .integer_literal, .eof });
}

test "lexer handles expressions" {
    try expectTags("x = a + b * c", &.{ .identifier, .assign, .identifier, .plus, .identifier, .star, .identifier, .eof });
}

test "lexer handles version strings" {
    try expectTags("version \"300 es\"", &.{ .kw_version, .string_literal, .eof });
}

test "lexer suppresses continued newline" {
    try expectTags("a +\nb", &.{ .identifier, .plus, .identifier, .eof });
}

test "lexer skips comments" {
    try expectTags("x = 1 # comment\n", &.{ .identifier, .assign, .integer_literal, .newline, .eof });
}

test "lexer recognizes composite operators" {
    try expectTags("-> += == != <= >= && ||", &.{ .arrow, .plus_assign, .eq, .neq, .le, .ge, .and_and, .or_or, .eof });
}

test "lexer recognizes symbols" {
    try expectTags(":highp :position", &.{ .symbol, .symbol, .eof });
}

test "lexer interns identifiers with a shared string pool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var pool = zwgsl.string_pool.StringPool.init(arena.allocator());
    defer pool.deinit();

    const tokens = try zwgsl.lexer.Lexer.tokenizeWithPool(arena.allocator(), &pool, "value value :value");
    try std.testing.expect(tokens[0].interned != null);
    try std.testing.expect(tokens[1].interned != null);
    try std.testing.expect(tokens[2].interned != null);
    try std.testing.expect(tokens[0].interned.?.ptr == tokens[1].interned.?.ptr);
    try std.testing.expect(tokens[1].interned.?.ptr == tokens[2].interned.?.ptr);
}

test "layout resolver keeps a flat line unchanged" {
    try expectResolvedTags("x = 1", &.{ .identifier, .assign, .integer_literal, .eof });
}

test "layout resolver inserts virtual semi between same-level lines" {
    try expectResolvedTags("x = 1\ny = 2", &.{
        .identifier,
        .assign,
        .integer_literal,
        .newline,
        .virtual_semi,
        .identifier,
        .assign,
        .integer_literal,
        .eof,
    });
}

test "layout resolver inserts virtual indent and dedent around a function body" {
    try expectResolvedTags(
        \\def main
        \\  x = 1
        \\end
    , &.{
        .kw_def,
        .identifier,
        .newline,
        .virtual_indent,
        .identifier,
        .assign,
        .integer_literal,
        .newline,
        .virtual_dedent,
        .kw_end,
        .eof,
    });
}

test "layout resolver tracks nested block depth" {
    try expectResolvedTags(
        \\def main
        \\  if ready
        \\    value = 1
        \\  end
        \\end
    , &.{
        .kw_def,
        .identifier,
        .newline,
        .virtual_indent,
        .kw_if,
        .identifier,
        .newline,
        .virtual_indent,
        .identifier,
        .assign,
        .integer_literal,
        .newline,
        .virtual_dedent,
        .kw_end,
        .newline,
        .virtual_dedent,
        .kw_end,
        .eof,
    });
}

test "layout resolver marks invalid indentation" {
    try expectResolvedTags(
        \\def main
        \\x = 1
        \\end
    , &.{
        .kw_def,
        .identifier,
        .newline,
        .invalid,
        .identifier,
        .assign,
        .integer_literal,
        .newline,
        .kw_end,
        .eof,
    });
}

test "layout resolver ignores blank and comment lines when computing indentation" {
    try expectResolvedTags(
        \\def main
        \\  x = 1
        \\
        \\  # comment
        \\  y = 2
        \\end
    , &.{
        .kw_def,
        .identifier,
        .newline,
        .virtual_indent,
        .identifier,
        .assign,
        .integer_literal,
        .newline,
        .newline,
        .newline,
        .virtual_semi,
        .identifier,
        .assign,
        .integer_literal,
        .newline,
        .virtual_dedent,
        .kw_end,
        .eof,
    });
}
