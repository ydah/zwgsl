const std = @import("std");
const zwgsl = @import("zwgsl");

test "formatter normalizes block indentation" {
    const source =
        \\fragment do
        \\output :frag_color, Vec4, location: 0
        \\def main
        \\frag_color = vec4(1.0)
        \\end
        \\end
    ;
    const expected =
        \\fragment do
        \\  output :frag_color, Vec4, location: 0
        \\  def main
        \\    frag_color = vec4(1.0)
        \\  end
        \\end
        \\
    ;

    const formatted = try zwgsl.formatter.format(std.testing.allocator, source, .{});
    defer std.testing.allocator.free(formatted);

    try std.testing.expectEqualStrings(expected, formatted);
}

test "formatter handles where and match arms" {
    const source =
        \\def area(shape: Shape) -> Float
        \\match shape
        \\when Circle(radius)
        \\radius * radius
        \\when _
        \\0.0
        \\end
        \\where
        \\fallback = 0.0
        \\end
    ;
    const expected =
        \\def area(shape: Shape) -> Float
        \\  match shape
        \\  when Circle(radius)
        \\    radius * radius
        \\  when _
        \\    0.0
        \\  end
        \\where
        \\  fallback = 0.0
        \\end
        \\
    ;

    const formatted = try zwgsl.formatter.format(std.testing.allocator, source, .{});
    defer std.testing.allocator.free(formatted);

    try std.testing.expectEqualStrings(expected, formatted);
}

test "formatter reads block markers before trailing comments" {
    const source =
        \\vertex do # stage comment
        \\def main # function comment
        \\gl_Position = vec4(0.0)
        \\end
        \\end
    ;
    const expected =
        \\vertex do # stage comment
        \\  def main # function comment
        \\    gl_Position = vec4(0.0)
        \\  end
        \\end
        \\
    ;

    const formatted = try zwgsl.formatter.formatChecked(std.testing.allocator, source, .{});
    defer std.testing.allocator.free(formatted);

    try std.testing.expectEqualStrings(expected, formatted);
}

test "formatter rejects source that remains invalid after formatting" {
    const source =
        \\fragment do
        \\  def main
        \\    frag_color = vec4(1.0)
    ;

    try std.testing.expectError(
        error.FormattedSourceInvalid,
        zwgsl.formatter.formatChecked(std.testing.allocator, source, .{}),
    );
}
