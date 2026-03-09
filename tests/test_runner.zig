const std = @import("std");

test {
    std.testing.refAllDecls(@import("zwgsl"));
}

comptime {
    _ = @import("lexer_test.zig");
    _ = @import("parser_test.zig");
}
