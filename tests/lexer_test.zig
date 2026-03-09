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
