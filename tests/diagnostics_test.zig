const std = @import("std");
const zwgsl = @import("zwgsl");

test "diagnostic formats source context" {
    const allocator = std.testing.allocator;
    const source =
        \\def main
        \\  color = 42
        \\end
    ;

    const diagnostic: zwgsl.diagnostics.Diagnostic = .{
        .kind = .@"error",
        .message = "type mismatch in assignment",
        .line = 2,
        .column = 11,
    };

    const formatted = try diagnostic.formatOwned(allocator, source);
    defer allocator.free(formatted);

    try std.testing.expectEqualStrings(
        \\error: type mismatch in assignment
        \\  --> 2:11
        \\   |
        \\2 |   color = 42
        \\   |           ^
        \\
    ,
        formatted,
    );
}

test "diagnostic list formats multiple entries" {
    const allocator = std.testing.allocator;
    const source =
        \\x = 1
        \\y = 2
    ;

    var list = zwgsl.diagnostics.DiagnosticList.init(allocator);
    defer list.deinit();

    try list.append(.{
        .kind = .warning,
        .message = "unused value",
        .line = 1,
        .column = 1,
    });
    try list.append(.{
        .kind = .@"error",
        .message = "bad assignment",
        .line = 2,
        .column = 5,
    });

    const formatted = try list.formatAllOwned(source);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "warning: unused value") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "error: bad assignment") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "2 | y = 2") != null);
}
