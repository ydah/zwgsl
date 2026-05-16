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
